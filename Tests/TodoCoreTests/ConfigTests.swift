import Foundation
import Testing
@testable import TodoCore

private func tempConfig(_ text: String? = nil) -> Config {
    let url = FileManager.default.temporaryDirectory.appending(path: "dedo-\(UUID().uuidString)/config.toml")
    if let text {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
    return Config(url: url)
}

@Test func readsTopLevelStrings() {
    #expect(Config.pair(#"file = "~/a b/DEDO.md""#)! == ("file", "~/a b/DEDO.md"))
    #expect(Config.pair(#"file='C:\no\escapes'"#)! == ("file", #"C:\no\escapes"#))
    #expect(Config.pair(#"x = "say \"hi\" \\ ok" # trailing comment"#)! == ("x", #"say "hi" \ ok"#))
    #expect(Config.pair("# file = \"commented\"") == nil)
    #expect(Config.pair("n = 3") == nil) // not a string
    #expect(Config.pair("broken = \"no end") == nil)

    let c = tempConfig("""
    # mine
    file = "~/notes/DEDO.md"

    [later.table]
    file = "ignored, not top-level"
    """)
    #expect(c.value("file") == "~/notes/DEDO.md")
    #expect(c.value("missing") == nil)
}

@Test func setKeepsEverythingElse() throws {
    let c = tempConfig("# mine\nother = 'x'\n\n[t]\nk = \"v\"\n")
    try c.set("file", #"/a "quoted" \ path"#)
    #expect(c.value("file") == #"/a "quoted" \ path"#)
    try c.set("file", "/b")
    let text = try String(contentsOf: c.url, encoding: .utf8)
    #expect(text == "# mine\nother = 'x'\nfile = \"/b\"\n[t]\nk = \"v\"\n")

    let fresh = tempConfig() // no file or folder yet
    try fresh.set("file", "/c")
    #expect(fresh.value("file") == "/c")
    #expect(try String(contentsOf: fresh.url, encoding: .utf8).hasPrefix("# DEDO settings"))
}

@Test func readsTables() {
    let c = tempConfig("""
    file = "~/a.md"
    [dark]
    accent = "#ff79c6"
    background = '#000000'
    [ light ]
    accent = "#123456"
    """)
    #expect(c.values(in: "dark") == ["accent": "#ff79c6", "background": "#000000"])
    #expect(c.values(in: "light") == ["accent": "#123456"])
    #expect(c.values(in: "nope").isEmpty)
    #expect(c.value("accent") == nil) // table keys aren't top-level
    #expect(c.value("file") == "~/a.md")
}

@Test func durations() {
    let c = tempConfig("a = \"30s\"\nb = \"5m\"\nc = \"1h\"\nd = \"90\"\ne = \"soon\"\n")
    #expect(c.duration("a") == 30 && c.duration("b") == 300 && c.duration("c") == 3600 && c.duration("d") == 90)
    #expect(c.duration("e") == nil && c.duration("missing") == nil)
}

@Test func listFileLookupOrder() throws {
    let c = tempConfig()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(c.listFile(environment: [:]) == Config.defaultListFile)
    try c.set("file", "~/x/DEDO.md")
    #expect(c.listFile(environment: [:]).path == home + "/x/DEDO.md") // ~ expands
    #expect(c.listFile(environment: ["DEDO_FILE": "/env.md"]).path == "/env.md")
    #expect(c.listFile(flag: "/flag.md", environment: ["DEDO_FILE": "/env.md"]).path == "/flag.md")
}
