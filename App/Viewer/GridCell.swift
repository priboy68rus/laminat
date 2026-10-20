import AppKit

/// Lightweight table cell that draws one line of text itself: no NSTextField, no Auto Layout.
/// Thousands of these are on screen while scrolling, so drawing cost matters.
final class GridCell: NSView {
    enum Style { case value, number, null, rowNumber, placeholder }

    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let horizontalPadding: CGFloat = 6

    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var style = Style.value { didSet { if style != oldValue { needsDisplay = true } } }

    /// Set by NSTableRowView: `.emphasized` on selected rows of the key window.
    @objc var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    private static func paragraph(_ alignment: NSTextAlignment, _ lineBreak: NSLineBreakMode) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = lineBreak
        p.alignment = alignment
        return p
    }

    private static let leftParagraph = paragraph(.left, .byTruncatingTail)
    private static let numberParagraph = paragraph(.right, .byTruncatingTail)
    /// Numbers with an exponent are cut in the middle so "e-08" stays visible.
    private static let exponentParagraph = paragraph(.right, .byTruncatingMiddle)
    private static let rowNumberParagraph = paragraph(.right, .byTruncatingHead)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let selected = backgroundStyle == .emphasized

        let color: NSColor
        switch style {
        case .value, .number: color = selected ? .alternateSelectedControlTextColor : .labelColor
        case .null, .placeholder: color = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.6) : .tertiaryLabelColor
        case .rowNumber: color = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        }
        let paragraph = switch style {
        case .number: text.contains("e") ? Self.exponentParagraph : Self.numberParagraph
        case .rowNumber: Self.rowNumberParagraph
        default: Self.leftParagraph
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let rect = NSRect(x: Self.horizontalPadding,
                          y: floor((bounds.height - Self.lineHeight) / 2),
                          width: bounds.width - Self.horizontalPadding * 2,
                          height: Self.lineHeight)
        // draw(in:) honours the paragraph's line break mode (tail / middle / head truncation).
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
