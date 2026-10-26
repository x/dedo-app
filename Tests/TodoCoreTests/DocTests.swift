import Foundation
import Testing
import TodoCore

private func at(_ s: String) -> Date { Doc.stamp.date(from: s)! }

private let sample = """
# Inbox

## 2026-10-24
- [ ] first

# Work
- [ ] loose
  - https://x.com

## Today
- [ ] a

## This Week

# Done
- [x] ancient @done(2026-01-01 09:00)

"""

@Test func foldersAndSections() {
    let d = Doc(sample)
    #expect(d.text == sample)
    #expect(d.folders.map(\.title) == [nil, "Inbox", "Work", "Done"])
    let work = d.folder("Work")!
    #expect(work.sections.map(\.title) == [nil, "Today", "This Week"])
    #expect(work.sections.map { $0.items.map(\.title) } == [["loose"], ["a"], []])
    #expect(work.items[0].links == [URL(string: "https://x.com")!])
}

@Test func addingAndMovingRespectFoldersAndSections() {
    var d = Doc(sample)
    // Every list is newest first.
    d.insert(["- [ ] b"], folder: "Work", section: "Today")
    d.insert(["- [ ] c"], folder: "Work", section: "This Week")
    d.insert(["- [ ] d"], folder: "Work")
    #expect(d.folder("Work")!.sections.map { $0.items.map(\.title) } == [["d", "loose"], ["b", "a"], ["c"]])

    // Inbox: today's heading above older days, newest item first.
    d.insert(["- [ ] new1"], folder: "Inbox", today: "2026-10-25")
    d.insert(["- [ ] new2"], folder: "Inbox", today: "2026-10-25")
    #expect(d.folder("Inbox")!.sections.map(\.title) == [nil, "2026-10-25", "2026-10-24"])
    #expect(d.folder("Inbox")!.items.map(\.title) == ["new2", "new1", "first"])

    d.move(d.folder("Work")!.items[1], folder: "Work", section: "This Week")
    #expect(d.folder("Work")!.sections[2].items.map(\.title) == ["loose", "c"])
    #expect(d.folder("Work")!.sections[2].items[0].children == ["https://x.com"])

    d.move(d.folder("Inbox")!.items[2], folder: "Personal") // new folder lands above Done
    #expect(d.folders.map(\.title) == [nil, "Inbox", "Work", "Personal", "Done"])
    #expect(d.folder("Personal")!.items.map(\.title) == ["first"])

    let w = d.folder("Work")!.items // d, b, a, loose, c
    d.move(w[2], before: w[0])
    #expect(d.folder("Work")!.items.map(\.title).prefix(2) == ["a", "d"])

    d.moveFolder("Done", before: "Inbox")
    #expect(d.folders.compactMap(\.title) == ["Done", "Inbox", "Work", "Personal"])
    d.moveFolder("Done", before: nil)
    #expect(d.folders.compactMap(\.title) == ["Inbox", "Work", "Personal", "Done"])
}

@Test func oldestFirstAddsAtTheBottom() {
    var d = Doc(sample, newestFirst: false)
    d.insert(["- [ ] b"], folder: "Work", section: "Today")
    d.insert(["- [ ] d"], folder: "Work")
    #expect(d.folder("Work")!.sections.map { $0.items.map(\.title) } == [["loose", "d"], ["a", "b"], []])
    d.insert(["- [ ] new1"], folder: "Inbox", today: "2026-10-25")
    d.insert(["- [ ] new2"], folder: "Inbox", today: "2026-10-25")
    #expect(d.folder("Inbox")!.sections.map(\.title) == [nil, "2026-10-24", "2026-10-25"])
    #expect(d.folder("Inbox")!.items.map(\.title) == ["first", "new1", "new2"])
}

@Test func emptyFileGrowsFolders() {
    var d = Doc("")
    d.insert(["- [ ] x"], folder: "Inbox", today: "2026-10-25")
    #expect(d.text == "# Inbox\n\n## 2026-10-25\n- [ ] x\n")
    d.insert(["- [ ] y"], folder: "Work")
    #expect(d.text == "# Inbox\n\n## 2026-10-25\n- [ ] x\n\n# Work\n- [ ] y\n")
}

@Test func checkOffSweepAndArchive() {
    var d = Doc(sample)
    d.toggle(d.folder("Work")!.items[1], at: at("2026-10-25 14:32"))
    #expect(d.lines.contains("- [x] a @done(2026-10-25 14:32)"))
    d.toggle(d.folder("Work")!.items[0], at: at("2026-10-24 09:00"))

    let moved = d.sweep(before: at("2026-10-25 06:00")) // only yesterday's; Done is left alone
    #expect(moved.map { $0[0] } == ["- [x] loose @done(2026-10-24 09:00)"])
    d.archive(moved)
    #expect(d.folder("Done")!.items.map(\.title) == ["loose", "ancient"])
    #expect(d.folder("Work")!.items.map(\.title) == ["a"])

    d.delete(d.folder("Inbox")!.items[0])
    d.pruneEmptySections() // empty day goes, empty "This Week" stays
    #expect(d.folder("Inbox")!.sections.map(\.title) == [nil])
    #expect(d.folder("Work")!.sections.map(\.title) == [nil, "Today", "This Week"])
}

@Test func lintFindsStructureProblems() {
    #expect(Doc(sample).lint() == [])
    let bad = Doc("""
    - [ ] stray
    # Inbox
    ## 2026-10-24
    ## 2026-10-26
    ## 2026-10-25
    #Work
    - [] broken
    * [ ] star
    - [ ] open @done(2026-10-25 09:00)
    - [x] garbled @done(yesterday)
    # Inbox
    """)
    #expect(bad.lint().map(\.description) == [
        "1: item is above the first # folder; it only shows in All",
        "2: Inbox days are out of order",
        "6: heading needs a space after the #s",
        "7: checkbox must be \"- [ ] \" or \"- [x] \"",
        "8: checkbox must be \"- [ ] \" or \"- [x] \"",
        "9: open item has a @done stamp",
        "10: unreadable @done date; use @done(yyyy-MM-dd HH:mm)",
        "11: duplicate folder \"Inbox\"; only the first is shown",
    ])
}

@Test func cutoffIsTheMostRecent6am() {
    #expect(Doc.sweepCutoff(now: at("2026-10-26 05:59")) == at("2026-10-25 06:00"))
    #expect(Doc.sweepCutoff(now: at("2026-10-26 06:00")) == at("2026-10-26 06:00"))
}

@Test func pastedLinksBecomeSubItems() {
    let (t, k) = Doc.parseInput("https://a.com/x https://b.com\ncompare these  and pick one\nby friday")
    #expect(t == "compare these and pick one")
    #expect(k == ["https://a.com/x", "https://b.com", "by friday"])

    let (t2, k2) = Doc.parseInput("read https://a.com today, ask bob@x.com about example.com")
    #expect(t2 == "read today, ask bob@x.com about example.com")
    #expect(k2 == ["https://a.com"])

    #expect(Doc.link("[Title](https://a.com/p)") == URL(string: "https://a.com/p"))
    #expect(Doc.link("see https://a.com") == nil)
}
