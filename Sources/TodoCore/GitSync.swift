import Foundation

/// Keeps the list file in step with its git remote: commit it, pull, push.
///
/// Only the list file (and the `.gitattributes` line below) is ever committed; the rest of the repo is
/// left alone. Edits on two machines are merged with git's union driver (`merge=union`), which keeps
/// both sides' lines instead of stopping: an item might show up twice, but nothing is lost and sync
/// doesn't get stuck. Anything union can't merge (one side deleted the file, say) is reported as a
/// conflict with the repo put back as it was before the pull, for the user to sort out.
public struct GitSync {
    public enum Outcome: Equatable {
        case ok(String) // what happened: "pushed", "pulled", "up to date", ...
        case failed(String) // git's error (no network, no credentials, ...); retrying later may work
        case conflict(String) // needs a person
    }

    public let file: URL
    public let root: URL

    /// Nil if the file isn't inside a git repo.
    public init?(file: URL) {
        let top = GitSync.git(["rev-parse", "--show-toplevel"], in: file.deletingLastPathComponent())
        guard top.ok, !top.out.isEmpty else { return nil }
        self.file = file
        root = URL(fileURLWithPath: top.out)
    }

    /// The file's path inside the repo.
    var path: String {
        let f = file.resolvingSymlinksInPath().path, r = root.resolvingSymlinksInPath().path
        return f.hasPrefix(r + "/") ? String(f.dropFirst(r.count + 1)) : file.lastPathComponent
    }

    public func sync(message: String) -> Outcome {
        let paths = [path, ".gitattributes"]
        if let problem = ensureUnionMerge() { return .failed(problem) }

        // Commit just our paths, even if other changes are staged.
        git(["add", "--"] + paths)
        var did: [String] = []
        if !git(["diff", "--cached", "--quiet", "--"] + paths).ok {
            let commit = git(["commit", "-m", message, "--"] + paths)
            guard commit.ok else { return .failed(GitSync.firstLine(commit)) }
            did.append("committed")
        }

        // A remote is one with a URL (`git remote` also lists names from global settings like remote.origin.prune).
        let remotes = git(["config", "--get-regexp", #"^remote\..*\.url$"#]).out.components(separatedBy: "\n")
            .compactMap { $0.split(separator: " ").first?.split(separator: ".").dropFirst().dropLast().joined(separator: ".") }
            .filter { !$0.isEmpty }
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            return .ok(did.isEmpty ? "nothing to sync" : "committed (no remote)")
        }
        guard git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]).ok else {
            // Never pushed: the first push sets the upstream.
            let push = git(["push", "-u", remote, "HEAD"])
            return push.ok ? .ok("pushed") : .failed(GitSync.firstLine(push))
        }

        let before = git(["rev-parse", "HEAD"]).out
        let pull = git(["pull", "--rebase", "--autostash"])
        if !pull.ok {
            if rebasing {
                git(["rebase", "--abort"])
                return .conflict("git couldn't merge \(path); run `git pull` in \(root.path) and resolve it")
            }
            return .failed(GitSync.firstLine(pull))
        }
        if git(["rev-parse", "HEAD"]).out != before, git(["rev-list", "--count", "\(before)..HEAD"]).out != "0" { did.append("pulled") }

        if (Int(git(["rev-list", "--count", "@{u}..HEAD"]).out) ?? 0) > 0 {
            let push = git(["push"])
            guard push.ok else { return .failed(GitSync.firstLine(push)) }
            did.append("pushed")
        }
        let shown = did.filter { $0 != "committed" || did.count == 1 }
        return .ok(shown.isEmpty ? "up to date" : shown.joined(separator: " and "))
    }

    /// Adds `<path> merge=union` to the repo's .gitattributes if it isn't there.
    private func ensureUnionMerge() -> String? {
        let attributes = root.appending(path: ".gitattributes")
        let existing = (try? String(contentsOf: attributes, encoding: .utf8)) ?? ""
        let pattern = path.contains(" ") ? "\"\(path)\"" : path
        let line = "\(pattern) merge=union"
        guard !existing.components(separatedBy: "\n").contains(line) else { return nil }
        let text = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
        do { try (text + "# DEDO: merge edits from different machines by keeping both sides' lines\n" + line + "\n").write(to: attributes, atomically: true, encoding: .utf8) }
        catch { return "can't write \(attributes.path): \(error.localizedDescription)" }
        return nil
    }

    private var rebasing: Bool {
        ["rebase-merge", "rebase-apply"].contains { FileManager.default.fileExists(atPath: root.appending(path: git(["rev-parse", "--git-path", $0]).out).path) }
    }

    @discardableResult
    private func git(_ args: [String]) -> (ok: Bool, out: String, err: String) { GitSync.git(args, in: root) }

    @discardableResult
    static func git(_ args: [String], in dir: URL) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" // fail instead of waiting for a password nobody will type
        env["GIT_EDITOR"] = "true"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        // ponytail: reads stdout then stderr; fine for git's short output, a pipe >64KB on stderr would stall it
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let trim = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus == 0, trim(o), trim(e))
    }

    private static func firstLine(_ r: (ok: Bool, out: String, err: String)) -> String {
        let text = r.err.isEmpty ? r.out : r.err
        return text.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? "git failed"
    }
}
