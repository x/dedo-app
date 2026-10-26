import Foundation
import Testing
@testable import VimKit

/// A string standing in for the text view, with per-edit undo.
final class TestBuffer: VimBuffer {
    var string: String
    var caret: Int
    var selection: NSRange?
    var halfPage = 2
    private var undos: [(String, Int)] = [], redos: [(String, Int)] = []

    init(_ s: String, caret: Int) { string = s; self.caret = caret }

    func show(caret: Int, selection: NSRange?) { self.caret = caret; self.selection = selection }
    func replace(_ r: NSRange, with text: String) {
        undos.append((string, caret)); redos = []
        string = (string as NSString).replacingCharacters(in: r, with: text)
    }
    func undoChange() { if let (s, c) = undos.popLast() { redos.append((string, caret)); string = s; caret = c } }
    func redoChange() { if let (s, c) = redos.popLast() { undos.append((string, caret)); string = s; caret = c } }
}

final class TestPasteboard: VimPasteboard {
    var changeCount = 0
    var text: String?
    func read() -> String? { text }
    func write(_ t: String) { text = t; changeCount += 1 }
}

/// Vim key notation: <Esc> <CR> <BS> <C-x> <Up> <Down> <Left> <Right>; anything else is typed as is.
func keys(_ s: String) -> [VimKey] {
    var out: [VimKey] = []
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
            let name = s[s.index(after: i)..<close]
            let named: VimKey? = switch name {
            case "Esc": .escape
            case "CR": .enter
            case "BS": .backspace
            case "Up": .up
            case "Down": .down
            case "Left": .left
            case "Right": .right
            default: name.hasPrefix("C-") && name.count == 3 ? .ctrl(name.last!) : nil
            }
            if let named { out.append(named); i = s.index(after: close); continue }
        }
        out.append(.char(s[i]))
        i = s.index(after: i)
    }
    return out
}

/// Runs `input` on `text` ("|" marks the cursor) and returns the text with "|" at the new cursor.
@discardableResult
func vim(_ text: String, _ input: String, _ setup: (VimEngine, TestBuffer) -> Void = { _, _ in }) -> String {
    let caret = (text as NSString).range(of: "|").location
    let buffer = TestBuffer(text.replacingOccurrences(of: "|", with: ""), caret: caret == NSNotFound ? 0 : caret)
    let engine = VimEngine(buffer: buffer)
    engine.insertsTyping = true
    setup(engine, buffer)
    for k in keys(input) { engine.handle(k) }
    return (buffer.string as NSString).replacingCharacters(in: NSRange(location: buffer.caret, length: 0), with: "|")
}

@Test func motions() {
    #expect(vim("|one two three", "w") == "one |two three")
    #expect(vim("|one two three", "2w") == "one two |three")
    #expect(vim("one two |three", "b") == "one |two three")
    #expect(vim("|one two", "e") == "on|e two")
    #expect(vim("|a.b c", "w") == "a|.b c")
    #expect(vim("|a.b c", "W") == "a.b |c")
    #expect(vim("one\n\n|two", "b") == "one\n|\ntwo") // an empty line is a word
    #expect(vim("  |abc", "0") == "|  abc")
    #expect(vim("|  abc", "^") == "  |abc")
    #expect(vim("|abc\ndef", "$") == "ab|c\ndef")
    #expect(vim("a\nb\n|c", "gg") == "|a\nb\nc")
    #expect(vim("|a\nb\nc", "G") == "a\nb\n|c")
    #expect(vim("|a\nb\nc", "2G") == "a\n|b\nc")
    #expect(vim("|a\nb\nc", ":3<CR>") == "a\nb\n|c")
    #expect(vim("|a\nb\nc\n", "99G") == "a\nb\n|c\n") // clamps, and skips the empty line after the final newline
}

@Test func verticalMotionsRememberTheColumn() {
    #expect(vim("abc|d\nx\nabcdef", "jj") == "abcd\nx\nabc|def")
    #expect(vim("a|bc\nxyz", "$jk") == "ab|c\nxyz")
    #expect(vim("|a\nb", "5j") == "a\n|b") // as far as it can
}

@Test func findAndBrackets() {
    #expect(vim("|a,b,c", "f,") == "a|,b,c")
    #expect(vim("|a,b,c", "2f,") == "a,b|,c")
    #expect(vim("|a,b,c", "t,;") == "a,|b,c")
    #expect(vim("a,b,|c", "F,") == "a,b|,c")
    #expect(vim("|[link](url)", "%") == "[link|](url)")
    #expect(vim("[link|](url)", "%") == "|[link](url)")
    #expect(vim("|one\ntwo\n\nthree", "}") == "one\ntwo\n|\nthree")
    #expect(vim("one\n\nthree|", "{") == "one\n|\nthree")
}

@Test func operatorsWithMotions() {
    #expect(vim("|one two", "dw") == "|two")
    #expect(vim("one |two\nnext", "dw") == "one| \nnext") // stops at the line end
    #expect(vim("|one two", "cwsix<Esc>") == "si|x two") // cw is like ce
    #expect(vim("|one two", "ce1<Esc>") == "|1 two")
    #expect(vim("|one two three", "d2w") == "|three")
    #expect(vim("one |two", "d$") == "one| ")
    #expect(vim("one |two", "D") == "one| ")
    #expect(vim("one |two", "Cx<Esc>") == "one |x")
    #expect(vim("|a,b,c", "dt,") == "|,b,c")
    #expect(vim("|a,b,c", "df,") == "|b,c")
    #expect(vim("a\n|b\nc", "dd") == "a\n|c")
    #expect(vim("|a\nb\nc", "2dd") == "|c")
    #expect(vim("a\n|b", "dd") == "|a") // the last line takes the newline before it
    #expect(vim("|a\nb\nc", "dj") == "|c")
    #expect(vim("a\n|b\nc", "dk") == "|c")
    #expect(vim("|a\nb\nc", "dG") == "|")
    #expect(vim("|abc", "x") == "|bc")
    #expect(vim("|abc", "2x") == "|c")
    #expect(vim("ab|c", "X") == "a|c")
    #expect(vim("|abc", "sX<Esc>") == "|Xbc")
    #expect(vim("|abc", "~~") == "AB|c")
    #expect(vim("|abc", "rx") == "|xbc")
    #expect(vim("|a\n  b", "J") == "a| b")
}

@Test func textObjects() {
    #expect(vim("one tw|o three", "diw") == "one | three")
    #expect(vim("one tw|o three", "daw") == "one |three")
    #expect(vim("say \"hel|lo\" now", "ci\"bye<Esc>") == "say \"by|e\" now")
    #expect(vim("say \"hel|lo\" now", "da\"") == "say | now")
    #expect(vim("[li|nk](url)", "ci[text<Esc>") == "[tex|t](url)")
    #expect(vim("[link](u|rl)", "ci(https://x.com<Esc>") == "[link](https://x.co|m)")
    #expect(vim("f(a, (b|), c)", "di(") == "f(a, (|), c)")
    #expect(vim("f(a, |(b), c)", "da(") == "f(a, |, c)")
    #expect(vim("one\ntw|o\n\nthree", "dip") == "|\nthree")
    #expect(vim("one\ntw|o\n\nthree", "dap") == "|three")
}

@Test func yankAndPaste() {
    #expect(vim("|a\nb", "yyp") == "a\n|a\nb")
    #expect(vim("a\n|b", "yyp") == "a\nb\n|b") // after a last line with no newline
    #expect(vim("a\n|b", "yyP") == "a\n|b\nb")
    #expect(vim("|one two", "yiwwP") == "one on|etwo")
    #expect(vim("|one two", "yiw$p") == "one twoon|e")
    #expect(vim("|a\nb", "ddp") == "b\n|a")
    #expect(vim("|ab", "xp") == "b|a")
    #expect(vim("  |a", "Y$p") == "  a\n  |a")
}

@Test func pasteboardSyncs() {
    let pb = TestPasteboard()
    vim("|one two", "yiw") { e, _ in e.pasteboard = pb }
    #expect(pb.text == "one")
    // Something copied in another app since our last yank wins.
    #expect(vim("|one two", "yiw<Esc>") { e, _ in e.pasteboard = pb } == "|one two")
    let elsewhere = TestPasteboard()
    elsewhere.text = "zz"
    elsewhere.changeCount = 7
    #expect(vim("|ab", "P") { e, _ in e.pasteboard = elsewhere } == "z|zab")
    #expect(vim("|ab", "yiwP") { e, _ in e.pasteboard = elsewhere } == "a|bab") // our yank is newer
}

@Test func shifting() {
    #expect(vim("|- a\n- b", ">>") == "  |- a\n- b")
    #expect(vim("|- a\n- b", ">j") == "  |- a\n  - b")
    #expect(vim("    |- a", "<<") == "  |- a")
    #expect(vim("|- a\n\n- b", "3>>") == "  |- a\n\n  - b") // blank lines stay blank
}

@Test func insertCommands() {
    #expect(vim("a|bc", "iX<Esc>") == "a|Xbc")
    #expect(vim("a|bc", "aX<Esc>") == "ab|Xc")
    #expect(vim("  a|bc", "IX<Esc>") == "  |Xabc")
    #expect(vim("a|bc", "AX<Esc>") == "abc|X")
    #expect(vim("|  one", "otwo<Esc>") == "  one\n  tw|o") // keeps the indent
    #expect(vim("|one", "Otwo<Esc>") == "tw|o\none")
    #expect(vim("|one two", "ccnew<Esc>") == "ne|w")
    #expect(vim("  |one", "Snew<Esc>") == "  ne|w") // keeps the indent
    #expect(vim("one two|", "A<C-w><Esc>") == "one| ")
    #expect(vim("|ab", "ix<BS>y<Esc>") == "|yab")
}

@Test func markdownListsContinue() {
    #expect(vim("|- one", "otwo<Esc>") == "- one\n- tw|o")
    #expect(vim("|- [x] done", "onext<Esc>") == "- [x] done\n- [ ] nex|t") // a new checkbox starts unchecked
    #expect(vim("|1. one", "otwo<Esc>") == "1. one\n2. tw|o")
    #expect(vim("  |* nested", "Oabove<Esc>") == "  * abov|e\n  * nested")
    #expect(vim("|- one", "A<CR>two<Esc>") == "- one\n- tw|o")
    #expect(vim("|- one", "A<CR><CR>after<Esc>") == "- one\nafte|r") // Enter on an empty item ends the list
    #expect(vim("|plain", "A<CR>x<Esc>") == "plain\n|x")
}

@Test func dotRepeats() {
    #expect(vim("|a b c d", "dw..") == "|d")
    #expect(vim("|one two", "ciwX<Esc>w.") == "X |X")
    #expect(vim("|a\nb\nc", "A!<Esc>j.j.") == "a!\nb!\nc|!")
    #expect(vim("|- a\n- b", ">>j.") == "  - a\n  |- b")
}

@Test func undoRedo() {
    #expect(vim("|a\nb", "ddu") == "|a\nb")
    #expect(vim("|a\nb", "ddu<C-r>") == "|b")
    #expect(vim("|abc", "xxuu") == "|abc")
}

@Test func visualMode() {
    #expect(vim("|one two", "ved") == "| two")
    #expect(vim("|a\nb\nc", "Vjd") == "|c")
    #expect(vim("|one two", "veyP") == "on|eone two")
    #expect(vim("one tw|o", "viwcX<Esc>") == "one |X")
    #expect(vim("|a\nb", "Vj>") == "  |a\n  b")
    #expect(vim("|one two", "vU") == "|One two")
    #expect(vim("|ab cd", "yiwwviwp") == "ab |ab")
    let b = TestBuffer("one two", caret: 0)
    let e = VimEngine(buffer: b)
    for k in keys("ve") { e.handle(k) }
    #expect(e.mode == .visual && b.selection == NSRange(location: 0, length: 3))
    e.handle(.escape)
    #expect(e.mode == .normal && b.selection == nil)
}

@Test func search() {
    #expect(vim("|a foo b foo", "/foo<CR>") == "a |foo b foo")
    #expect(vim("|a foo b foo", "/foo<CR>n") == "a foo b |foo")
    #expect(vim("|a foo b foo", "/foo<CR>nn") == "a |foo b foo") // wraps
    #expect(vim("a foo b |foo", "?foo<CR>") == "a |foo b foo")
    #expect(vim("|a Foo", "/foo<CR>") == "a |Foo") // lowercase searches ignore case
    #expect(vim("|a Foo foo", "/foo<CR>N") == "a Foo |foo")
    #expect(vim("|word x word", "*") == "word x |word")
    #expect(vim("|a foo b", "d/foo<CR>") == "|foo b")
    #expect(vim("a foo |b", "c?foo<CR>X<Esc>") == "a |Xb")
    #expect(vim("|a foo b", "v/foo<CR>d") == "|oo b") // visual search extends the selection
}

@Test func exCommands() {
    #expect(vim("|a cat a cat\na cat", ":s/cat/dog/<CR>") == "|a dog a cat\na cat")
    #expect(vim("|a cat a cat\na cat", ":%s/cat/dog/g<CR>") == "|a dog a dog\na dog")
    #expect(vim("|Cat", ":s/cat/[&]/i<CR>") == "|[Cat]")
    #expect(vim("|ab", ":s/(a)(b)/\\2\\1/<CR>") == "|ba")
    var got: [String] = []
    vim("|x", ":w<CR>:wq<CR>ZZ") { e, _ in e.exCommand = { got.append($0); return nil } }
    #expect(got == ["w", "wq", "x"])
    let b = TestBuffer("x", caret: 0)
    let e = VimEngine(buffer: b)
    for k in keys(":nope<CR>") { e.handle(k) }
    #expect(e.status == "Not an editor command: nope")
}

@Test func statusLine() {
    let b = TestBuffer("abc", caret: 0)
    let e = VimEngine(buffer: b)
    e.insertsTyping = true
    #expect(e.status == "")
    e.handle(.char("2")); e.handle(.char("d"))
    #expect(e.status == "2d")
    e.handle(.escape)
    e.handle(.char("i"))
    #expect(e.status == "-- INSERT --")
    e.handle(.escape)
    e.handle(.char(":")); e.handle(.char("w"))
    #expect(e.status == ":w")
}

@Test func textViewTypingIsLeftToTheTextView() {
    let b = TestBuffer("ab", caret: 0)
    let e = VimEngine(buffer: b)
    e.handle(.char("i"))
    #expect(e.handle(.char("x")) == false) // the text view types it
    #expect(e.handle(.escape))
    #expect(e.mode == .normal)
}
