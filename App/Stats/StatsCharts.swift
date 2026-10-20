import AppKit

enum Format {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")  // "." as decimal separator, like DuckDB's output
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 4
        return f
    }()

    static func count(_ n: Int) -> String { grouped.string(from: NSNumber(value: n)) ?? String(n) }

    /// Shortens long numeric strings from DuckDB ("500.03883697" → "500.0388"); anything that isn't a
    /// plain number (dates, text) is returned unchanged.
    static func number(_ s: String) -> String {
        guard let value = Double(s), s.count > 8 || s.contains("e") else { return s }
        let magnitude = abs(value)
        if magnitude != 0 && (magnitude >= 1e15 || magnitude < 1e-4) { return String(format: "%.4g", value) }
        return grouped.string(from: NSNumber(value: value)) ?? s
    }

    static func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        let p = Double(part) / Double(total) * 100
        return p > 0 && p < 0.1 ? "<0.1 %" : String(format: "%.1f %%", p)
    }

    static func binBound(_ value: Double, timestamps: Bool) -> String {
        guard timestamps else {
            return value == value.rounded() && abs(value) < 1e15 ? count(Int(value)) : number(String(value))
        }
        let date = Date(timeIntervalSince1970: value / 1000)
        return date.formatted(.iso8601.year().month().day())
    }
}

/// Vertical bar histogram with a tooltip per bar.
final class HistogramView: NSView {
    var bins: [ColumnDetails.Bin] = [] { didSet { rebuildToolTips(); needsDisplay = true } }
    var kind = ColumnDetails.BinKind.value
    var perValue = false
    private var timestamps: Bool { kind == .timestamp }

    override var isFlipped: Bool { true }
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var plotRect: NSRect { bounds.insetBy(dx: 8, dy: 0).divided(atDistance: 18, from: .maxYEdge).remainder.insetBy(dx: 0, dy: 6) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()
    }

    private func barRect(_ index: Int, maxCount: Int) -> NSRect {
        let plot = plotRect
        let width = plot.width / CGFloat(bins.count)
        let height = maxCount > 0 ? plot.height * CGFloat(bins[index].count) / CGFloat(maxCount) : 0
        return NSRect(x: plot.minX + CGFloat(index) * width + 0.5, y: plot.maxY - height,
                      width: max(1, width - 1), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bins.isEmpty else {
            ("No distribution for this type." as NSString).draw(
                at: NSPoint(x: 8, y: 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let maxCount = bins.map(\.count).max() ?? 0
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        for index in bins.indices { barRect(index, maxCount: maxCount).fill() }

        NSColor.separatorColor.setFill()
        NSRect(x: plotRect.minX, y: plotRect.maxY, width: plotRect.width, height: 1).fill()

        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let unit = kind == .length ? " chars" : ""
        let low = (Format.binBound(bins.first!.lower, timestamps: timestamps) + unit) as NSString
        let high = (Format.binBound(perValue ? bins.last!.lower : bins.last!.upper, timestamps: timestamps) + unit) as NSString
        let y = plotRect.maxY + 4
        low.draw(at: NSPoint(x: plotRect.minX, y: y), withAttributes: attributes)
        high.draw(at: NSPoint(x: plotRect.maxX - high.size(withAttributes: attributes).width, y: y), withAttributes: attributes)
        ("max " + Format.count(maxCount) as NSString).draw(at: NSPoint(x: plotRect.minX, y: 0), withAttributes: attributes)
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard !bins.isEmpty else { return }
        let plot = plotRect
        let width = plot.width / CGFloat(bins.count)
        for index in bins.indices {
            let rect = NSRect(x: plot.minX + CGFloat(index) * width, y: plot.minY, width: width, height: plot.height)
            addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard bins.indices.contains(index) else { return "" }
        let bin = bins[index]
        let unit = kind == .length ? " chars" : ""
        if perValue { return "\(Format.binBound(bin.lower, timestamps: false))\(unit)\n\(Format.count(bin.count)) rows" }
        return "\(Format.binBound(bin.lower, timestamps: timestamps)) – \(Format.binBound(bin.upper, timestamps: timestamps))\(unit)\n\(Format.count(bin.count)) rows"
    }
}

/// Most frequent values as rows with a proportional bar behind each.
final class TopValuesView: NSView {
    var values: [(value: String?, count: Int)] = [] { didSet { needsDisplay = true } }
    var total = 0
    /// Every value occurs once: a top-10 list would just be ten arbitrary rows.
    var allUnique: Bool { (values.first?.count ?? 0) <= 1 && values.count > 1 }

    override var isFlipped: Bool { true }
    static let rowHeight: CGFloat = 20
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        if allUnique {
            ("No repeated values — every value occurs once." as NSString).draw(
                at: NSPoint(x: 6, y: 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let maxCount = values.map(\.count).max() ?? 0
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail

        for (index, entry) in values.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight - 2)
            if maxCount > 0 {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: NSRect(x: row.minX, y: row.minY, width: row.width * CGFloat(entry.count) / CGFloat(maxCount),
                                                 height: row.height), xRadius: 3, yRadius: 3).fill()
            }
            let numbers = "\(Format.count(entry.count))  \(Format.percent(entry.count, of: total))" as NSString
            let numberAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let numberWidth = numbers.size(withAttributes: numberAttributes).width
            let textY = row.minY + (row.height - 15) / 2
            numbers.draw(at: NSPoint(x: row.maxX - numberWidth - 6, y: textY), withAttributes: numberAttributes)

            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: entry.value == nil ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .paragraphStyle: truncating,
            ]
            ((entry.value ?? "NULL") as NSString).draw(
                in: NSRect(x: row.minX + 6, y: textY, width: max(0, row.width - numberWidth - 24), height: 16),
                withAttributes: valueAttributes)
        }
    }
}
