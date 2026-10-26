# VimKit

Vim keys for a macOS text view: the everyday core of Vim, tuned for Markdown and prose.

- `VimEngine`: the editing model. Pure Foundation, no UI, fully unit tested (`swift test`).
- `VimTextView`: an `NSTextView` subclass that feeds keys to the engine and draws a block cursor.
- `VimEditor`: a SwiftUI wrapper.

```swift
// Package.swift
.package(path: "../VimKit")   // then depend on .product(name: "VimKit", package: "VimKit")

// SwiftUI
VimEditor(text: markdown, line: 0, status: { modeLine = $0 }) { command, text in
    switch command {
    case "w": save(text); return "written"
    case "q", "q!": close(); return nil
    default: return "Not an editor command: \(command)"
    }
}
```

`y` copies to the macOS clipboard and `p` pastes whichever is newer: the last yank, or something
copied in another app. In insert mode the text view types natively, so input methods and key repeat work.

## Keys

| | |
|---|---|
| Counts | `3j`, `d2w`, `2dd`, ... |
| Motions | `h j k l`, `w b e W B E`, `0 ^ $`, `gg G` `{n}G`, `f t F T ; ,`, `%`, `{ }`, `n N * #`, `+ -` Enter, Ctrl-D Ctrl-U |
| Operators | `d c y > <` with any motion, text object or search (`d/foo`); doubled for lines (`dd`, `>>`) |
| Text objects | `iw aw iW aW`, `i" a" i' a' i\` a\``, `i( a( ib`, `i[ a[`, `i{ a{ iB`, `i< a<`, `ip ap` |
| Edits | `x X s S D C Y r J ~ p P`, `.` repeat, `u` Ctrl-R |
| Insert | `i a I A o O`; Esc or Ctrl-[ to leave; Ctrl-W deletes a word back |
| Visual | `v V` with motions and text objects; `o`; `d x y c > < J p ~ u U`; `D X Y` for whole lines |
| Command line | `/` `?` (plain text, smartcase, wraps), `:{n}`, `:$`, `:s/re/rep/gi`, `:%s/...`, `ZZ` `ZQ`; other `:` commands go to the host |

Markdown: `o`, `O` and Enter continue list items (`- `, `* `, `1. ` counting up, `- [ ] ` unchecked);
Enter on an empty item ends the list. `>` and `<` shift by two spaces, for nested lists.

Not included (rare in prose): macros, marks, named registers, folds, windows and buffers, visual block,
`g` commands other than `gg`, `H M L`, regex search.
