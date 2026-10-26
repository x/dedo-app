import Foundation

/// The whole to-do list as one markdown file: `# Folder` headings contain `## Section` headings
/// contain `- [ ]` items. The text is the source of truth: every edit is a line splice, so anything
/// we don't model (prose, nested lists, deeper headings) survives untouched.
public struct Doc: Equatable {
    public var lines: [String]
    /// Where new items (and new Inbox days) go: the top of a list, or the bottom. Done is always
    /// newest first. A per-machine setting (`new_items` in config.toml), not part of the text.
    public var newestFirst: Bool
    public init(_ text: String, newestFirst: Bool = true) {
        lines = text.components(separatedBy: "\n")
        self.newestFirst = newestFirst
    }
    public var text: String { lines.joined(separator: "\n") }

    public struct Item: Equatable {
        public var range: Range<Int>
        public var done: Bool
        public var title: String
        public var doneAt: Date?
        public var children: [String]
        public var links: [URL] { children.compactMap(Doc.link) }
        public func same(as o: Item) -> Bool { done == o.done && title == o.title && doneAt == o.doneAt && children == o.children }
    }

    public struct Section: Equatable {
        public var title: String? // nil = the part of a folder above its first `##`
        public var range: Range<Int>
        public var items: [Item]
        var head: Int // 1 when the range starts with a heading line
    }

    public struct Folder: Equatable {
        public var title: String? // nil = anything above the first `#`
        public var range: Range<Int>
        public var sections: [Section]
        public var items: [Item] { sections.flatMap(\.items) }
    }

    /// `- [ ] title` followed by indented, non-blank lines (its sub-items).
    public var items: [Item] {
        var out: [Item] = [], i = 0
        while i < lines.count {
            guard let cb = Doc.checkbox(lines[i]) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, lines[j].first == " " || lines[j].first == "\t", !Doc.blank(lines[j]) { j += 1 }
            let (title, doneAt) = Doc.splitStamp(cb.title)
            out.append(Item(range: i..<j, done: cb.done, title: title, doneAt: doneAt,
                            children: lines[i + 1..<j].map(Doc.unbullet)))
            i = j
        }
        return out
    }

    public var folders: [Folder] {
        let all = items
        let fb = [0] + lines.indices.filter { Doc.h1(lines[$0]) != nil } + [lines.count]
        return (0..<fb.count - 1).map { k in
            let fr = fb[k]..<fb[k + 1]
            let sb = [fr.lowerBound] + fr.filter { Doc.h2(lines[$0]) != nil } + [fr.upperBound]
            let sections = (0..<sb.count - 1).map { j in
                let r = sb[j]..<sb[j + 1]
                return Section(title: j == 0 ? nil : Doc.h2(lines[r.lowerBound]), range: r,
                               items: all.filter { r.contains($0.range.lowerBound) }, head: k == 0 && j == 0 ? 0 : 1)
            }
            return Folder(title: k == 0 ? nil : Doc.h1(lines[fr.lowerBound]), range: fr, sections: sections)
        }
    }

    public func folder(_ name: String) -> Folder? { folders.first { $0.title == name } }

    /// The folder and section an item is in (nil folder = above the first `#`).
    public func location(of item: Item) -> (folder: String?, section: String?)? {
        for f in folders {
            for s in f.sections where s.items.contains(where: { $0.same(as: item) }) { return (f.title, s.title) }
        }
        return nil
    }

    public static func block(title: String, children: [String]) -> [String] {
        [line(done: false, title)] + children.map { "  - \($0)" }
    }

    public mutating func add(title: String, children: [String], at: Int) {
        lines.insert(contentsOf: Doc.block(title: title, children: children), at: at)
    }

    /// Adds lines to a folder's section (nil = above its first `##`), at the top or bottom per `newestFirst`.
    /// Creates the folder if needed. Inbox without a section means today's `## yyyy-MM-dd`.
    public mutating func insert(_ block: [String], folder name: String, section: String? = nil, today: String = Doc.today) {
        if name == "Inbox", section == nil { return addToDay(block, day: today) }
        ensureFolder(name)
        let f = folder(name)!
        lines.insert(contentsOf: block, at: slot(in: f.sections.first { $0.title == section } ?? f.sections[0]))
    }

    public mutating func move(_ item: Item, folder name: String, section: String? = nil, today: String = Doc.today) {
        let block = Array(lines[item.range])
        lines.removeSubrange(item.range)
        insert(block, folder: name, section: section, today: today)
    }

    public mutating func move(_ item: Item, before target: Item) { move(item, toLine: target.range.lowerBound) }
    public mutating func move(_ item: Item, after target: Item) { move(item, toLine: target.range.upperBound) }

    public mutating func delete(_ item: Item) { lines.removeSubrange(item.range) }

    /// Checks off in place, stamping `@done(yyyy-MM-dd HH:mm)`; reopening drops the stamp.
    public mutating func toggle(_ item: Item, at now: Date = Date()) {
        lines[item.range.lowerBound] = Doc.line(done: !item.done, item.title, item.done ? nil : now)
    }

    public mutating func edit(_ item: Item, title: String, adding children: [String]) {
        lines[item.range.lowerBound] = Doc.line(done: item.done, title, item.doneAt)
        lines.insert(contentsOf: children.map { "  - \($0)" }, at: item.range.upperBound)
    }

    // MARK: Inbox days, Done, folders

    /// Today's items go under `## yyyy-MM-dd` in Inbox.
    public mutating func addToDay(_ block: [String], day: String) {
        ensureDay(day)
        lines.insert(contentsOf: block, at: slot(in: folder("Inbox")!.sections.first { $0.title == day }!))
    }

    public mutating func ensureDay(_ day: String) {
        ensureFolder("Inbox")
        let f = folder("Inbox")!
        guard !f.sections.contains(where: { $0.title == day }) else { return }
        let newest = newestFirst ? f.sections.first { $0.title.map(Doc.isDay) == true } : nil
        insertSpaced(["## \(day)"], at: newest?.range.lowerBound ?? trimEnd(f.range, head: 1))
    }

    /// Creates `# name` if missing: Inbox first, Done last, anything else just above Done.
    public mutating func ensureFolder(_ name: String) {
        guard folder(name) == nil else { return }
        let fs = folders
        let at = name == "Inbox" ? (fs.first { $0.title != nil }?.range.lowerBound ?? contentEnd)
            : name == "Done" ? contentEnd : (folder("Done")?.range.lowerBound ?? contentEnd)
        insertSpaced(["# \(name)"], at: at)
    }

    /// Moves a whole `# folder` above another (nil = to the end).
    public mutating func moveFolder(_ name: String, before other: String?) {
        guard name != other, let f = folder(name) else { return }
        var block = Array(lines[f.range])
        while block.last.map(Doc.blank) == true { block.removeLast() }
        lines.removeSubrange(f.range)
        insertSpaced(block, at: other.flatMap(folder)?.range.lowerBound ?? contentEnd)
    }

    /// Removes done items outside `# Done` completed before `cutoff` (unstamped ones count as old)
    /// and returns their blocks newest first, for `archive`.
    public mutating func sweep(before cutoff: Date) -> [[String]] {
        let done = folder("Done")?.range
        let gone = items.filter { $0.done && ($0.doneAt ?? .distantPast) < cutoff && done?.contains($0.range.lowerBound) != true }
        let blocks = gone.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }.map { Array(lines[$0.range]) }
        for it in gone.reversed() { lines.removeSubrange(it.range) }
        return blocks
    }

    /// Puts blocks at the top of `# Done`, keeping it newest first.
    public mutating func archive(_ blocks: [[String]]) {
        guard !blocks.isEmpty else { return }
        ensureFolder("Done")
        lines.insert(contentsOf: blocks.flatMap { $0 }, at: top(of: folder("Done")!.sections[0]))
    }

    /// Drops empty date sections (and a legacy empty `## Done`); headings you wrote yourself stay,
    /// and so does `keeping` (today's, which may be about to get an item).
    public mutating func pruneEmptySections(keeping: String? = nil) {
        for s in folders.flatMap(\.sections).reversed() {
            guard let t = s.title, t != keeping, Doc.isDay(t) || t.lowercased() == "done",
                  lines[s.range].dropFirst().allSatisfy(Doc.blank) else { continue }
            lines.removeSubrange(s.range)
        }
    }

    /// The most recent 6am local: things finished before it have had their day.
    public static func sweepCutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let six = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now)!
        return six <= now ? six : calendar.date(byAdding: .day, value: -1, to: six)!
    }

    // MARK: Lint

    public struct Problem: Equatable, CustomStringConvertible {
        public let line: Int // 1-based
        public let message: String
        public var description: String { "\(line): \(message)" }
    }

    /// Structure problems a hand (or agent) edit can introduce. Empty means DEDO reads the file as intended.
    public func lint() -> [Problem] {
        var out: [Problem] = []
        let add = { (i: Int, m: String) in out.append(Problem(line: i + 1, message: m)) }
        for (i, l) in lines.enumerated() {
            if l.first == "#", l.drop(while: { $0 == "#" }).first != " " { add(i, "heading needs a space after the #s") }
            if l.hasPrefix("-[") || l.hasPrefix("* [") {
                add(i, "checkbox must be \"- [ ] \" or \"- [x] \"")
            } else if l.hasPrefix("- ["), Doc.checkbox(l) == nil {
                add(i, "checkbox must be \"- [ ] \" or \"- [x] \"")
            }
        }
        for it in items where it.title.isEmpty { add(it.range.lowerBound, "item has no title") }
        for it in items {
            let l = lines[it.range.lowerBound]
            if l.contains("@done("), it.doneAt == nil { add(it.range.lowerBound, "unreadable @done date; use @done(yyyy-MM-dd HH:mm)") }
            if !it.done, it.doneAt != nil { add(it.range.lowerBound, "open item has a @done stamp") }
        }
        let fs = folders
        if let first = fs.first?.items.first { add(first.range.lowerBound, "item is above the first # folder; it only shows in All") }
        if folder("Inbox") == nil { add(0, "no # Inbox folder") }
        var folderNames = Set<String>()
        for f in fs {
            guard let t = f.title else { continue }
            if t.isEmpty { add(f.range.lowerBound, "folder heading has no name") }
            if !folderNames.insert(t).inserted { add(f.range.lowerBound, "duplicate folder \"\(t)\"; only the first is shown") }
            var sectionNames = Set<String>()
            for s in f.sections {
                guard let st = s.title else { continue }
                if !sectionNames.insert(st).inserted { add(s.range.lowerBound, "duplicate section \"\(st)\" in \(t)") }
            }
            if t == "Inbox" {
                let days = f.sections.compactMap { $0.title }.filter(Doc.isDay)
                if days != days.sorted(by: >), days != days.sorted() { add(f.range.lowerBound, "Inbox days are out of order") }
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    // MARK: Input

    /// Free text → (title, sub-items). URLs are always pulled out into their own sub-items;
    /// the first remaining line is the title, any further lines become note sub-items.
    public static func parseInput(_ s: String) -> (title: String, children: [String]) {
        let ns = s as NSString, rest = NSMutableString(string: s)
        var links: [String] = []
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let sub = ns.substring(with: m.range)
            guard sub.contains("://") else { continue } // skip bare domains and emails
            links.insert(sub, at: 0)
            rest.replaceCharacters(in: m.range, with: "")
        }
        let text = (rest as String).components(separatedBy: .newlines)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return (text.first ?? "", links + text.dropFirst())
    }

    /// A sub-item is a link if it is a bare URL or `[title](url)`.
    public static func link(_ s: String) -> URL? {
        var s = s
        if s.hasPrefix("["), s.hasSuffix(")"), let r = s.range(of: "](") { s = String(s[r.upperBound...].dropLast()) }
        return !s.contains(" ") && s.contains("://") ? URL(string: s) : nil
    }

    public static let stamp = formatter("yyyy-MM-dd HH:mm")
    public static let day = formatter("yyyy-MM-dd")
    public static var today: String { day.string(from: Date()) }
    public static func isDay(_ s: String) -> Bool { s.count == 10 && day.date(from: s) != nil }

    // MARK: Private

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private mutating func move(_ item: Item, toLine to: Int) {
        let block = Array(lines[item.range])
        lines.removeSubrange(item.range)
        lines.insert(contentsOf: block, at: to > item.range.lowerBound ? to - item.range.count : to)
    }

    /// Above the section's first item (or after its heading when it has none).
    private func top(of s: Section) -> Int { s.items.first?.range.lowerBound ?? trimEnd(s.range, head: s.head) }

    /// Where a new item goes in a section.
    private func slot(in s: Section) -> Int { newestFirst ? top(of: s) : trimEnd(s.range, head: s.head) }

    private func trimEnd(_ r: Range<Int>, head: Int) -> Int {
        var i = r.upperBound
        while i > r.lowerBound + head, Doc.blank(lines[i - 1]) { i -= 1 }
        return i
    }

    /// After the last non-blank line.
    private var contentEnd: Int { trimEnd(0..<lines.count, head: 0) }

    /// Inserts heading-level lines, keeping a blank line on either side.
    private mutating func insertSpaced(_ block: [String], at: Int) {
        var b = block
        if at > 0, !Doc.blank(lines[at - 1]) { b.insert("", at: 0) }
        if at >= lines.count || !Doc.blank(lines[at]) { b.append("") }
        lines.insert(contentsOf: b, at: at)
    }

    private static func blank(_ l: String) -> Bool { l.trimmingCharacters(in: .whitespaces).isEmpty }
    private static func h1(_ l: String) -> String? { l.hasPrefix("# ") ? l.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil }
    private static func h2(_ l: String) -> String? { l.hasPrefix("## ") ? l.dropFirst(3).trimmingCharacters(in: .whitespaces) : nil }

    private static func line(done: Bool, _ title: String, _ doneAt: Date? = nil) -> String {
        "- [\(done ? "x" : " ")] \(title)" + (doneAt.map { " @done(\(stamp.string(from: $0)))" } ?? "")
    }

    private static func splitStamp(_ t: String) -> (String, Date?) {
        guard t.hasSuffix(")"), let r = t.range(of: "@done(", options: .backwards) else { return (t, nil) }
        return (t[..<r.lowerBound].trimmingCharacters(in: .whitespaces), stamp.date(from: String(t[r.upperBound...].dropLast())))
    }

    private static func checkbox(_ l: String) -> (done: Bool, title: String)? {
        guard l.hasPrefix("- ["), l.count >= 5, l.dropFirst(4).first == "]" else { return nil }
        let mark = l[l.index(l.startIndex, offsetBy: 3)]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", l.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    private static func unbullet(_ l: String) -> String {
        let s = l.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("- ") || s.hasPrefix("* ") ? String(s.dropFirst(2)) : s
    }
}
