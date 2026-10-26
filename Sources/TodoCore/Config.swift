import Foundation

/// Per-machine settings in `~/.config/dedo/config.toml` (or `$XDG_CONFIG_HOME/dedo/config.toml`):
/// where the list is, git sync, and how the app looks and behaves.
///
/// The file is TOML. Only `key = "string"` (or `'string'`) pairs are read, at the top level or under a
/// `[table]` header, which is all DEDO uses; anything else is left alone.
public struct Config {
    public let url: URL

    public init(url: URL = Config.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "dedo/config.toml")
    }

    public func value(_ key: String) -> String? { values(in: nil)[key] }

    /// The string pairs at the top level (nil) or under `[table]`.
    public func values(in table: String?) -> [String: String] {
        var current: String?, out: [String: String] = [:]
        for line in lines {
            if Config.isTable(line) {
                current = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
            } else if current == table, let p = Config.pair(line), out[p.key] == nil {
                out[p.key] = p.value
            }
        }
        return out
    }

    /// Sets a top-level string, keeping every other line (and comment) as it was.
    public func set(_ key: String, _ value: String) throws {
        let line = "\(key) = \"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        var all = lines
        let top = all.firstIndex(where: Config.isTable) ?? all.count
        if let i = all[..<top].firstIndex(where: { Config.pair($0)?.key == key }) {
            all[i] = line
        } else {
            if all.isEmpty { all = ["# DEDO settings for this machine (see dedo help)."] }
            all.insert(line, at: all.firstIndex(where: Config.isTable) ?? all.count)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (all.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// "30s", "5m", "1h", or plain seconds.
    public func duration(_ key: String) -> TimeInterval? {
        guard let v = value(key)?.trimmingCharacters(in: .whitespaces), let last = v.last else { return nil }
        let unit: Double? = ["s": 1, "m": 60, "h": 3600][last]
        return Double(unit == nil ? v : String(v.dropLast())).map { $0 * (unit ?? 1) }
    }

    /// Where the list is: `flag` (`--file`), then `$DEDO_FILE`, then `file` here, then iCloud Drive/DEDO.md.
    public func listFile(flag: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = flag ?? environment["DEDO_FILE"] ?? value("file") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Config.defaultListFile
    }

    public static var defaultListFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        return (FileManager.default.fileExists(atPath: icloud.path) ? icloud : home.appending(path: "Documents")).appending(path: "DEDO.md")
    }

    /// Earlier versions kept the path in the app's preferences; move it here once.
    public func migrateFromAppPreferences() {
        guard value("file") == nil, let defaults = UserDefaults(suiteName: "local.dedo"),
              let old = defaults.url(forKey: "file"), (try? set("file", (old.path as NSString).abbreviatingWithTildeInPath)) != nil else { return }
        defaults.removeObject(forKey: "file")
    }

    private var lines: [String] {
        (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }

    private static func isTable(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("[") }

    /// `key = "value"` or `key = 'value'`; nil for comments, blank lines and anything else.
    static func pair(_ line: String) -> (key: String, value: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        let key = t[..<eq].trimmingCharacters(in: .whitespaces)
        let rest = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let quote = rest.first, quote == "\"" || quote == "'", !key.isEmpty else { return nil }
        var value = "", escaped = false
        for c in rest.dropFirst() {
            if escaped {
                value.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaped = false
            } else if c == "\\", quote == "\"" {
                escaped = true // literal ('...') strings have no escapes
            } else if c == quote {
                return (key, value)
            } else {
                value.append(c)
            }
        }
        return nil // unterminated
    }
}
