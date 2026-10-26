import Testing
import TodoCore

private let doc = Doc("""
# Inbox

## 2026-10-25
- [ ] new thing

# Work
- [ ] loose

## Today
- [ ] standup

## This Week

# Personal
- [ ] call mom

# Done
- [x] old @done(2026-10-01 09:00)
""")

private func item(_ title: String) -> Doc.Item { doc.items.first { $0.title == title }! }
private func labels(_ m: MoveMenu) -> [String] { m.shown.map(\.label) }
private func choose(_ m: inout MoveMenu, _ label: String) -> (folder: String, section: String?)? {
    while m.shown[m.pick].label != label { m.step(1) }
    return m.choose()
}

@Test func fromInboxShowsFoldersThenTheirSections() {
    var m = MoveMenu(doc: doc, item: item("new thing"))
    #expect(labels(m) == ["Work", "Personal"]) // not Inbox, not Done, no date sections
    #expect(m.shown.map(\.opensMenu) == [true, false]) // Work has sections, Personal doesn't
    let opened = choose(&m, "Work") == nil
    #expect(opened)
    #expect(m.path == ["Work"])
    #expect(labels(m) == ["Work", "Today", "This Week"])
    let dest = choose(&m, "Today")
    #expect(dest?.folder == "Work" && dest?.section == "Today")

    var p = MoveMenu(doc: doc, item: item("new thing"))
    let personal = choose(&p, "Personal")
    #expect(personal?.folder == "Personal" && personal?.section == nil)
}

@Test func fromAFolderWithSectionsShowsThemThenAnotherFolder() {
    var m = MoveMenu(doc: doc, item: item("standup")) // in Work / Today
    #expect(labels(m) == ["This Week", "Work", "Another folder"]) // own section left out; Work = its top
    let opened = choose(&m, "Another folder") == nil
    #expect(opened)
    #expect(labels(m) == ["Inbox", "Personal"]) // Inbox first, never Work itself or Done
    let inbox = choose(&m, "Inbox")
    #expect(inbox?.folder == "Inbox" && inbox?.section == nil) // Inbox means today

    let top = MoveMenu(doc: doc, item: item("loose")) // already at Work's top: no "Work" entry
    #expect(labels(top) == ["Today", "This Week", "Another folder"])
}

@Test func fromAFolderWithoutSectionsShowsFoldersWithInboxFirst() {
    var m = MoveMenu(doc: doc, item: item("call mom"))
    #expect(labels(m) == ["Inbox", "Work"])
    let opened = choose(&m, "Work") == nil
    #expect(opened) // Work's sections come up next
    #expect(labels(m) == ["Work", "Today", "This Week"])
}

@Test func typingFiltersFuzzilyAndBackspaceUndoesIt() {
    var m = MoveMenu(doc: doc, item: item("standup"))
    m.input("t"); m.input("w")
    #expect(labels(m) == ["This Week"])
    m.backspace()
    #expect(m.typed == "t")
    #expect(labels(m) == ["This Week", "Another folder"])
    m.backspace(); m.backspace() // extra backspace is harmless
    #expect(labels(m) == ["This Week", "Work", "Another folder"])
    m.input("x")
    #expect(labels(m).isEmpty)
    let nothing = m.choose() == nil // nothing to choose
    #expect(nothing)
}

@Test func jkMoveUntilYouTypeAndEscGoesBackAMenu() {
    var m = MoveMenu(doc: doc, item: item("standup"))
    m.input("j"); m.input("j")
    #expect(m.pick == 2 && m.typed.isEmpty)
    m.input("j") // clamps at the end
    #expect(m.pick == 2)
    m.input("k")
    #expect(m.pick == 1)

    let opened = choose(&m, "Another folder") == nil
    #expect(opened)
    m.input("w"); m.input("k") // once typing, j/k are letters: "wk" matches Work
    #expect(m.typed == "wk")
    let wentBack = m.back()
    #expect(wentBack)
    #expect(m.path.isEmpty && m.typed.isEmpty && labels(m).count == 3)
    let closes = !m.back() // at the first menu, Esc closes
    #expect(closes)
}
