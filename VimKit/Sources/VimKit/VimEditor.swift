import AppKit
import SwiftUI

/// A vim text editor for SwiftUI. It starts with `text` and keeps its own buffer from then on; the host
/// gets the text when `:` commands it doesn't know arrive (`:w`, `:q`, ...).
public struct VimEditor: NSViewRepresentable {
    public struct Style {
        public var font: NSFont
        public var text: NSColor
        public var background: NSColor
        public var cursor: NSColor
        public var inset: NSSize

        public init(font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular), text: NSColor = .textColor,
                    background: NSColor = .textBackgroundColor, cursor: NSColor = .controlAccentColor,
                    inset: NSSize = NSSize(width: 16, height: 16)) {
            self.font = font; self.text = text; self.background = background; self.cursor = cursor; self.inset = inset
        }
    }

    let text: String
    let line: Int
    let style: Style
    let status: (String) -> Void
    let command: (String, String) -> String?

    /// - Parameters:
    ///   - line: 0-based line to start on.
    ///   - status: the mode line, after every key.
    ///   - command: `:` commands the editor doesn't handle itself, with the current text; return a message.
    public init(text: String, line: Int = 0, style: Style = Style(), status: @escaping (String) -> Void,
                command: @escaping (_ command: String, _ text: String) -> String?) {
        self.text = text; self.line = line; self.style = style; self.status = status; self.command = command
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = VimTextView.scrollable()
        tv.font = style.font
        tv.textColor = style.text
        tv.backgroundColor = style.background
        tv.cursorColor = style.cursor
        tv.textContainerInset = style.inset
        tv.string = text
        tv.onStatus = status
        tv.vim.exCommand = { [weak tv] cmd in command(cmd, tv?.string ?? "") }
        tv.vim.goToLine(line)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.scrollRangeToVisible(tv.selectedRange())
        }
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
