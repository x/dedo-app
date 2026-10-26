// dedo: the DEDO to-do list from the command line, for people and AI agents.
import Foundation
import TodoCore

let help = """
dedo: read and edit the DEDO to-do list, a single markdown file.

Usage:
  dedo add [--folder=NAME] [--section=NAME] [--link=URL]... TEXT
      Add an item. Without --folder it goes to Inbox under today's date.
      URLs in TEXT, and each --link, become sub-items under it.
  dedo complete [--folder=NAME] TEXT
      Check off the open item titled TEXT (exact match first, then a unique
      case-insensitive substring). It moves to Done after the next 6am.
  dedo create-folder NAME
  dedo list [--folder=NAME]   Print the markdown (one folder, or the whole file).
  dedo lint                   Check the file's structure. Exits 1 on problems.
  dedo path                   Print where the file is, to edit it directly.
  dedo sync                   In a git repo: commit the list file, pull, push.
                              (The app does this itself while it runs.)
  dedo help                   This text. Also --help, -h.

Options:
  --file=PATH   Use this file. Otherwise $DEDO_FILE, then `file` in
                ~/.config/dedo/config.toml (the app's Choose File... sets it),
                then iCloud Drive/DEDO.md.

Per-machine settings, ~/.config/dedo/config.toml:
  file = "~/notes/DEDO.md"    where the list is
  git = "sync"                keep it in sync with its git repo while the app runs:
                              when it gains or loses focus, every git_every, on quit.
                              Edits from two machines merge by keeping both lines;
                              anything else is left for you to resolve with git.
  git_every = "5m"            how often (30s minimum)
  new_items = "top"           where new items go: top (newest first) or bottom
  appearance = "system"       the app's look: system, light or dark
  [dark] and [light]          colors as "#rrggbb" for background, sidebar, text,
                              muted, selection, accent, done, link, error

The file:
  # Inbox                         a folder; Inbox comes first
  ## 2026-10-25                   Inbox groups items by the day they were added
  - [ ] Read these and compare    an item
    - https://example.com         its links and notes, indented two spaces
  # Work
  ## Today                        optional sections inside any folder
  - [x] Done thing @done(2026-10-25 14:32)
  # Done                          checked-off items land here after 6am

Run `dedo lint` after editing the file by hand.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dedo: \(message)\n".utf8))
    exit(1)
}

// MARK: Arguments: positional words plus --name=value or --name value options.

var words: [String] = []
var options: [String: [String]] = [:]
var args = CommandLine.arguments.dropFirst()[...]
while let a = args.popFirst() {
    if a == "-h" || a == "--help" { options["help"] = [] }
    else if a.hasPrefix("--") {
        let body = a.dropFirst(2)
        if let eq = body.firstIndex(of: "=") {
            options[String(body[..<eq]), default: []].append(String(body[body.index(after: eq)...]))
        } else if let v = args.popFirst() {
            options[String(body), default: []].append(v)
        } else {
            fail("\(a) needs a value")
        }
    } else {
        words.append(a)
    }
}

let command = words.first ?? "help"
let text = words.dropFirst().joined(separator: " ")
if options["help"] != nil || command == "help" { print(help); exit(0) }

let allowed: [String: Set<String>] = [
    "add": ["folder", "section", "link", "file"], "complete": ["folder", "file"], "create-folder": ["file"],
    "list": ["folder", "file"], "lint": ["file"], "path": ["file"], "sync": ["file"],
]
guard let known = allowed[command] else { fail("unknown command \"\(command)\"; see dedo help") }
for k in options.keys where !known.contains(k) { fail("\(command) doesn't take --\(k)") }
let folderName = options["folder"]?.last

// MARK: The file: same lookup as the app.

let config = Config()
config.migrateFromAppPreferences()
let url = config.listFile(flag: options["file"]?.last)

if command == "path" { print(url.path); exit(0) }

// Never create the file here: the app's first run merges an older layout into it.
guard let original = try? String(contentsOf: url, encoding: .utf8) else {
    fail("can't read \(url.path); open the DEDO app once, or pass --file")
}
var doc = Doc(original, newestFirst: config.value("new_items") != "bottom")

func requireFolder(_ name: String) -> Doc.Folder {
    guard let f = doc.folder(name) else {
        fail("no folder \"\(name)\" (folders: \(doc.folders.compactMap(\.title).joined(separator: ", "))); dedo create-folder \(name)")
    }
    return f
}

func write(_ message: String) {
    do { try doc.text.write(to: url, atomically: true, encoding: .utf8) } catch { fail("can't write \(url.path): \(error.localizedDescription)") }
    print(message)
}

switch command {
case "add":
    var (title, children) = Doc.parseInput(text)
    children += (options["link"] ?? []).map { $0.contains("://") ? $0 : "https://\($0)" }
    guard !title.isEmpty || !children.isEmpty else { fail("add needs TEXT") }
    let name = folderName ?? "Inbox", section = options["section"]?.last
    if folderName != nil, name != "Inbox" || section != nil {
        let f = requireFolder(name)
        if let section, !f.sections.contains(where: { $0.title == section }) {
            let have = f.sections.compactMap(\.title)
            fail("no section \"\(section)\" in \(name) (" + (have.isEmpty ? "it has none" : "sections: " + have.joined(separator: ", ")) + "); add a \"## \(section)\" line to make one")
        }
    }
    doc.insert(Doc.block(title: title, children: children), folder: name, section: section)
    write("added to \(name)\(section.map { " / \($0)" } ?? ""): \(title)")

case "complete":
    guard !text.isEmpty else { fail("complete needs TEXT") }
    let pool = (folderName.map { [requireFolder($0)] } ?? doc.folders.filter { $0.title != "Done" })
        .flatMap(\.items).filter { !$0.done }
    let exact = pool.filter { $0.title == text }
    let matches = !exact.isEmpty ? exact : pool.filter { $0.title.localizedCaseInsensitiveContains(text) }
    guard let item = matches.first else { fail("no open item matches \"\(text)\"\(folderName.map { " in \($0)" } ?? "")") }
    guard matches.count == 1 || !exact.isEmpty else {
        fail("\"\(text)\" matches \(matches.count) items; be more specific:\n" + matches.map { "  \($0.title)" }.joined(separator: "\n"))
    }
    doc.toggle(item)
    write("completed: \(item.title)")

case "create-folder":
    guard !text.isEmpty, !text.contains("\n") else { fail("create-folder needs NAME") }
    if doc.folder(text) != nil { print("folder \(text) already exists"); exit(0) }
    doc.ensureFolder(text)
    write("created folder \(text)")

case "list":
    if let name = folderName { print(doc.lines[requireFolder(name).range].joined(separator: "\n")) } else { print(doc.text) }

case "sync":
    guard let git = GitSync(file: url) else { fail("\(url.path) isn't in a git repo") }
    switch git.sync(message: "dedo: sync from \(Host.current().localizedName ?? "a Mac") (dedo sync)") {
    case let .ok(what): print(what)
    case let .failed(why): fail("sync failed: \(why)")
    case let .conflict(why): fail(why)
    }

case "lint":
    let problems = doc.lint()
    for p in problems { print("\(url.path):\(p.line): \(p.message)") }
    if !problems.isEmpty { exit(1) }
    print("ok")

default:
    break
}
