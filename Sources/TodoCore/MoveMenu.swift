import Foundation

/// The `m` menu: where an item can move, as a stack of small menus.
///
/// - From Inbox: the other folders. A folder with `##` sections opens a menu of them.
/// - From a folder with sections: its sections, then "Another folder" for the folder menu.
/// - From a folder without sections: the folder menu (Inbox first).
///
/// Done is never a target (items get there by being checked off), nor are Inbox's date sections.
public struct MoveMenu: Equatable {
    public enum Action: Equatable {
        case move(folder: String, section: String?)
        case folders // opens the folder menu
        case sections(String) // opens that folder's section menu
    }

    public struct Entry: Equatable {
        public let label: String
        public let action: Action
        public var opensMenu: Bool { if case .move = action { false } else { true } }
    }

    public private(set) var path: [String] = [] // labels of the menus opened so far
    public private(set) var typed = ""
    public private(set) var pick = 0
    private var stack: [[Entry]]
    private let folders: [String] // every folder except Done and the item's own, Inbox first
    private let sections: [String: [String]] // named (non-date) `##` sections per folder

    public init(doc: Doc, item: Doc.Item) {
        let here = doc.location(of: item)
        let own = here?.folder ?? ""
        var sections: [String: [String]] = [:]
        for f in doc.folders { if let t = f.title { sections[t] = f.sections.compactMap(\.title).filter { !Doc.isDay($0) } } }
        let names = doc.folders.compactMap(\.title).filter { $0 != "Done" && $0 != own }
        self.sections = sections
        folders = names.filter { $0 == "Inbox" } + names.filter { $0 != "Inbox" }

        let mine = sections[own] ?? []
        if own == "Inbox" || mine.isEmpty {
            stack = [MoveMenu.folderMenu(folders, sections)]
        } else {
            let others = mine.filter { $0 != here?.section }.map { Entry(label: $0, action: .move(folder: own, section: $0)) }
            let top = here?.section != nil ? [Entry(label: own, action: .move(folder: own, section: nil))] : []
            stack = [others + top + [Entry(label: "Another folder", action: .folders)]]
        }
    }

    /// The current menu, filtered by what's been typed.
    public var shown: [Entry] { stack.last!.filter { MoveMenu.fuzzy(typed, $0.label) } }

    /// j/k move until something's been typed; after that every character filters.
    public mutating func input(_ c: Character) {
        if typed.isEmpty, c == "j" || c == "k" { return step(c == "j" ? 1 : -1) }
        typed.append(c)
        pick = 0
    }

    public mutating func backspace() {
        guard !typed.isEmpty else { return }
        typed.removeLast()
        pick = 0
    }

    public mutating func step(_ d: Int) { pick = max(0, min(shown.count - 1, pick + d)) }

    /// Enter: the destination if the pick is a place, otherwise opens its menu and returns nil.
    public mutating func choose() -> (folder: String, section: String?)? {
        let s = shown
        guard s.indices.contains(pick) else { return nil }
        let e = s[pick]
        switch e.action {
        case let .move(folder, section): return (folder, section)
        case .folders: open(e.label, MoveMenu.folderMenu(folders, sections))
        case let .sections(name):
            open(e.label, [Entry(label: name, action: .move(folder: name, section: nil))]
                + (sections[name] ?? []).map { Entry(label: $0, action: .move(folder: name, section: $0)) })
        }
        return nil
    }

    /// Esc: back to the previous menu; false when there's none (close the picker).
    public mutating func back() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast(); path.removeLast()
        typed = ""; pick = 0
        return true
    }

    private static func folderMenu(_ folders: [String], _ sections: [String: [String]]) -> [Entry] {
        folders.map { n in
            n == "Inbox" || (sections[n] ?? []).isEmpty ? Entry(label: n, action: .move(folder: n, section: nil)) : Entry(label: n, action: .sections(n))
        }
    }

    private mutating func open(_ label: String, _ menu: [Entry]) {
        stack.append(menu); path.append(label)
        typed = ""; pick = 0
    }

    /// Case-insensitive subsequence match: "tw" matches "This Week".
    static func fuzzy(_ query: String, _ label: String) -> Bool {
        var rest = label.lowercased()[...]
        for c in query.lowercased() {
            guard let i = rest.firstIndex(of: c) else { return false }
            rest = rest[rest.index(after: i)...]
        }
        return true
    }
}
