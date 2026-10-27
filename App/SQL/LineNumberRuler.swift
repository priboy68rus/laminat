import AppKit

/// Line numbers to the left of the SQL editor. The cursor's line is drawn darker, a line with a query
/// error in red.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// 1-based line to mark as the error line.
    var errorLine: Int? { didSet { needsDisplay = true } }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Room for the widest line number (at least two digits).
    func updateThickness() {
        let lines = (textView?.string ?? "").reduce(into: 1) { count, c in if c == "\n" { count += 1 } }
        let digits = max(2, String(lines).count)
        let width = CGFloat(digits) * 7 + 18
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let cursorLine = lineNumber(at: textView.selectedRange().location, in: text)
        let insetY = textView.textContainerOrigin.y

        func newlines(in range: NSRange) -> Int {
            var count = 0
            for i in range.location..<NSMaxRange(range) where text.character(at: i) == 10 { count += 1 }
            return count
        }

        func draw(_ number: Int, fragment: NSRect) {
            let color: NSColor = number == errorLine ? .systemRed : number == cursorLine ? .labelColor : .tertiaryLabelColor
            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: fragment.minY + insetY), from: textView).y + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }

        var line = lineNumber(at: characters.location, in: text)
        var counted = characters.location
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let index = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            // Wrapped continuation lines get no number.
            guard index == 0 || text.character(at: index - 1) == 10 else { return }
            line += newlines(in: NSRange(location: counted, length: index - counted))
            counted = index
            draw(line, fragment: fragment)
        }
        // The empty line after a trailing newline (or of an empty editor).
        if layoutManager.extraLineFragmentTextContainer != nil {
            draw(lineNumber(at: text.length, in: text), fragment: layoutManager.extraLineFragmentRect)
        }
    }

    private func lineNumber(at position: Int, in text: NSString) -> Int {
        var count = 1
        let end = min(position, text.length)
        var i = 0
        while i < end {
            if text.character(at: i) == 10 { count += 1 }
            i += 1
        }
        return count
    }
}
