import Foundation

/// A key as the engine sees it.
public enum VimKey: Equatable {
    case char(Character)
    case ctrl(Character)
    case escape, enter, backspace, up, down, left, right
}

/// The text the engine edits: an NSTextView (`VimTextView`), or a plain string in tests.
/// Offsets are UTF-16, like NSString and NSTextView.
public protocol VimBuffer: AnyObject {
    var string: String { get }
    /// Where the caret is, e.g. after native typing or a mouse click.
    var caret: Int { get }
    /// Shows the caret, and in visual mode the selection.
    func show(caret: Int, selection: NSRange?)
    /// One undoable edit.
    func replace(_ range: NSRange, with text: String)
    func undoChange()
    func redoChange()
    /// Lines in half a screen, for Ctrl-D and Ctrl-U.
    var halfPage: Int { get }
}

/// The system clipboard, so `y` and `p` work with other apps.
public protocol VimPasteboard: AnyObject {
    var changeCount: Int { get }
    func read() -> String?
    func write(_ text: String)
}

/// Vim's editing model over a `VimBuffer`: the everyday core, plus Markdown list continuation.
///
/// In insert mode, a text view does its own typing (so input methods and key repeat work) and the
/// engine only handles Esc, Enter, and Ctrl-W; set `insertsTyping` to have the engine type instead.
public final class VimEngine {
    public enum Mode: Equatable { case normal, insert, visual, visualLine }

    public private(set) var mode = Mode.normal
    /// The `:`, `/` or `?` line being typed (prefix included), or nil.
    public private(set) var commandLine: String?
    /// Feedback for the mode line, cleared by the next command.
    public var message = ""
    /// Ex commands the engine doesn't do itself (`:w`, `:q`, ...). Return a message to show, or nil.
    public var exCommand: ((String) -> String?)?
    public var pasteboard: VimPasteboard?
    /// Type insert-mode characters through the engine rather than leaving them to the text view.
    public var insertsTyping = false
    /// Spaces per `>` / `<`. Markdown nests lists by two.
    public var shiftWidth = 2

    public private(set) var cursor = 0

    private unowned let buffer: VimBuffer
    private var pending: [VimKey] = []
    private var register = (text: "", linewise: false)
    private var pasteboardSeen = -1
    private var column: Int? // remembered by j/k
    private var lastFind: (char: Character, forward: Bool, till: Bool)?
    private var lastSearch: (text: String, forward: Bool)?
    private var visualStart = 0
    private var lastChange: (keys: [VimKey], inserted: String?)?
    private var changeKeys: [VimKey]? // the insert-mode change in progress, for "."
    private var insertStart = 0
    private var replaying = false
    private var startsCache: [Int]?
    private var searchOp: Character? // d/foo: the operator waiting on the search

    public init(buffer: VimBuffer) {
        self.buffer = buffer
        cursor = buffer.caret
    }

    /// What a mode line shows: the command being typed, a message, or the mode.
    public var status: String {
        if let c = commandLine { return c }
        if !message.isEmpty { return message }
        switch mode {
        case .insert: return "-- INSERT --"
        case .visual: return "-- VISUAL --"
        case .visualLine: return "-- VISUAL LINE --"
        case .normal: return pending.map(VimEngine.describe).joined()
        }
    }

    /// Feeds one key. Returns false when the text view should handle it (typing in insert mode).
    @discardableResult
    public func handle(_ key: VimKey) -> Bool {
        startsCache = nil // native typing may have changed the text
        if commandLine != nil { commandLineKey(key); return true }
        if mode == .insert { return insertKey(key) }
        if pending.isEmpty {
            message = ""
            if mode == .normal { cursor = clamp(buffer.caret) } // a click may have moved it
            if mode == .normal, key == .char(".") { repeatLastChange(); return true }
        }
        pending.append(key)
        let keys = pending[...]
        switch mode == .normal ? normal(keys) : visual(keys) {
        case .more: return true
        case .fail, .done: pending = []
        }
        if mode != .insert { cursor = clamp(cursor) }
        show()
        return true
    }

    /// Types text at the caret, as insert mode would.
    public func type(_ text: String) {
        for c in text { _ = insertKey(c == "\n" ? .enter : .char(c), force: true) }
    }

    /// Puts the cursor on the first non-blank of a 0-based line.
    public func goToLine(_ n: Int) {
        startsCache = nil
        cursor = firstNonBlank(lineOffset(max(0, min(n, lastLine))))
        show()
    }

    // MARK: Normal mode

    private enum Step { case more, fail, done }

    private struct Target {
        var from: Int, to: Int
        var linewise = false
        var inclusive = false
        var object = false // a text object: from..to is the whole range
        var keepColumn: Int? // j/k: the column to remember
        var toLineEnd = false // $: remember "end of line"
    }

    private enum Got { case more, fail, ok(Target) }

    private func normal(_ all: ArraySlice<VimKey>) -> Step {
        var keys = all
        let n1 = takeCount(&keys)
        guard let k = keys.first else { return .more }
        let n = n1 ?? 1
        // Operators take a motion, a text object, or themselves (dd) for whole lines.
        if case let .char(op) = k, "dcy<>".contains(op) {
            keys.removeFirst()
            let n2 = takeCount(&keys)
            guard let m = keys.first else { return .more }
            let total = n * (n2 ?? 1)
            if m == k { return change(all, op != "y") { self.operate(op, self.lines(total)) } }
            if m == .char("/") || m == .char("?") { // the operator applies up to the match
                searchOp = op
                commandLine = m == .char("/") ? "/" : "?"
                return .done
            }
            switch target(keys, count: total, explicit: n1 != nil || n2 != nil, op: op) {
            case .more: return .more
            case .fail: return .fail
            case let .ok(t): return change(all, op != "y") { self.operate(op, t) }
            }
        }
        if let step = command(k, keys.dropFirst(), n, all: all) { return step }
        switch target(keys, count: n, explicit: n1 != nil, op: nil) {
        case .more: return .more
        case .fail: return .fail
        case let .ok(t): move(to: t); return .done
        }
    }

    /// Commands that aren't motions. Nil means "not a command; try it as a motion".
    private func command(_ k: VimKey, _ rest: ArraySlice<VimKey>, _ n: Int, all: ArraySlice<VimKey>) -> Step? {
        let c = cursor
        switch k {
        case .char("i"): return change(all) { self.enterInsert(at: c) }
        case .char("a"): return change(all) { self.enterInsert(at: self.lineEnd(c) > c ? c + 1 : c) }
        case .char("I"): return change(all) { self.enterInsert(at: self.firstNonBlankOrEnd(c)) }
        case .char("A"): return change(all) { self.enterInsert(at: self.lineEnd(c)) }
        case .char("o"): return change(all) { self.openLine(below: true) }
        case .char("O"): return change(all) { self.openLine(below: false) }
        case .char("x"):
            guard lineEnd(c) > c else { return .fail }
            return change(all) { self.operate("d", Target(from: c, to: min(c + n, self.lineEnd(c)))) }
        case .char("X"):
            guard c > lineStart(c) else { return .fail }
            return change(all) { self.operate("d", Target(from: max(self.lineStart(c), c - n), to: c)) }
        case .char("s"): return change(all) { self.operate("c", Target(from: c, to: min(c + n, self.lineEnd(c)))) }
        case .char("S"): return change(all) { self.operate("c", self.lines(n)) }
        case .char("D"), .char("C"):
            let end = lineEnd(lineOffset(min(lineIndex(c) + n - 1, lastLine)))
            return change(all) { self.operate(k == .char("D") ? "d" : "c", Target(from: c, to: end)) }
        case .char("Y"): operate("y", lines(n)); return .done
        case .char("p"), .char("P"): return change(all) { self.paste(before: k == .char("P"), n) }
        case .char("r"):
            guard let r = rest.first else { return .more }
            guard case let .char(x) = r, lineEnd(c) - c >= n else { return .fail }
            return change(all) {
                self.replace(NSRange(location: c, length: n), String(repeating: x, count: n))
                self.cursor = c + n - 1
            }
        case .char("J"): return change(all) { self.join(c, max(2, n)) }
        case .char("~"):
            guard lineEnd(c) > c else { return .fail }
            return change(all) {
                let r = NSRange(location: c, length: min(n, self.lineEnd(c) - c))
                self.replace(r, String(self.text(r).map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) }))
                self.cursor = NSMaxRange(r)
            }
        case .char("u"):
            for _ in 0..<n { buffer.undoChange() }
            startsCache = nil; cursor = buffer.caret
            return .done
        case .ctrl("r"):
            for _ in 0..<n { buffer.redoChange() }
            startsCache = nil; cursor = buffer.caret
            return .done
        case .char("v"): mode = .visual; visualStart = c; return .done
        case .char("V"): mode = .visualLine; visualStart = c; return .done
        case .char(":"), .char("/"), .char("?"):
            if case let .char(p) = k { commandLine = String(p) }
            return .done
        case .char("Z"):
            guard let r = rest.first else { return .more }
            if r == .char("Z") { ex("x"); return .done }
            if r == .char("Q") { ex("q!"); return .done }
            return .fail
        case .escape: return .fail
        default: return nil
        }
    }

    /// Runs a command and, if it changed the text, remembers it for ".".
    private func change(_ all: ArraySlice<VimKey>, _ changes: Bool = true, _ body: () -> Void) -> Step {
        body()
        if changes {
            if mode == .insert { changeKeys = Array(all) } else { lastChange = (Array(all), nil) }
        }
        return .done
    }

    private func repeatLastChange() {
        guard let last = lastChange else { return }
        replaying = true
        defer { replaying = false }
        for k in last.keys { handle(k) }
        if mode == .insert {
            insert(last.inserted ?? "", at: cursor)
            _ = insertKey(.escape)
        }
    }

    private func move(to t: Target) {
        cursor = t.to
        column = t.toLineEnd ? Int.max : t.keepColumn
    }

    // MARK: Motions and text objects

    /// A motion, or (after an operator, or in visual mode) a text object, at the front of `keys`.
    private func target(_ keys: ArraySlice<VimKey>, count n: Int, explicit: Bool, op: Character?) -> Got {
        guard let k = keys.first else { return .more }
        let next = keys.dropFirst().first
        let c = cursor
        func to(_ i: Int, inclusive: Bool = false) -> Got { .ok(Target(from: c, to: i, inclusive: inclusive)) }
        switch k {
        case .char("h"), .left, .backspace: return to(max(lineStart(c), c - n))
        case .char("l"), .right, .char(" "): return to(min(op != nil ? lineEnd(c) : lastCol(c), c + n))
        case .char("j"), .down, .ctrl("n"): return vertical(n)
        case .char("k"), .up, .ctrl("p"): return vertical(-n)
        case .enter, .char("+"): return lineIndex(c) + n <= lastLine ? lineTarget(lineIndex(c) + n) : .fail
        case .char("-"): return lineIndex(c) - n >= 0 ? lineTarget(lineIndex(c) - n) : .fail
        case .ctrl("d"): return vertical(buffer.halfPage)
        case .ctrl("u"): return vertical(-buffer.halfPage)
        case .char("0"): return to(lineStart(c))
        case .char("^"): return to(firstNonBlank(c))
        case .char("$"):
            var t = Target(from: c, to: lastCol(lineOffset(min(lineIndex(c) + n - 1, lastLine))), inclusive: true)
            t.toLineEnd = true
            return .ok(t)
        case .char("w"), .char("W"):
            let big = k == .char("W")
            if op == "c", c < len, cls(c, big) != 0 { // cw changes to the end of the word, like ce
                var e = c
                while e + 1 < len, cls(e + 1, big) == cls(c, big) { e += 1 }
                for _ in 1..<max(n, 1) { e = wordEnd(e, big) }
                return to(e, inclusive: true)
            }
            var i = c
            for _ in 0..<n { i = wordForward(i, big) }
            // dw on a line's last word stops at the line end rather than eating the newline.
            if op != nil, lineIndex(i) > lineIndex(c), i <= firstNonBlankOrEnd(i) { i = lineEnd(i - 1) }
            return to(i)
        case .char("b"), .char("B"):
            var i = c
            for _ in 0..<n { i = wordBack(i, k == .char("B")) }
            return to(i)
        case .char("e"), .char("E"):
            var i = c
            for _ in 0..<n { i = wordEnd(i, k == .char("E")) }
            return to(i, inclusive: true)
        case .char("G"): return lineTarget(explicit ? n - 1 : lastLine)
        case .char("g"):
            guard let next else { return .more }
            return next == .char("g") ? lineTarget(explicit ? n - 1 : 0) : .fail
        case .char("f"), .char("F"), .char("t"), .char("T"):
            guard let next else { return .more }
            guard case let .char(x) = next else { return .fail }
            let forward = k == .char("f") || k == .char("t"), till = k == .char("t") || k == .char("T")
            lastFind = (x, forward, till)
            guard let i = find(x, forward: forward, till: till, n, from: c) else { return .fail }
            return to(i, inclusive: forward)
        case .char(";"), .char(","):
            guard let f = lastFind else { return .fail }
            let forward = k == .char(";") ? f.forward : !f.forward
            guard let i = find(f.char, forward: forward, till: f.till, n, from: f.till ? c + (forward ? 1 : -1) : c) else { return .fail }
            return to(i, inclusive: forward)
        case .char("%"):
            guard let i = matchBracket(c) else { return .fail }
            return to(i, inclusive: true)
        case .char("}"), .char("{"): return to(paragraph(from: c, forward: k == .char("}"), n))
        case .char("n"), .char("N"):
            guard let s = lastSearch else { return .fail }
            let forward = k == .char("n") ? s.forward : !s.forward
            var i: Int? = c
            for _ in 0..<n { i = i.flatMap { search(s.text, forward: forward, from: $0) } }
            guard let i else { message = "Pattern not found: \(s.text)"; return .fail }
            return to(i)
        case .char("*"), .char("#"):
            guard let w = textObject("w", inner: true, at: c) else { return .fail }
            let word = text(NSRange(location: w.from, length: w.to - w.from + 1))
            guard cls(c, false) == 1 else { return .fail }
            lastSearch = (word, k == .char("*"))
            guard let i = search(word, forward: k == .char("*"), from: k == .char("*") ? c : w.from) else { return .fail }
            return to(i)
        case .char("i"), .char("a"):
            guard op != nil || mode != .normal else { return .fail }
            guard let next else { return .more }
            guard case let .char(x) = next, let t = textObject(x, inner: k == .char("i"), at: c) else { return .fail }
            return .ok(t)
        default: return .fail
        }
    }

    private func vertical(_ d: Int) -> Got {
        let line = lineIndex(cursor), goal = max(0, min(lastLine, line + d))
        guard goal != line else { return .fail }
        let col = column ?? (cursor - lineStart(cursor))
        let start = lineOffset(goal)
        var t = Target(from: cursor, to: col == Int.max ? lastCol(start) : min(start + col, lastCol(start)), linewise: true)
        t.keepColumn = col
        return .ok(t)
    }

    private func lineTarget(_ line: Int) -> Got {
        .ok(Target(from: cursor, to: firstNonBlank(lineOffset(max(0, min(line, lastLine)))), linewise: true))
    }

    /// `count` whole lines from the cursor's, for dd, yy, cc, >>, <<.
    private func lines(_ count: Int) -> Target {
        Target(from: cursor, to: lineOffset(min(lineIndex(cursor) + count - 1, lastLine)), linewise: true)
    }

    private func wordForward(_ from: Int, _ big: Bool) -> Int {
        var i = from
        guard i < len else { return len }
        let k = cls(i, big)
        if k != 0 { while i < len, cls(i, big) == k { i += 1 } }
        while i < len, cls(i, big) == 0 {
            if ch(i) == 10, i + 1 < len, ch(i + 1) == 10 { return i + 1 } // an empty line is a word
            i += 1
        }
        return i
    }

    private func wordEnd(_ from: Int, _ big: Bool) -> Int {
        var i = from + 1
        while i < len, cls(i, big) == 0 { i += 1 }
        guard i < len else { return max(from, len - 1) }
        let k = cls(i, big)
        while i + 1 < len, cls(i + 1, big) == k { i += 1 }
        return i
    }

    private func wordBack(_ from: Int, _ big: Bool) -> Int {
        var i = from - 1
        while i > 0, cls(i, big) == 0 {
            if ch(i) == 10, ch(i - 1) == 10 { return i } // an empty line is a word
            i -= 1
        }
        guard i > 0 else { return 0 }
        let k = cls(i, big)
        while i > 0, cls(i - 1, big) == k { i -= 1 }
        return i
    }

    private func find(_ x: Character, forward: Bool, till: Bool, _ n: Int, from c: Int) -> Int? {
        guard let u = String(x).utf16.first, String(x).utf16.count == 1 else { return nil }
        let ls = lineStart(cursor), le = lineEnd(cursor), d = forward ? 1 : -1
        var i = c, hits = 0
        while true {
            i += d
            guard i >= ls, i < le else { return nil }
            if ch(i) == u {
                hits += 1
                if hits == n { return till ? i - d : i }
            }
        }
    }

    private func matchBracket(_ c: Int) -> Int? {
        let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true),
                                                 41: (40, false), 93: (91, false), 125: (123, false)]
        var i = c
        while i < lineEnd(c), pairs[ch(i)] == nil { i += 1 }
        guard i < lineEnd(c), let (other, forward) = pairs[ch(i)] else { return nil }
        let me = ch(i)
        var depth = 0
        while i >= 0, i < len {
            if ch(i) == me { depth += 1 } else if ch(i) == other { depth -= 1; if depth == 0 { return i } }
            i += forward ? 1 : -1
        }
        return nil
    }

    /// Next (or previous) blank line after the current paragraph.
    private func paragraph(from c: Int, forward: Bool, _ n: Int) -> Int {
        var line = lineIndex(c)
        let d = forward ? 1 : -1, edge = forward ? lastLine : 0
        for _ in 0..<n {
            while line != edge, isBlankLine(line) { line += d }
            while line != edge, !isBlankLine(line) { line += d }
        }
        return line == lastLine && forward && !isBlankLine(line) ? lastCol(lineOffset(line)) : lineOffset(line)
    }

    private func textObject(_ x: Character, inner: Bool, at c: Int) -> Target? {
        switch x {
        case "w", "W":
            let ls = lineStart(c), le = lineEnd(c)
            guard le > ls else { return nil }
            let big = x == "W", k = cls(c, big)
            var a = c, b = c
            while a > ls, cls(a - 1, big) == k { a -= 1 }
            while b + 1 < le, cls(b + 1, big) == k { b += 1 }
            if !inner { // aw: trailing blanks, or leading ones if there are none
                var e = b
                while e + 1 < le, isBlank(ch(e + 1)) { e += 1 }
                if e > b { b = e } else { while a > ls, isBlank(ch(a - 1)) { a -= 1 } }
            }
            return Target(from: a, to: b, inclusive: true, object: true)
        case "\"", "'", "`":
            guard let q = String(x).utf16.first else { return nil }
            let quotes = (lineStart(c)..<lineEnd(c)).filter { ch($0) == q }
            for p in stride(from: 0, to: quotes.count - 1, by: 2) where c <= quotes[p + 1] {
                let (o, e) = (quotes[p], quotes[p + 1])
                return inner ? Target(from: o + 1, to: e, object: true) : Target(from: o, to: e, inclusive: true, object: true)
            }
            return nil
        case "(", ")", "b": return bracketObject(40, 41, inner, c)
        case "[", "]": return bracketObject(91, 93, inner, c)
        case "{", "}", "B": return bracketObject(123, 125, inner, c)
        case "<", ">": return bracketObject(60, 62, inner, c)
        case "p":
            let blank = isBlankLine(lineIndex(c))
            var a = lineIndex(c), b = a
            while a > 0, isBlankLine(a - 1) == blank { a -= 1 }
            while b < lastLine, isBlankLine(b + 1) == blank { b += 1 }
            if !inner { while b < lastLine, isBlankLine(b + 1) { b += 1 } }
            return Target(from: lineOffset(a), to: lineOffset(b), linewise: true, object: true)
        default: return nil
        }
    }

    private func bracketObject(_ open: unichar, _ close: unichar, _ inner: Bool, _ c: Int) -> Target? {
        var o = -1
        if c < len, ch(c) == open {
            o = c
        } else {
            var i = c < len && ch(c) == close ? c - 1 : c, depth = 0
            while i >= 0 {
                if ch(i) == close { depth += 1 } else if ch(i) == open { if depth == 0 { o = i; break }; depth -= 1 }
                i -= 1
            }
        }
        guard o >= 0 else { return nil }
        var j = o + 1, depth = 0
        while j < len {
            if ch(j) == open { depth += 1 } else if ch(j) == close { if depth == 0 { break }; depth -= 1 }
            j += 1
        }
        guard j < len else { return nil }
        return inner ? Target(from: o + 1, to: j, object: true) : Target(from: o, to: j, inclusive: true, object: true)
    }

    // MARK: Operators and edits

    private func operate(_ op: Character, _ t: Target) {
        var t = t
        if op == ">" || op == "<" { t.linewise = true }
        let r = span(t)
        switch op {
        case "y":
            yank(text(r), t.linewise)
            cursor = t.linewise ? (t.to < t.from ? t.to : cursor) : r.location
        case "d":
            delete(r, t.linewise)
        case "c":
            if t.linewise {
                yank(text(r), true)
                let indent = leadingBlanks(r.location)
                var content = r
                if NSMaxRange(r) > r.location, ch(NSMaxRange(r) - 1) == 10 { content.length -= 1 }
                replace(content, indent)
                enterInsert(at: r.location + indent.utf16.count)
            } else {
                yank(text(r), false)
                replace(r, "")
                enterInsert(at: r.location)
            }
        case ">", "<":
            let shifted = text(r).components(separatedBy: "\n").map { line -> String in
                guard !line.isEmpty else { return line }
                if op == ">" { return String(repeating: " ", count: shiftWidth) + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(shiftWidth, line.prefix { $0 == " " }.count)))
            }.joined(separator: "\n")
            replace(r, shifted)
            cursor = firstNonBlank(r.location)
        default: break
        }
    }

    /// What a target covers: whole lines for linewise targets.
    private func span(_ t: Target) -> NSRange {
        let a = min(t.from, t.to), b = max(t.from, t.to)
        if t.linewise {
            let start = lineStart(a), end = lineEnd(b) < len ? lineEnd(b) + 1 : len
            return NSRange(location: start, length: end - start)
        }
        let end = min(t.inclusive ? b + 1 : b, len)
        return NSRange(location: a, length: end - a)
    }

    private func delete(_ range: NSRange, _ linewise: Bool) {
        var r = range
        yank(text(r), linewise)
        // The last line has no newline after it: take the one before it instead.
        if linewise, NSMaxRange(r) == len, len > 0, ch(len - 1) != 10, r.location > 0 { r = NSRange(location: r.location - 1, length: r.length + 1) }
        replace(r, "")
        cursor = linewise ? firstNonBlank(min(r.location, max(0, len - 1))) : r.location
    }

    private func yank(_ text: String, _ linewise: Bool) {
        register = (linewise && !text.hasSuffix("\n") ? text + "\n" : text, linewise)
        pasteboard?.write(register.text)
        pasteboardSeen = pasteboard?.changeCount ?? -1
    }

    /// The register, unless something newer was copied in another app.
    private var pasteRegister: (text: String, linewise: Bool) {
        if let p = pasteboard, p.changeCount != pasteboardSeen, let s = p.read() {
            pasteboardSeen = p.changeCount
            register = (s, s.hasSuffix("\n"))
        }
        return register
    }

    private func paste(before: Bool, _ n: Int) {
        let reg = pasteRegister
        guard !reg.text.isEmpty else { return }
        let body = String(repeating: reg.text, count: n)
        let c = cursor
        if reg.linewise {
            let end = lineEnd(c)
            if before {
                insertAt(lineStart(c), body, cursorAt: lineStart(c))
            } else if end == len { // last line with no newline after it
                insertAt(end, "\n" + body.dropLast(), cursorAt: end + 1)
            } else {
                insertAt(end + 1, body, cursorAt: end + 1)
            }
            cursor = firstNonBlank(cursor)
        } else {
            let at = before || lineEnd(c) == lineStart(c) ? c : c + 1
            insertAt(at, body, cursorAt: at + body.utf16.count - 1)
        }
    }

    private func insertAt(_ at: Int, _ text: String, cursorAt: Int) {
        replace(NSRange(location: at, length: 0), text)
        cursor = cursorAt
    }

    private func join(_ c: Int, _ count: Int) {
        cursor = c
        for _ in 1..<count {
            let e = lineEnd(cursor)
            guard e < len else { return }
            var j = e + 1
            while j < len, isBlank(ch(j)) { j += 1 }
            let sep = j >= len || ch(j) == 10 || (e > lineStart(cursor) && isBlank(ch(e - 1))) ? "" : " "
            replace(NSRange(location: e, length: j - e), sep)
            cursor = e
        }
    }

    // MARK: Insert mode, with Markdown list continuation

    private func enterInsert(at i: Int) {
        mode = .insert
        cursor = i
        insertStart = i
        column = nil
    }

    private func openLine(below: Bool) {
        let c = cursor
        let list = listItem(c)
        if below {
            let at = lineEnd(c), prefix = list?.next ?? leadingBlanks(c)
            replace(NSRange(location: at, length: 0), "\n" + prefix)
            enterInsert(at: at + 1 + prefix.utf16.count)
        } else {
            let at = lineStart(c), prefix = list?.same ?? leadingBlanks(c)
            replace(NSRange(location: at, length: 0), prefix + "\n")
            enterInsert(at: at + prefix.utf16.count)
        }
    }

    private var typing: Bool { insertsTyping || replaying }

    private func insertKey(_ key: VimKey, force: Bool = false) -> Bool {
        let typing = typing || force
        let at = typing ? cursor : buffer.caret
        switch key {
        case .escape, .ctrl("["), .ctrl("c"):
            if let keys = changeKeys {
                lastChange = (keys, at >= insertStart ? text(NSRange(location: insertStart, length: at - insertStart)) : "")
                changeKeys = nil
            }
            mode = .normal
            cursor = clamp(at > lineStart(at) ? at - 1 : at)
            show()
            return true
        case .enter:
            newline(at)
            return true
        case .ctrl("w"):
            let ls = lineStart(at)
            var i = at
            while i > ls, isBlank(ch(i - 1)) { i -= 1 }
            if i > ls { let k = cls(i - 1, false); while i > ls, cls(i - 1, false) == k { i -= 1 } }
            replace(NSRange(location: i, length: at - i), "")
            cursor = i
            show()
            return true
        case let .char(c) where typing:
            insert(String(c), at: at)
            return true
        case .backspace where typing:
            if at > 0 { replace(NSRange(location: at - 1, length: 1), ""); cursor = at - 1; show() }
            return true
        default:
            return false
        }
    }

    private func insert(_ s: String, at: Int) {
        replace(NSRange(location: at, length: 0), s)
        cursor = at + s.utf16.count
        show()
    }

    /// Enter: in a list item, starts the next item; on an empty item, ends the list.
    private func newline(_ at: Int) {
        cursor = at
        if let list = listItem(at), at == lineEnd(at) || !list.empty {
            if list.empty {
                let r = NSRange(location: lineStart(at), length: lineEnd(at) - lineStart(at))
                replace(r, "")
                cursor = r.location
                show()
                return
            }
            insert("\n" + list.next, at: at)
        } else {
            insert("\n" + leadingBlanks(at), at: at)
        }
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d+)([.)]))( \[[ xX]\])? (.*)$"#)

    /// Markdown list item on the line at `i`: the marker for a new item after it and for one before it.
    private func listItem(_ i: Int) -> (next: String, same: String, empty: Bool)? {
        let line = text(NSRange(location: lineStart(i), length: lineEnd(i) - lineStart(i))) as NSString
        guard let m = VimEngine.listPattern.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return nil }
        func group(_ g: Int) -> String? { m.range(at: g).location == NSNotFound ? nil : line.substring(with: m.range(at: g)) }
        let indent = group(1) ?? "", box = group(5) != nil ? " [ ]" : ""
        let same = group(3) == nil ? group(2)! : group(3)! + group(4)!
        let next = group(3).flatMap(Int.init).map { "\($0 + 1)" + group(4)! } ?? same
        return (indent + next + box + " ", indent + same + box + " ", (group(6) ?? "").isEmpty)
    }

    // MARK: Visual mode

    private func visual(_ all: ArraySlice<VimKey>) -> Step {
        var keys = all
        let n1 = takeCount(&keys)
        guard let k = keys.first else { return .more }
        let linewise = mode == .visualLine
        let sel = Target(from: visualStart, to: cursor, linewise: linewise, inclusive: true)
        func finish(_ body: () -> Void) -> Step {
            body()
            if mode != .insert { mode = .normal }
            return .done
        }
        switch k {
        case .escape, .ctrl("["), .ctrl("c"): mode = .normal; return .done
        case .char("v"): mode = linewise ? .visual : .normal; return .done
        case .char("V"): mode = linewise ? .normal : .visualLine; return .done
        case .char("o"): swap(&visualStart, &cursor); return .done
        case .char("/"), .char("?"): commandLine = k == .char("/") ? "/" : "?"; return .done
        case .char("d"), .char("x"): return finish { operate("d", sel) }
        case .char("D"), .char("X"): return finish { operate("d", Target(from: sel.from, to: sel.to, linewise: true)) }
        case .char("y"): return finish { operate("y", sel); cursor = min(sel.from, sel.to) }
        case .char("Y"): return finish { operate("y", Target(from: sel.from, to: sel.to, linewise: true)); cursor = min(sel.from, sel.to) }
        case .char("c"), .char("s"): return finish { operate("c", sel) }
        case .char(">"), .char("<"):
            if case let .char(op) = k { return finish { operate(op, sel) } }
            return .fail
        case .char("J"):
            let a = min(sel.from, sel.to)
            return finish { join(a, max(2, lineIndex(max(sel.from, sel.to)) - lineIndex(a) + 1)) }
        case .char("p"), .char("P"):
            let reg = pasteRegister
            return finish {
                let r = span(sel)
                replace(r, reg.linewise && !linewise ? "\n" + reg.text : reg.text)
                cursor = r.location
            }
        case .char("~"), .char("u"), .char("U"):
            let r = span(sel)
            return finish {
                let s = text(r)
                replace(r, k == .char("u") ? s.lowercased() : k == .char("U") ? s.uppercased()
                    : String(s.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) }))
                cursor = r.location
            }
        default:
            switch target(keys, count: n1 ?? 1, explicit: n1 != nil, op: nil) {
            case .more: return .more
            case .fail: return .fail
            case let .ok(t):
                if t.object {
                    visualStart = min(t.from, t.to)
                    cursor = t.inclusive || t.linewise ? max(t.from, t.to) : max(t.from, t.to) - 1
                    if t.linewise { mode = .visualLine }
                } else {
                    move(to: t)
                }
                return .done
            }
        }
    }

    // MARK: Command line: `:` commands and `/` `?` search

    private func commandLineKey(_ key: VimKey) {
        guard var line = commandLine else { return }
        switch key {
        case .escape, .ctrl("["), .ctrl("c"): commandLine = nil; searchOp = nil
        case .backspace:
            line.removeLast()
            commandLine = line.isEmpty ? nil : line
            if commandLine == nil { searchOp = nil }
        case .enter:
            commandLine = nil
            run(line)
        case let .char(c): commandLine = line + String(c)
        default: break
        }
        cursor = clamp(cursor)
        show()
    }

    private func run(_ line: String) {
        let body = String(line.dropFirst())
        guard line.first == "/" || line.first == "?" else { return ex(body) }
        let forward = line.first == "/"
        guard let text = body.isEmpty ? lastSearch?.text : body, !text.isEmpty else { return }
        lastSearch = (text, forward)
        let op = searchOp
        searchOp = nil
        guard let i = search(text, forward: forward, from: cursor) else { message = "Pattern not found: \(text)"; return }
        if let op { operate(op, Target(from: cursor, to: i)) } else { cursor = i; column = nil }
    }

    private func ex(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        if let n = Int(cmd) { cursor = firstNonBlank(lineOffset(max(0, min(n - 1, lastLine)))); return }
        if cmd == "$" { cursor = firstNonBlank(lineOffset(lastLine)); return }
        if cmd.hasPrefix("s") || cmd.hasPrefix("%s") { return substitute(cmd) }
        message = exCommand.map { $0(cmd) ?? "" } ?? "Not an editor command: \(cmd)"
    }

    /// `:s/pattern/replacement/[gi]` on the cursor's line, `:%s/...` on every line. The pattern is a
    /// regular expression; the replacement understands `&` and `\1`...`\9`.
    private func substitute(_ cmd: String) {
        var rest = Substring(cmd)
        let everywhere = rest.hasPrefix("%")
        if everywhere { rest = rest.dropFirst() }
        rest = rest.dropFirst() // the s
        guard let delim = rest.first, !delim.isLetter, !delim.isNumber, delim != " " else { message = "Bad substitute"; return }
        let parts = rest.dropFirst().split(separator: delim, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { message = "Bad substitute"; return }
        let flags = parts.count > 2 ? String(parts[2]) : ""
        guard let re = try? NSRegularExpression(pattern: String(parts[0]), options: flags.contains("i") ? [.caseInsensitive] : []) else {
            message = "Bad pattern: \(parts[0])"; return
        }
        var template = ""
        var chars = parts[1].makeIterator()
        while let c = chars.next() {
            switch c {
            case "&": template += "$0"
            case "$": template += "\\$"
            case "\\":
                if let d = chars.next() { template += d.isNumber ? "$\(d)" : NSRegularExpression.escapedTemplate(for: String(d)) }
            default: template += String(c)
            }
        }
        let r = everywhere ? NSRange(location: 0, length: len) : NSRange(location: lineStart(cursor), length: lineEnd(cursor) - lineStart(cursor))
        var count = 0
        let lines = text(r).components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            var matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if !flags.contains("g") { matches = Array(matches.prefix(1)) }
            count += matches.count
            var out = line as NSString
            for m in matches.reversed() {
                out = out.replacingCharacters(in: m.range, with: re.replacementString(for: m, in: line, offset: 0, template: template)) as NSString
            }
            return out as String
        }
        guard count > 0 else { message = "Pattern not found: \(parts[0])"; return }
        replace(r, lines.joined(separator: "\n"))
        cursor = firstNonBlank(r.location)
        message = "\(count) substitution\(count == 1 ? "" : "s")"
    }

    /// Plain-text search, case-insensitive unless the pattern has capitals. Wraps around.
    private func search(_ text: String, forward: Bool, from c: Int) -> Int? {
        var opts: NSString.CompareOptions = text == text.lowercased() ? [.caseInsensitive] : []
        if !forward { opts.insert(.backwards) }
        let after = min(c + 1, len)
        let ranges = forward
            ? [NSRange(location: after, length: len - after), NSRange(location: 0, length: after)]
            : [NSRange(location: 0, length: c), NSRange(location: c, length: len - c)]
        for (n, r) in ranges.enumerated() {
            let m = s.range(of: text, options: opts, range: r)
            guard m.location != NSNotFound else { continue }
            if n == 1 { message = forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM" }
            return m.location
        }
        return nil
    }

    // MARK: Text helpers (UTF-16 offsets)

    private var s: NSString { buffer.string as NSString }
    private var len: Int { s.length }
    private func ch(_ i: Int) -> unichar { s.character(at: i) }
    private func text(_ r: NSRange) -> String { s.substring(with: r) }

    private func replace(_ r: NSRange, _ text: String) {
        buffer.replace(r, with: text)
        startsCache = nil
    }

    private func show() {
        var selection: NSRange?
        if mode == .visual || mode == .visualLine {
            let a = min(visualStart, cursor), b = max(visualStart, cursor)
            selection = span(Target(from: a, to: b, linewise: mode == .visualLine, inclusive: true))
        }
        buffer.show(caret: cursor, selection: selection)
    }

    /// Where each line starts.
    private var starts: [Int] {
        if let c = startsCache { return c }
        var a = [0]
        for i in 0..<len where ch(i) == 10 { a.append(i + 1) }
        startsCache = a
        return a
    }

    private func lineIndex(_ i: Int) -> Int {
        let st = starts
        var lo = 0, hi = st.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if st[mid] <= i { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// The last line, not counting the empty one after a final newline.
    private var lastLine: Int { len > 0 && ch(len - 1) == 10 ? max(0, starts.count - 2) : starts.count - 1 }
    private func lineOffset(_ n: Int) -> Int { starts[max(0, min(n, starts.count - 1))] }
    private func lineStart(_ i: Int) -> Int { starts[lineIndex(min(i, len))] }

    /// The line's newline, or the end of the text.
    private func lineEnd(_ i: Int) -> Int {
        let n = lineIndex(min(i, len))
        return n + 1 < starts.count ? starts[n + 1] - 1 : len
    }

    /// The last character a normal-mode cursor can sit on.
    private func lastCol(_ i: Int) -> Int { max(lineStart(i), lineEnd(i) - 1) }

    private func firstNonBlank(_ i: Int) -> Int {
        var j = lineStart(i)
        while j < lineEnd(i), isBlank(ch(j)) { j += 1 }
        return min(j, lastCol(i))
    }

    private func firstNonBlankOrEnd(_ i: Int) -> Int {
        var j = lineStart(i)
        while j < lineEnd(i), isBlank(ch(j)) { j += 1 }
        return j
    }

    private func leadingBlanks(_ i: Int) -> String { text(NSRange(location: lineStart(i), length: firstNonBlankOrEnd(i) - lineStart(i))) }

    private func isBlankLine(_ n: Int) -> Bool { firstNonBlankOrEnd(lineOffset(n)) == lineEnd(lineOffset(n)) }

    private func isBlank(_ u: unichar) -> Bool { u == 32 || u == 9 }

    /// 0 blank (newlines too), 1 word (letters, digits, _), 2 other. `big` (W B E) makes 1 and 2 the same.
    private func cls(_ i: Int, _ big: Bool) -> Int {
        let u = ch(i)
        if u == 32 || u == 9 || u == 10 || u == 13 { return 0 }
        if big || u == 95 { return 1 }
        if let sc = Unicode.Scalar(u), CharacterSet.alphanumerics.contains(sc) { return 1 }
        return 2
    }

    /// A normal-mode cursor sits on a character, not on a newline (unless the line is empty).
    private func clamp(_ i: Int) -> Int {
        guard len > 0 else { return 0 }
        var i = max(0, min(i, len))
        if i == len, ch(len - 1) == 10 { i = len - 1 }
        return min(i, lastCol(i))
    }

    private func takeCount(_ keys: inout ArraySlice<VimKey>) -> Int? {
        var n: Int?
        while case let .char(c)? = keys.first, c.isASCII, let d = c.wholeNumberValue, d > 0 || n != nil {
            n = (n ?? 0) * 10 + d
            keys.removeFirst()
        }
        return n
    }

    private static func describe(_ k: VimKey) -> String {
        switch k {
        case let .char(c): return String(c)
        case let .ctrl(c): return "^" + c.uppercased()
        default: return ""
        }
    }
}
