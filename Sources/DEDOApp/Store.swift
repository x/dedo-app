import AppKit
import Observation
import TodoCore

/// The whole list lives in one markdown file. The file on disk is always the truth:
/// we re-read it if it changed before every edit, and write it straight back after.
@Observable final class Store {
    enum Request { case compose, edit, help }

    var url: URL
    var doc = Doc("")
    var folder = "Inbox"
    var showAll = false
    var error: String?
    var askingFolder = false
    var editLine: Int? // the vim editor is open, starting on this line
    var syncStatus: String? // git sync, for the footer: "synced 14:32", or what went wrong
    var syncTrouble = false
    private var editorStamp: Date? // the file as the editor first saw it
    // Settings live in ~/.config/dedo/config.toml (per machine), shared with the CLI.
    private var settings = (newestFirst: true, appearance: "system")
    var paletteVersion = 0 // bumped when [dark] / [light] colors change
    @ObservationIgnored private var configStamp: Date?
    /// View > New Items: top of each list (newest first) or bottom. `new_items` in the config.
    var newestFirst: Bool {
        get { settings.newestFirst }
        set { writeConfig("new_items", newValue ? "top" : "bottom") }
    }
    /// View > Appearance: system, light or dark. `appearance` in the config.
    var appearance: String {
        get { settings.appearance }
        set { writeConfig("appearance", newValue) }
    }
    var request: Request? // for the list view, which owns the selection and the inline row
    private(set) var stamp: Date?
    private var history: [Doc] = []
    private var writable = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSweep = Date.distantPast
    @ObservationIgnored private var git: GitSync?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false // a trigger arrived mid-sync
    @ObservationIgnored private var syncDeferred = false // a rate-limited sync is scheduled
    @ObservationIgnored private var changedSinceSync = false
    @ObservationIgnored private var lastSyncStart = Date.distantPast
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var syncObservers: [NSObjectProtocol] = []
    // What's being dragged, so drop targets know without decoding a payload.
    @ObservationIgnored var dragging: Doc.Item?
    @ObservationIgnored var draggingFolder: String?

    var folders: [String] { doc.folders.compactMap(\.title) }

    init() {
        // Where the list is: ~/.config/dedo/config.toml, shared with the dedo command.
        let config = Config()
        config.migrateFromAppPreferences()
        url = config.listFile()
        if config.value("file") == nil { // write the default down, so it's there to find and change
            try? config.set("file", (config.listFile(environment: [:]).path as NSString).abbreviatingWithTildeInPath)
        }
        // Spell out the theme so it's there to edit; the same colors are the default anyway.
        if config.values(in: "dark").isEmpty, config.values(in: "light").isEmpty,
           let text = try? String(contentsOf: config.url, encoding: .utf8) {
            try? (text + Palette.standard.toml).write(to: config.url, atomically: true, encoding: .utf8)
        }
        readConfig()
        bootstrap()
        setUpSync()
        // ponytail: 1s mtime poll catches git pulls / iCloud / other editors; NSFilePresenter if it ever lags
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func open(_ name: String) { showAll = false; folder = name }
    func openAll() { showAll = true }

    /// All, then each folder in file order.
    func cycle(_ d: Int) {
        let names = folders, n = names.count + 1
        let i = showAll ? 0 : (names.firstIndex(of: folder) ?? 0) + 1
        let j = ((i + d) % n + n) % n
        j == 0 ? openAll() : open(names[j - 1])
    }

    /// Opens Inbox and asks the list for a new item at the top of today.
    func compose() {
        editLine = nil
        open("Inbox")
        mutate { $0.ensureDay(Doc.today) }
        request = .compose
    }

    func newFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mutate { $0.ensureFolder(name) }
        open(name)
    }

    func pickFile() {
        let p = NSOpenPanel()
        p.message = "Choose a markdown file, or a folder to keep DEDO.md in"
        p.canChooseFiles = true; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = url.deletingLastPathComponent()
        guard p.runModal() == .OK, var u = p.url else { return }
        if u.hasDirectoryPath { u = u.appending(path: "DEDO.md") }
        url = u
        let config = Config()
        do { try config.set("file", (u.path as NSString).abbreviatingWithTildeInPath) }
        catch { self.error = "Could not save the location to \(config.url.path). \(error.localizedDescription)" }
        bootstrap()
        setUpSync()
    }

    func mutate(_ f: (inout Doc) -> Void) {
        if mtime() != stamp { load() } // pick up external edits first so we never clobber them
        guard writable else { return }
        history.append(doc)
        f(&doc)
        save()
    }

    /// Re-finds `item` after a possible reload so we never act on a stale line range.
    func mutate(_ item: Doc.Item, _ f: (inout Doc, Doc.Item) -> Void) {
        mutate { doc in if let it = doc.items.first(where: { $0.same(as: item) }) { f(&doc, it) } }
    }

    func undo() {
        if mtime() != stamp { return load() }
        guard let prev = history.popLast() else { return }
        doc = prev
        save()
    }

    func openEditor(at line: Int) {
        editorStamp = stamp
        editLine = line
    }

    /// Saves the vim buffer. Unless forced, refuses if the file changed on disk since the editor read it.
    func saveEditor(_ text: String, force: Bool) -> String? {
        if !force, mtime() != editorStamp { return "changed on disk since you opened it, :w! to overwrite" }
        error = nil
        history.append(doc)
        doc = Doc(text, newestFirst: settings.newestFirst)
        save()
        editorStamp = stamp
        return error
    }

    private func poll() {
        if Store.mtime(Config().url) != configStamp { configChanged() }
        if mtime() != stamp { load() }
        if Date().timeIntervalSince(lastSweep) >= 60 { sweep() }
    }

    /// Moves items finished before the last 6am into `# Done` and tidies empty date headings.
    private func sweep() {
        lastSweep = Date()
        guard writable, editLine == nil else { return } // don't change the file under the editor
        var d = doc
        d.archive(d.sweep(before: Doc.sweepCutoff()))
        d.pruneEmptySections(keeping: Doc.today)
        if d != doc { doc = d; save() }
    }

    /// Creates the file on first run, merging the old one-file-per-folder layout if it's beside it.
    private func bootstrap() {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: url) }
        guard !fm.fileExists(atPath: url.path), !fm.fileExists(atPath: placeholder.path) else { return load() }
        let old = url.deletingLastPathComponent().appending(path: "Todo")
        let text = Store.merge(old) ?? "# Inbox\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Could not create \(url.lastPathComponent). \(error.localizedDescription)" }
        load()
    }

    /// The old layout: one `Name.md` per folder plus `.folders` for order. Leaves those files alone.
    private static func merge(_ dir: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".md") && !$0.hasPrefix(".") }),
              !names.isEmpty else { return nil }
        let order = (try? String(contentsOf: dir.appending(path: ".folders"), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        let rank = { (n: String) in (order.firstIndex(of: n) ?? Int.max, n == "Inbox.md" ? 0 : n == "Done.md" ? 2 : 1, n) }
        return names.sorted { rank($0) < rank($1) }.map { n in
            let name = String(n.dropLast(3))
            var lines = ((try? String(contentsOf: dir.appending(path: n), encoding: .utf8)) ?? "").components(separatedBy: "\n")
            if lines.first == "# \(name)" { lines.removeFirst() }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return "# \(name)\n" + (body.isEmpty ? "" : body + "\n")
        }.joined(separator: "\n")
    }

    private func load() {
        history = [] // undo across an external change would clobber it
        stamp = mtime()
        do {
            doc = Doc(try String(contentsOf: url, encoding: .utf8), newestFirst: settings.newestFirst)
            writable = true
        } catch {
            writable = false // never write over a file we couldn't read (e.g. still in iCloud)
            self.error = "Cannot read \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            stamp = mtime()
            changedSinceSync = true
        } catch {
            self.error = "Could not save \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    // MARK: Config

    private func readConfig() {
        let config = Config()
        configStamp = Store.mtime(config.url)
        settings = (config.value("new_items") != "bottom", config.value("appearance") ?? "system")
        doc.newestFirst = settings.newestFirst
        let (palette, problems) = Palette.from(config)
        if palette != Theme.palette { Theme.palette = palette; paletteVersion += 1 }
        if !problems.isEmpty { self.error = "config.toml: can't use the color for \(problems.joined(separator: ", ")); use a known key and \"#rrggbb\"" }
    }

    private func writeConfig(_ key: String, _ value: String) {
        let config = Config()
        do { try config.set(key, value) } catch { self.error = "Could not save \(config.url.path). \(error.localizedDescription)" }
        readConfig()
    }

    /// Edited by hand (or by an agent) while the app runs: apply it, including a new `file` or `git`.
    private func configChanged() {
        readConfig()
        let file = Config().listFile()
        if file != url { url = file; bootstrap() }
        setUpSync()
    }

    // MARK: Git sync (`git = "sync"` in the config)

    /// While the app runs: sync when it comes to the front, when it goes to the back after changes,
    /// every `git_every` (default 5m), and on quit.
    private func setUpSync() {
        let config = Config()
        syncTimer?.invalidate()
        syncObservers.forEach(NotificationCenter.default.removeObserver)
        syncObservers = []
        syncStatus = nil
        guard config.value("git") == "sync" else { git = nil; return }
        git = GitSync(file: url)
        guard git != nil else { syncStatus = "git sync is on, but \(url.lastPathComponent) isn't in a git repo"; syncTrouble = true; return }
        let nc = NotificationCenter.default
        syncObservers = [
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.syncSoon() },
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                if self?.changedSinceSync == true { self?.syncSoon() }
            },
            nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.syncBeforeQuit() },
        ]
        syncTimer = Timer.scheduledTimer(withTimeInterval: max(config.duration("git_every") ?? 300, 30), repeats: true) { [weak self] _ in
            self?.syncSoon()
        }
        syncSoon()
    }

    /// Syncs in the background, at most once every 30 seconds, and not under the open editor.
    func syncSoon() {
        guard let git, editLine == nil else { return }
        if syncing { syncAgain = true; return }
        let wait = lastSyncStart.addingTimeInterval(30).timeIntervalSinceNow
        guard wait <= 0 else {
            if !syncDeferred {
                syncDeferred = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.syncDeferred = false; self.syncSoon() }
            }
            return
        }
        syncing = true
        lastSyncStart = Date()
        changedSinceSync = false
        DispatchQueue.global(qos: .utility).async {
            let outcome = git.sync(message: Store.commitMessage)
            DispatchQueue.main.async { self.finishSync(outcome) }
        }
    }

    private func finishSync(_ outcome: GitSync.Outcome) {
        syncing = false
        switch outcome {
        case .ok: syncStatus = "synced " + Date().formatted(date: .omitted, time: .shortened); syncTrouble = false
        case let .failed(why): syncStatus = "sync failed: " + why; syncTrouble = true; changedSinceSync = true
        case let .conflict(why): syncStatus = why; syncTrouble = true
        }
        if mtime() != stamp { load() } // show what was pulled now, not at the next poll
        if syncAgain { syncAgain = false; syncSoon() }
    }

    // ponytail: quitting waits for this sync (a few seconds on a slow network)
    private func syncBeforeQuit() {
        guard let git, changedSinceSync, !syncing else { return }
        _ = git.sync(message: Store.commitMessage)
    }

    private static var commitMessage: String { "dedo: sync from \(Host.current().localizedName ?? "a Mac")" }

    private func mtime() -> Date? { Store.mtime(url) }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
