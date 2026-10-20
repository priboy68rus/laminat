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

    /// Text attributes per (style, selected), built once instead of on every draw.
    private static let attributeCache: [Style: [Bool: [NSAttributedString.Key: Any]]] = {
        var cache: [Style: [Bool: [NSAttributedString.Key: Any]]] = [:]
        for style in [Style.value, .number, .null, .rowNumber, .placeholder] {
            for selected in [false, true] {
                let color: NSColor = switch style {
                case .value, .number: selected ? .alternateSelectedControlTextColor : .labelColor
                case .null, .placeholder: selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.6) : .tertiaryLabelColor
                case .rowNumber: selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
                }
                let paragraph = switch style {
                case .number: numberParagraph
                case .rowNumber: rowNumberParagraph
                default: leftParagraph
                }
                cache[style, default: [:]][selected] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            }
        }
        return cache
    }()

    private static let exponentAttributes: [Bool: [NSAttributedString.Key: Any]] = {
        var result: [Bool: [NSAttributedString.Key: Any]] = [:]
        for selected in [false, true] {
            var attributes = attributeCache[.number]![selected]!
            attributes[.paragraphStyle] = exponentParagraph
            result[selected] = attributes
        }
        return result
    }()

    /// Zebra striping, applied to row views (see GridViewController).
    static func rowBackground(_ row: Int) -> NSColor {
        let colors = NSColor.alternatingContentBackgroundColors
        return colors[row % colors.count]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Vertical grid line on the right edge (the table's own grid is off for performance).
        NSColor.gridColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        guard !text.isEmpty else { return }
        let selected = backgroundStyle == .emphasized
        let attributes = style == .number && text.contains("e")
            ? Self.exponentAttributes[selected]!
            : Self.attributeCache[style]![selected]!
        let rect = NSRect(x: Self.horizontalPadding,
                          y: floor((bounds.height - Self.lineHeight) / 2),
                          width: bounds.width - Self.horizontalPadding * 2,
                          height: Self.lineHeight)
        // draw(in:) honours the paragraph's line break mode (tail / middle / head truncation).
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
