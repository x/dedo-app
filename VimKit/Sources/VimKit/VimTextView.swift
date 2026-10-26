import AppKit

/// An NSTextView with vim keys. Handle `:w`/`:q` with `vim.exCommand`; show `vim.status` from `onStatus`.
open class VimTextView: NSTextView, VimBuffer {
    public private(set) lazy var vim: VimEngine = {
        let e = VimEngine(buffer: self)
        e.pasteboard = SystemPasteboard()
        return e
    }()

    /// Called after every key with the mode line to show.
    public var onStatus: ((String) -> Void)?

    /// The cursor: a blinking box in normal and visual mode, the system bar in insert mode.
    public var cursorColor: NSColor = .controlAccentColor { didSet { updateCursor() } }

    private let box = BoxCursor()
    private var placingCursor = false

    open override func keyDown(with event: NSEvent) {
        defer { updateCursor() }
        guard !event.modifierFlags.contains(.command), let key = VimTextView.key(event), vim.handle(key) else {
            return super.keyDown(with: event)
        }
        onStatus?(vim.status)
    }

    static func key(_ e: NSEvent) -> VimKey? {
        switch e.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default:
            if e.modifierFlags.contains(.control), let c = e.charactersIgnoringModifiers?.first { return .ctrl(c) }
            return e.characters?.first.map(VimKey.char)
        }
    }

    // MARK: VimBuffer

    public var caret: Int { selectedRange().location }

    public func show(caret: Int, selection: NSRange?) {
        setSelectedRange(selection ?? NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
        updateCursor()
    }

    public func replace(_ range: NSRange, with text: String) {
        insertText(text, replacementRange: range) // goes through undo
    }

    public func undoChange() { undoManager?.undo() }
    public func redoChange() { undoManager?.redo() }

    public var halfPage: Int {
        guard let font, let lm = layoutManager else { return 10 }
        return max(1, Int(visibleRect.height / lm.defaultLineHeight(for: font) / 2))
    }

    // MARK: Box cursor outside insert mode

    /// Drawn as our own view over the character rather than by restyling the system insertion point,
    /// which newer macOS draws itself. Translucent, so the character under it still reads.
    func updateCursor() {
        // Measuring can lay text out and resize the view, which calls back here.
        guard !placingCursor, window != nil else { box.isHidden = true; return }
        placingCursor = true
        defer { placingCursor = false }
        let boxed = vim.mode != .insert
        insertionPointColor = boxed ? .clear : cursorColor // the bar only in insert mode
        if box.superview !== self { addSubview(box) }
        box.isHidden = !boxed || window == nil || window?.firstResponder !== self
        guard !box.isHidden, let window, let font else { return }
        let visual = vim.mode == .visual || vim.mode == .visualLine
        let at = visual ? vim.cursor : selectedRange().location // a click moves the caret before vim hears of it
        let ns = string as NSString
        let onChar = at < ns.length && ns.character(at: at) != 10
        var r = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: at, length: onChar ? 1 : 0), actualRange: nil)), from: nil)
        if r.width < 1 { r.size.width = ("M" as NSString).size(withAttributes: [.font: font]).width }
        box.frame = r
        box.layer?.backgroundColor = cursorColor.withAlphaComponent(0.55).cgColor
        box.restartBlink()
    }

    open override func becomeFirstResponder() -> Bool {
        defer { updateCursor() }
        return super.becomeFirstResponder()
    }

    open override func resignFirstResponder() -> Bool {
        defer { updateCursor() }
        return super.resignFirstResponder()
    }

    open override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        updateCursor()
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCursor() // text rewraps
    }

    /// A scroll view holding a VimTextView set up for plain-text editing.
    public static func scrollable() -> (NSScrollView, VimTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let tv = VimTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        scroll.documentView = tv
        return (scroll, tv)
    }
}

/// The box: solid while you're moving, then blinking like the system cursor (unless Reduce Motion is on).
final class BoxCursor: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the text

    private var timer: Timer?

    /// Solid now; on/off every half second after a moment, the system cursor's rhythm.
    func restartBlink() {
        timer?.invalidate()
        alphaValue = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            alphaValue = alphaValue > 0 ? 0 : 1
        }
    }

    override func viewDidHide() {
        timer?.invalidate()
        super.viewDidHide()
    }
}

/// The macOS clipboard.
final class SystemPasteboard: VimPasteboard {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func read() -> String? { NSPasteboard.general.string(forType: .string) }
    func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
