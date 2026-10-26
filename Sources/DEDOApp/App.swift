import CoreText
import LinkPresentation
import SwiftUI
import TodoCore
import UniformTypeIdentifiers
import VimKit

@main struct DedoApp: App {
    @State private var store = Store()

    init() {
        NSApplication.shared.setActivationPolicy(.regular) // so `swift run` gets a Dock icon and key focus
        if let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(store).frame(minWidth: 420, minHeight: 280)
                .id(store.paletteVersion) // new colors: rebuild with them
                .onAppear(perform: applyAppearance)
                .onChange(of: store.appearance, applyAppearance)
        }
        .defaultSize(width: 600, height: 520)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Item") { store.compose() }.keyboardShortcut("n")
                Button("New Item in Inbox") { store.compose() }.keyboardShortcut("o")
                Button("New Folder…") { store.askingFolder = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Choose File…") { store.pickFile() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Edit Markdown") { store.request = .edit }.keyboardShortcut("e")
                Button("Keyboard Shortcuts") { store.request = .help }.keyboardShortcut("/")
                Button("Previous Folder") { store.cycle(-1) }.keyboardShortcut("{", modifiers: .command)
                Button("Next Folder") { store.cycle(1) }.keyboardShortcut("}", modifiers: .command)
                Picker("New Items", selection: $store.newestFirst) {
                    Text("On Top (Newest First)").tag(true)
                    Text("At Bottom (Oldest First)").tag(false)
                }
                Picker("Appearance", selection: $store.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
        }
    }

    /// nil follows the system setting.
    private func applyAppearance() {
        NSApp.appearance = store.appearance == "light" ? NSAppearance(named: .aqua)
            : store.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

/// The colors, by role. `[dark]` and `[light]` in config.toml override any of them with "#rrggbb".
struct Palette: Equatable {
    var dark: [String: UInt32]
    var light: [String: UInt32]

    // Dracula (~/.config/kitty/dark-theme.auto.conf) and Alucard (~/.config/kitty/light-theme.auto.conf).
    static let standard = Palette(
        dark: ["background": 0x282a36, "sidebar": 0x21222c, "text": 0xf8f8f2, "selection": 0x44475a, "muted": 0x6272a4,
               "accent": 0xbd93f9, "done": 0x50fa7b, "link": 0x8be9fd, "error": 0xff5555],
        light: ["background": 0xfffbeb, "sidebar": 0xeeebdc, /* Alucard's #ceccc0 border, 35% over the background */
                "text": 0x1f1f1f, "selection": 0xcfcfde, "muted": 0x6c664b,
                "accent": 0x644ac9, "done": 0x14710a, "link": 0x036a96, "error": 0xcb3a2a])

    static let roles = ["background", "sidebar", "text", "muted", "selection", "accent", "done", "link", "error"]

    /// The palette as `[dark]` and `[light]` tables, for writing into config.toml.
    var toml: String {
        [("dark", dark, "Dracula"), ("light", light, "Alucard")].map { name, colors, theme in
            "\n# \(theme). Colors are \"#rrggbb\"; delete a line to use the default.\n[\(name)]\n"
                + Palette.roles.map { "\($0) = \"#\(String(format: "%06x", colors[$0]!))\"" }.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    /// The standard palette with the config's colors laid over it, and any keys it couldn't use.
    static func from(_ config: Config) -> (Palette, problems: [String]) {
        var p = standard, problems: [String] = []
        for mode in ["dark", "light"] {
            for (key, value) in config.values(in: mode) {
                var hex = value.trimmingCharacters(in: .whitespaces)
                if hex.hasPrefix("#") { hex.removeFirst() }
                guard standard.dark[key] != nil, hex.count == 6, let rgb = UInt32(hex, radix: 16) else { problems.append("\(mode).\(key)"); continue }
                if mode == "dark" { p.dark[key] = rgb } else { p.light[key] = rgb }
            }
        }
        return (p, problems.sorted())
    }
}

enum Theme {
    static var palette = Palette.standard
    static var bg: Color { color("background") }
    static var sidebar: Color { color("sidebar") }
    static var fg: Color { color("text") }
    static var selection: Color { color("selection") }
    static var comment: Color { color("muted") }
    static var purple: Color { color("accent") }
    static var green: Color { color("done") }
    static var cyan: Color { color("link") }
    static var red: Color { color("error") }
    private static func color(_ role: String) -> Color { Color(dark: palette.dark[role]!, light: palette.light[role]!) }
}

extension Color {
    /// Resolves per appearance, so the system setting (or the View > Appearance override) picks the palette.
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { a in
            let hex = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

extension Font {
    /// Victor Mono everywhere, as on the IEOR 4570 site: regular for text, bold for headings.
    static func mono(_ size: CGFloat, _ weight: String = "Regular") -> Font { .custom("VictorMonoNFM-\(weight)", size: size) }
}

extension View {
    /// Flat row; the cursor is a purple bar plus a faint wash.
    func rowStyle(selected: Bool) -> some View {
        font(.mono(14))
            .padding(.vertical, 5).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection.opacity(0.5) : .clear)
            .overlay(alignment: .leading) { if selected { Theme.purple.frame(width: 2) } }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var folderName = ""
    @FocusState private var naming: Bool
    @State private var dropTarget: String?
    @State private var endTargeted = false

    var body: some View {
        // Plain HStack, not NavigationSplitView: the system sidebar is a floating glass panel on macOS 26.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("All")
                    .font(.mono(14, store.showAll ? "Bold" : "Regular"))
                    .foregroundStyle(store.showAll ? Theme.fg : Theme.comment)
                    .rowStyle(selected: store.showAll)
                    .contentShape(Rectangle())
                    .onTapGesture { store.openAll() }
                ForEach(store.folders, id: \.self) { name in
                    let on = !store.showAll && name == store.folder
                    Text(name)
                        .font(.mono(14, on ? "Bold" : "Regular"))
                        .foregroundStyle(on ? Theme.fg : Theme.comment)
                        .rowStyle(selected: on)
                        .background(dropTarget == name && store.dragging != nil ? Theme.purple.opacity(0.25) : .clear)
                        .overlay(alignment: .top) { if dropTarget == name && store.draggingFolder != nil { Theme.purple.frame(height: 2) } }
                        .contentShape(Rectangle())
                        .onTapGesture { store.open(name) }
                        .onDrag { store.draggingFolder = name; store.dragging = nil; return NSItemProvider(object: name as NSString) }
                        .onDrop(of: [.text], isTargeted: targeted(name)) { _ in drop(on: name) }
                }
                // Empty space below the folders: drop here to move a folder to the end.
                Color.clear.contentShape(Rectangle())
                    .overlay(alignment: .top) { if dropTarget == nil, endTargeted, store.draggingFolder != nil { Theme.purple.frame(height: 2) } }
                    .onDrop(of: [.text], isTargeted: $endTargeted) { _ in drop(on: nil) }
                if store.askingFolder {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("new folder").font(.mono(10)).foregroundStyle(Theme.comment)
                        TextField("", text: $folderName).textFieldStyle(.plain).font(.mono(14))
                            .focused($naming)
                            .onAppear { naming = true }
                            .onSubmit { store.newFolder(folderName); folderName = ""; store.askingFolder = false }
                            .onExitCommand { folderName = ""; store.askingFolder = false }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .padding(.top, 36) // clear the traffic lights
            .frame(width: 160)
            .background(Theme.sidebar)
            TodoList().padding(.top, 20)
        }
        // The editor covers everything, folders included: it edits them too. The list stays alive
        // underneath so :wq lands back where you were.
        .overlay { if let line = store.editLine { EditorPane(line: line).background(Theme.bg) } }
        .background(Theme.bg)
        .ignoresSafeArea()
        .tint(Theme.purple)
        .foregroundStyle(Theme.fg)
        .onAppear { NSApp.activate() }
    }

    private func targeted(_ name: String) -> Binding<Bool> {
        Binding(get: { dropTarget == name }, set: { dropTarget = $0 ? name : (dropTarget == name ? nil : dropTarget) })
    }

    /// Folder dropped: move its `#` block above `name` (nil = end). Item dropped on a folder: move it there.
    private func drop(on name: String?) -> Bool {
        defer { store.dragging = nil; store.draggingFolder = nil }
        if let f = store.draggingFolder { store.mutate { $0.moveFolder(f, before: name) }; return true }
        if let item = store.dragging, let name { store.mutate(item) { $0.move($1, folder: name) }; return true }
        return false
    }
}

/// The whole file in VimKit's editor, with its mode line.
struct EditorPane: View {
    let line: Int
    @Environment(Store.self) private var store
    @State private var status = ""
    @State private var saved: String? // the text as last written, for :q's unsaved check

    var body: some View {
        VStack(spacing: 0) {
            // Which file this is, in the title bar strip beside the traffic lights.
            Text((store.url.path as NSString).abbreviatingWithTildeInPath)
                .font(.mono(11)).foregroundStyle(Theme.fg.opacity(0.35))
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.leading, 84).padding(.trailing, 20) // clear of the traffic lights
            VimEditor(text: store.doc.text, line: line,
                      style: .init(font: NSFont(name: "VictorMonoNFM-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   text: NSColor(Theme.fg), background: NSColor(Theme.bg), cursor: NSColor(Theme.purple)),
                      status: { status = $0 },
                      command: command)
            Text(status.isEmpty ? ":wq save and return   :q! discard" : status)
                .font(.mono(10)).foregroundStyle(Theme.fg.opacity(0.25))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .onAppear { saved = store.doc.text }
    }

    /// :w, :wq, :x and :q, each with ! to force. VimKit does the rest (:3, :%s, ...).
    private func command(_ cmd: String, _ text: String) -> String? {
        let force = cmd.hasSuffix("!"), name = force ? String(cmd.dropLast()) : cmd
        switch name {
        case "w", "wq", "x":
            if let err = store.saveEditor(text, force: force) { return err }
            saved = text
            if name != "w" { store.editLine = nil }
            return "written"
        case "q":
            guard force || text == saved else { return "unsaved changes: :wq to save, :q! to discard" }
            store.editLine = nil
            return nil
        default:
            return "Not an editor command: \(cmd)"
        }
    }
}

struct TodoList: View {
    enum Focus: Hashable { case list, draft, edit }
    enum Spot: Hashable { case row(Int), header(String, String?), end }
    enum Place { case above(Doc.Item), new, today }
    /// Inline new-item row (o, O): drawn at `row` within its section, inserted per `place`.
    struct Draft { var folder: String; var section: String?; var row: Int; var place: Place }
    /// `#` in All; `##` in a folder (as big as `#` in All), or under its `#` in All (smaller).
    enum Header { case folder(String), section(String), subsection(String) }
    /// A run of items on screen, under its headers.
    struct Block { let folder: String; let section: Doc.Section; let headers: [Header] }

    @Environment(Store.self) private var store
    @FocusState private var focus: Focus?
    @State private var sel = 0
    @State private var pending = ""
    @State private var draft: Draft?
    @State private var draftText = ""
    @State private var editing: Doc.Item?
    @State private var editText = ""
    @State private var editAtStart = false // I puts the cursor at the start, i and A at the end
    // Move picker (m): the item and its menu of folders and sections (TodoCore's MoveMenu).
    @State private var moving: Doc.Item?
    @State private var menu: MoveMenu?
    @State private var dropSpot: Spot?
    @State private var help = false

    /// Folder view: its sections under `##` headers. All: the same, for every folder except Done,
    /// under `#` headers; empty folders and sections are left out.
    private var blocks: [Block] {
        let doc = store.doc
        guard store.showAll else {
            return doc.folder(store.folder)?.sections.map { Block(folder: store.folder, section: $0, headers: $0.title.map { [.section($0)] } ?? []) } ?? []
        }
        return doc.folders.filter { $0.title != "Done" && !$0.items.isEmpty }.flatMap { f in
            f.sections.filter { !$0.items.isEmpty }.enumerated().map { j, s in
                Block(folder: f.title ?? "", section: s,
                      headers: (j == 0 ? f.title.map { [.folder($0)] } ?? [] : []) + (s.title.map { [.subsection($0)] } ?? []))
            }
        }
    }

    private var rows: [Doc.Item] { blocks.flatMap(\.section.items) }

    var body: some View {
        Group {
            if help { helpView } else { list }
        }
        .background(Theme.bg)
        .onChange(of: store.showAll ? "\u{0}all" : store.folder) {
            sel = 0; editing = nil; moving = nil; menu = nil
            if let d = draft, !store.showAll, d.folder == store.folder {} else { draft = nil }
            focus = .list
        }
        .onChange(of: store.request) { handleRequest() }
        .onChange(of: store.askingFolder) { if !store.askingFolder { backToList() } }
        .onChange(of: store.editLine) { if store.editLine == nil { backToList() } }
    }

    private var list: some View {
        let blocks = blocks, rows = blocks.flatMap(\.section.items)
        var starts: [Int] = [], n = 0
        for b in blocks { starts.append(n); n += b.section.items.count }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let e = store.error {
                        Text(e).font(.mono(11)).foregroundStyle(Theme.red).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { bi, b in
                        // A header is first if nothing visible is above it (an empty untitled top part doesn't count).
                        let first = !blocks[..<bi].contains { !$0.headers.isEmpty || !$0.section.items.isEmpty }
                        ForEach(Array(b.headers.enumerated()), id: \.offset) { hi, h in
                            header(h, folder: b.folder, top: first && hi == 0 ? 0 : hi > 0 ? 2 : 22)
                        }
                        let here = draft.map { $0.folder == b.folder && $0.section == b.section.title } ?? false
                        ForEach(Array(b.section.items.enumerated()), id: \.offset) { j, item in
                            if here, draft?.row == j { draftField }
                            row(item, starts[bi] + j)
                            if moving != nil, starts[bi] + j == sel { picker }
                        }
                        if here, let d = draft, d.row >= b.section.items.count { draftField }
                    }
                    if rows.isEmpty, draft == nil {
                        Text(store.showAll ? "Nothing to do." : "Empty. Press o to add, ? for keys.").font(.mono(13, "Italic"))
                            .foregroundStyle(Theme.comment).padding(.horizontal, 12)
                    }
                    // Drop zone below the last item.
                    Color.clear.frame(height: 80).contentShape(Rectangle())
                        .overlay(alignment: .top) { if dropSpot == .end { Theme.purple.frame(height: 2) } }
                        .onDrop(of: [.text], isTargeted: targeted(.end)) { _ in
                            if let last = rows.last { return dropMove { doc, it in if let t = doc.items.first(where: { $0.same(as: last) }) { doc.move(it, after: t) } } }
                            let f = store.folder
                            return dropMove { $0.move($1, folder: f) }
                        }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: sel) { proxy.scrollTo(sel) }
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0, rows) ? .handled : .ignored }
        .onAppear { focus = .list; handleRequest() }
        .safeAreaInset(edge: .bottom) {
            footer(moving == nil ? "o new  i edit  x done  dd del  u undo  m move  gx open  ? keys" : "type or j k  enter choose  esc back")
        }
    }

    /// The keys reminder, with git sync's status on the right when it's on.
    private func footer(_ s: String) -> some View {
        HStack(spacing: 12) {
            Text(s).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            if let status = store.syncStatus {
                Text(status).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(store.syncTrouble ? Theme.red : Theme.fg.opacity(0.25))
                    .help(status)
            }
        }
        .font(.mono(10)).foregroundStyle(Theme.fg.opacity(0.25))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bg)
    }

    /// Dropping an item on a header moves it into that folder or section.
    private func header(_ h: Header, folder: String, top: CGFloat) -> some View {
        let (text, size, spot): (String, CGFloat, Spot) = switch h {
        case .folder(let name): (name, 18, .header(name, nil))
        case .section(let title): (Self.label(title), 18, .header(folder, title))
        case .subsection(let title): (Self.label(title), 15, .header(folder, title))
        }
        let rule: Bool = if case .subsection = h { false } else { true }
        return VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.mono(size, "Italic")).foregroundStyle(Theme.purple)
            if rule { Theme.selection.frame(height: 1) }
        }
        .padding(.horizontal, 12).padding(.top, top).padding(.bottom, rule ? 6 : 2)
        .background(dropSpot == spot ? Theme.purple.opacity(0.15) : .clear)
        .onDrop(of: [.text], isTargeted: targeted(spot)) { _ in
            guard case let .header(f, s) = spot else { return false }
            return dropMove { $0.move($1, folder: f, section: s) }
        }
    }

    /// Inbox's `## yyyy-MM-dd` headings read as Today, Yesterday, or the date.
    static func label(_ title: String) -> String {
        guard Doc.isDay(title), let d = Doc.day.date(from: title) else { return title }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((["move to"] + (menu?.path ?? [])).joined(separator: " > ") + "  " + (menu?.typed ?? ""))
                .font(.mono(11)).foregroundStyle(Theme.comment)
            ForEach(Array((menu?.shown ?? []).enumerated()), id: \.offset) { j, e in
                Text(e.label + (e.opensMenu ? "  >" : "")).font(.mono(13, j == menu?.pick ? "Bold" : "Regular"))
                    .foregroundStyle(j == menu?.pick ? Theme.purple : Theme.fg)
            }
            if menu?.shown.isEmpty == true { Text("no match").font(.mono(13)).foregroundStyle(Theme.comment) }
        }
        .padding(.leading, 33).padding(.vertical, 6)
    }

    /// Picker keys go to the menu; Enter on a place moves the item there.
    private func handlePicker(_ k: KeyPress, _ item: Doc.Item) {
        guard var m = menu else { return }
        defer { if moving != nil { menu = m } }
        switch k.key {
        case .escape: if !m.back() { moving = nil; menu = nil }
        case .return:
            if let dest = m.choose() {
                store.mutate(item) { $0.move($1, folder: dest.folder, section: dest.section) }
                moving = nil; menu = nil
            }
        case .downArrow: m.step(1)
        case .upArrow: m.step(-1)
        default:
            guard let c = k.characters.first, let v = c.unicodeScalars.first?.value,
                  k.modifiers.isDisjoint(with: [.command, .control]) else { return }
            // Backspace arrives as DEL (0x7F), not SwiftUI's .delete (0x08), so it used to be typed in and
            // nothing matched. Other control and function keys (0xF700...) are ignored, not typed.
            if v == 0x7F || v == 0x08 { m.backspace() } else if v >= 0x20, !(0xF700...0xF8FF).contains(v) { m.input(c) }
        }
    }

    private func locate(_ item: Doc.Item) -> (folder: String, section: String?)? {
        store.doc.location(of: item).map { ($0.folder ?? "", $0.section) }
    }

    private func row(_ item: Doc.Item, _ i: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkbox(item.done)
            VStack(alignment: .leading, spacing: 3) {
                if editing?.same(as: item) == true {
                    TextField("", text: $editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .edit)
                        .onAppear {
                            focus = .edit
                            // macOS selects the whole field on focus; put a caret where vim would instead.
                            let move = editAtStart ? #selector(NSResponder.moveToBeginningOfDocument(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
                            DispatchQueue.main.async { NSApp.sendAction(move, to: nil, from: nil) }
                        }
                        .onSubmit(commitEdit)
                        .onExitCommand(perform: commitEdit)
                } else {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .strikethrough(item.done, color: Theme.comment)
                        .foregroundStyle(item.done || item.title.isEmpty ? Theme.comment : Theme.fg)
                }
                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                    if let url = Doc.link(child) { LinkLine(url: url) }
                    else { Text(child).font(.mono(12)).foregroundStyle(Theme.comment) }
                }
            }
            if let d = item.doneAt {
                Spacer(minLength: 8)
                Text(d.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.mono(11)).foregroundStyle(Theme.comment).fixedSize()
            }
        }
        .rowStyle(selected: i == sel && (focus == .list || focus == .edit))
        .overlay(alignment: .top) { if dropSpot == .row(i) { Theme.purple.frame(height: 2) } }
        .onDrag { store.dragging = item; store.draggingFolder = nil; return NSItemProvider(object: item.title as NSString) }
        .onDrop(of: [.text], isTargeted: targeted(.row(i))) { _ in
            dropMove { doc, it in if let t = doc.items.first(where: { $0.same(as: item) }) { doc.move(it, before: t) } }
        }
        .id(i)
    }

    private func targeted(_ spot: Spot) -> Binding<Bool> {
        Binding(get: { dropSpot == spot }, set: { dropSpot = $0 ? spot : (dropSpot == spot ? nil : dropSpot) })
    }

    /// Applies a move to whatever is being dragged.
    private func dropMove(_ f: (inout Doc, Doc.Item) -> Void) -> Bool {
        guard let src = store.dragging else { return false }
        store.dragging = nil
        store.mutate(src, f)
        return true
    }

    private func checkbox(_ done: Bool) -> some View {
        Circle().strokeBorder(done ? Theme.green : Theme.comment, lineWidth: 1.5)
            .background(Circle().fill(done ? Theme.green : .clear).padding(3))
            .frame(width: 11, height: 11)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
    }

    private var draftField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkbox(false)
            TextField("", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focus, equals: .draft)
                .onAppear { focus = .draft }
                .onSubmit { submitDraft(keepOpen: true) }
                .onExitCommand { submitDraft(keepOpen: false) }
        }
        .rowStyle(selected: true)
    }

    /// A new item starts at the top (or bottom, per View > New Items) of the selected item's section;
    /// in Inbox, today's. With `above`, it goes right above the selected item instead.
    private func openDraft(at item: Doc.Item?, above: Bool) {
        draftText = ""
        let loc = item.flatMap(locate)
        if above, let item, let loc,
           let j = store.doc.folder(loc.folder)?.sections.first(where: { $0.title == loc.section })?.items.firstIndex(where: { $0.same(as: item) }) {
            draft = Draft(folder: loc.folder, section: loc.section, row: j, place: .above(item))
            return
        }
        let f = loc?.folder ?? (store.showAll ? "Inbox" : store.folder)
        if f == "Inbox" {
            if store.showAll { return store.compose() } // today may not be on screen in All
            store.mutate { $0.ensureDay(Doc.today) }
            draft = Draft(folder: f, section: Doc.today, row: newRow(f, Doc.today), place: .today)
        } else {
            if store.doc.folder(f) == nil { store.mutate { $0.ensureFolder(f) } }
            draft = Draft(folder: f, section: loc?.section, row: newRow(f, loc?.section), place: .new)
        }
    }

    /// Where the inline row sits for a new item: first, or after the last item.
    private func newRow(_ folder: String, _ section: String?) -> Int {
        store.newestFirst ? 0 : store.doc.folder(folder)?.sections.first { $0.title == section }?.items.count ?? 0
    }

    /// Enter adds and opens a fresh row (Enter on an empty row closes it); Esc adds and closes.
    private func submitDraft(keepOpen: Bool) {
        let (title, kids) = Doc.parseInput(draftText)
        draftText = ""
        guard let d = draft, !title.isEmpty || !kids.isEmpty else { draft = nil; backToList(); return }
        let block = Doc.block(title: title, children: kids)
        store.mutate { doc in
            switch d.place {
            case .today: doc.addToDay(block, day: Doc.today)
            case .new: doc.insert(block, folder: d.folder, section: d.section)
            case let .above(a):
                if let t = doc.items.first(where: { $0.same(as: a) }) {
                    doc.lines.insert(contentsOf: block, at: t.range.lowerBound)
                } else {
                    doc.insert(block, folder: d.folder, section: d.section)
                }
            }
        }
        let items = store.doc.folder(d.folder)?.sections.first { $0.title == d.section }?.items ?? []
        if items.indices.contains(d.row), let i = rows.firstIndex(where: { $0.same(as: items[d.row]) }) { sel = i }
        // Enter keeps the row open: above the newest, below the newest, or above the same item.
        if !keepOpen {
            draft = nil; backToList()
        } else if case .above = d.place {
        } else if !store.newestFirst {
            draft?.row += 1
        }
    }

    private func startEdit(_ item: Doc.Item, atStart: Bool = false) { editAtStart = atStart; editing = item; editText = item.title }

    /// Hands the keyboard back to the list once the text field that had it is gone; doing it in the
    /// same update loses focus entirely and j/k stop working.
    private func backToList() { DispatchQueue.main.async { focus = .list } }

    private func commitEdit() {
        guard let item = editing else { return }
        let (title, kids) = Doc.parseInput(editText)
        if title != item.title || !kids.isEmpty { store.mutate(item) { $0.edit($1, title: title, adding: kids) } }
        editing = nil
        backToList()
    }

    /// Menu actions that depend on the selection or the inline row.
    private func handleRequest() {
        guard let r = store.request else { return }
        store.request = nil
        switch r {
        case .compose:
            help = false; editing = nil; moving = nil; menu = nil; draftText = ""; sel = 0
            draft = Draft(folder: "Inbox", section: Doc.today, row: newRow("Inbox", Doc.today), place: .today)
        case .edit:
            openEditor(rows.indices.contains(sel) ? rows[sel] : nil)
        case .help:
            help = true
        }
    }

    /// Edits the whole file; the item (or folder) we're on is where the cursor starts.
    private func openEditor(_ item: Doc.Item?) {
        let line = item.flatMap { it in store.doc.items.first { $0.same(as: it) } }?.range.lowerBound
            ?? (store.showAll ? 0 : store.doc.folder(store.folder)?.range.lowerBound ?? 0)
        store.openEditor(at: line)
    }

    static let keys: [(String, String)] = [
        ("j k", "move down, up"),
        ("gg G", "top, bottom"),
        ("o", "new item in this list (Inbox: today); top or bottom per View > New Items"),
        ("O", "new item above the cursor"),
        ("i, A, enter", "edit the title, cursor at the end"),
        ("I", "edit the title, cursor at the start"),
        ("x, space", "check off, reopen"),
        ("dd", "delete"),
        ("u", "undo"),
        ("m", "move to a folder or section"),
        ("gx", "open the links"),
        ("gt gT", "next, previous folder"),
        ("cmd } cmd {", "next, previous folder"),
        ("cmd N, cmd O", "new item in Inbox"),
        ("cmd E", "edit the markdown (vim, :wq to return)"),
        ("cmd shift N", "new folder"),
        ("cmd shift O", "choose the markdown file"),
        ("?", "these keys"),
    ]

    private var helpView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("Keys").font(.mono(18, "Italic")).foregroundStyle(Theme.purple)
                Theme.selection.frame(height: 1).padding(.bottom, 8)
                ForEach(Self.keys, id: \.0) { k, d in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(k).font(.mono(13, "Bold")).frame(width: 120, alignment: .leading)
                        Text(d).font(.mono(13)).foregroundStyle(Theme.comment)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { k in
            if k.characters == "?" || k.key == .escape || k.characters == "q" { help = false }
            return .handled
        }
        .onAppear { focus = .list }
        .safeAreaInset(edge: .bottom) { footer("? or esc to close") }
    }

    /// Normal-mode vim keys. Text fields own the keyboard while focused (insert mode); Esc returns here.
    private func handle(_ k: KeyPress, _ rows: [Doc.Item]) -> Bool {
        guard focus == .list else { return false }
        store.error = nil
        if let m = moving { handlePicker(k, m); return true }
        sel = min(sel, max(0, rows.count - 1))
        let item = rows.indices.contains(sel) ? rows[sel] : nil
        // ctrl-x ctrl-e: edit the markdown, emacs/readline style.
        if k.modifiers.contains(.control) {
            let c = k.key.character
            if pending == "C-x", c == "e" || c == "\u{05}" { pending = ""; openEditor(item); return true }
            pending = c == "x" || c == "\u{18}" ? "C-x" : ""
            return pending == "C-x"
        }
        let move = { (d: Int) in sel = max(0, min(rows.count - 1, sel + d)) }
        switch k.key {
        case .downArrow: move(1); return true
        case .upArrow: move(-1); return true
        case .return: if let item { startEdit(item) }; return true
        case .escape: pending = ""; return true
        default: break
        }
        guard k.modifiers.isDisjoint(with: [.command, .option]), let c = k.characters.first else { return false }
        let seq = pending + String(c)
        pending = ""
        switch seq {
        case "j": move(1)
        case "k": move(-1)
        case "gg": sel = 0
        case "G": sel = max(0, rows.count - 1)
        case "x", " ": if let item { store.mutate(item) { $0.toggle($1) } }
        case "o": openDraft(at: item, above: false)
        case "O": openDraft(at: item, above: true)
        case "i", "c", "A": if let item { startEdit(item) }
        case "I": if let item { startEdit(item, atStart: true) }
        case "dd": if let item { store.mutate(item) { $0.delete($1) } }
        case "m": if let item { moving = item; menu = MoveMenu(doc: store.doc, item: item) }
        case "u": store.undo()
        case "gx": item?.links.forEach { NSWorkspace.shared.open($0) }
        case "gt": store.cycle(1)
        case "gT": store.cycle(-1)
        case "?": help = true
        case "g", "d": pending = seq
        default: return false
        }
        return true
    }
}

/// One-line link preview: favicon, page title, host.
struct LinkLine: View {
    let url: URL
    @State private var preview: Preview?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let img = preview?.icon { Image(nsImage: img).resizable().scaledToFit() }
                else { RoundedRectangle(cornerRadius: 2).fill(Theme.selection) }
            }
            .frame(width: 13, height: 13)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            // One Text so the host wraps with the title instead of squeezing it.
            Text("\(preview?.title ?? url.host() ?? "link")  \(Text(url.host() ?? "").font(.mono(10)).foregroundStyle(Theme.cyan))")
                .font(.mono(13))
        }
        .task(id: url) { preview = await Preview.load(url) }
    }
}

struct Preview {
    var title: String?
    var icon: NSImage?

    // ponytail: in-memory cache, refetched each launch; persist to disk if launch feels slow
    @MainActor private static var cache: [URL: Preview] = [:]

    @MainActor static func load(_ url: URL) async -> Preview {
        if let p = cache[url] { return p }
        let meta = try? await LPMetadataProvider().startFetchingMetadata(for: url)
        let p = Preview(title: meta?.title, icon: await image(meta?.iconProvider ?? meta?.imageProvider))
        cache[url] = p
        return p
    }

    private static func image(_ provider: NSItemProvider?) async -> NSImage? {
        guard let provider else { return nil }
        return await withCheckedContinuation { c in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                c.resume(returning: data.flatMap(NSImage.init(data:)))
            }
        }
    }
}
