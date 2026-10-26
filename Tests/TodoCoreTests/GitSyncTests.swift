import Foundation
import Testing
@testable import TodoCore

/// A bare "remote" and clones of it, in a temp folder.
private struct Repos {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dedo-git-\(UUID().uuidString)")
    var remote: URL { dir.appending(path: "remote.git") }

    init() {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        GitSync.git(["init", "--bare", "-q", remote.path], in: dir)
    }

    /// A clone with an identity, and the list file in it.
    func clone(_ name: String) -> URL {
        GitSync.git(["clone", "-q", remote.path, name], in: dir)
        let c = dir.appending(path: name)
        GitSync.git(["config", "user.name", name], in: c)
        GitSync.git(["config", "user.email", "\(name)@example.com"], in: c)
        return c.appending(path: "DEDO.md")
    }
}

private func write(_ url: URL, _ s: String) { try! s.write(to: url, atomically: true, encoding: .utf8) }
private func read(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
private func sync(_ file: URL) -> GitSync.Outcome { GitSync(file: file)!.sync(message: "dedo: test") }

@Test func outsideARepoThereIsNothingToSync() {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dedo-plain-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    #expect(GitSync(file: dir.appending(path: "DEDO.md")) == nil)
}

@Test func syncsBetweenTwoMachines() {
    let r = Repos()
    let a = r.clone("a")
    write(a, "# Inbox\n- [ ] one\n\n# Work\n- [ ] two\n")
    #expect(sync(a) == .ok("pushed")) // first push sets the upstream
    #expect(sync(a) == .ok("up to date"))

    let b = r.clone("b")
    #expect(read(b) == read(a))
    #expect(read(b.deletingLastPathComponent().appending(path: ".gitattributes")).contains("DEDO.md merge=union"))

    // Different lines on each machine: an ordinary merge.
    write(a, "# Inbox\n- [ ] one\n- [ ] from a\n\n# Work\n- [ ] two\n")
    write(b, "# Inbox\n- [ ] one\n\n# Work\n- [ ] two\n- [ ] from b\n")
    #expect(sync(a) == .ok("pushed"))
    #expect(sync(b) == .ok("pulled and pushed"))
    #expect(sync(a) == .ok("pulled"))
    #expect(read(a) == "# Inbox\n- [ ] one\n- [ ] from a\n\n# Work\n- [ ] two\n- [ ] from b\n")
    #expect(read(a) == read(b))
}

@Test func theSameLineEditedTwiceKeepsBoth() {
    let r = Repos()
    let a = r.clone("a")
    write(a, "# Inbox\n- [ ] call mom\n")
    #expect(sync(a) == .ok("pushed"))
    let b = r.clone("b")
    write(a, "# Inbox\n- [ ] call mom tonight\n")
    write(b, "# Inbox\n- [x] call mom @done(2026-10-25 09:00)\n")
    #expect(sync(a) == .ok("pushed"))
    #expect(sync(b) == .ok("pulled and pushed")) // no conflict: union keeps both lines
    let merged = read(b)
    #expect(merged.contains("- [ ] call mom tonight") && merged.contains("- [x] call mom @done(2026-10-25 09:00)"))
}

@Test func whatUnionCantMergeIsReportedAndUndone() {
    let r = Repos()
    let a = r.clone("a")
    write(a, "# Inbox\n- [ ] one\n")
    #expect(sync(a) == .ok("pushed"))
    let b = r.clone("b")
    // b deletes the file; a edits it.
    GitSync.git(["rm", "-q", "DEDO.md"], in: b.deletingLastPathComponent())
    GitSync.git(["commit", "-qm", "gone"], in: b.deletingLastPathComponent())
    GitSync.git(["push", "-q"], in: b.deletingLastPathComponent())
    write(a, "# Inbox\n- [ ] one\n- [ ] two\n")
    guard case let .conflict(message) = sync(a) else { Issue.record("expected a conflict"); return }
    #expect(message.contains("git pull"))
    #expect(read(a) == "# Inbox\n- [ ] one\n- [ ] two\n") // our edit is still there
    let status = GitSync.git(["status", "--porcelain"], in: a.deletingLastPathComponent()).out
    #expect(status.isEmpty) // committed, and no half-finished rebase left behind
}

@Test func onlyTheListFileIsCommitted() {
    let r = Repos()
    let a = r.clone("a")
    let other = a.deletingLastPathComponent().appending(path: "notes.txt")
    write(other, "private draft\n")
    write(a, "# Inbox\n")
    #expect(sync(a) == .ok("pushed"))
    let tracked = GitSync.git(["ls-files"], in: a.deletingLastPathComponent()).out
    #expect(tracked.components(separatedBy: "\n").sorted() == [".gitattributes", "DEDO.md"])
}

@Test func withoutARemoteItJustCommits() {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dedo-local-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    GitSync.git(["init", "-q"], in: dir)
    GitSync.git(["config", "user.name", "x"], in: dir)
    GitSync.git(["config", "user.email", "x@example.com"], in: dir)
    let f = dir.appending(path: "DEDO.md")
    write(f, "# Inbox\n")
    #expect(sync(f) == .ok("committed (no remote)"))
    #expect(sync(f) == .ok("nothing to sync"))
}
