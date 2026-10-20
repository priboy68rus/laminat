import AppKit

/// Table header with two rows: the column title on top (clickable for sorting, drawn by
/// `TitleHeaderCell`), and a "contains" filter field under every data column.
/// Fields are subviews of the header, so they scroll horizontally with it for free.
final class FilterHeaderView: NSTableHeaderView {
    static let titleHeight: CGFloat = 22
    static let height: CGFloat = 48

    /// Called when a field's text changes (`commit` is true on Return).
    var onFilterChange: ((_ column: Int, _ text: String, _ commit: Bool) -> Void)?

    private var fields: [NSUserInterfaceItemIdentifier: NSSearchField] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: frameRect.minX, y: frameRect.minY, width: frameRect.width, height: Self.height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// NSTableView resets the header to the standard height; keep room for the filter row.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: Self.height))
    }

    /// Creates one field per data column (columns whose identifier starts with "c").
    func setUp(columns: [NSTableColumn]) {
        fields.values.forEach { $0.removeFromSuperview() }
        fields = [:]
        for (index, column) in columns.enumerated() where column.identifier.rawValue.hasPrefix("c") {
            let field = NSSearchField()
            field.controlSize = .small
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.placeholderString = "Filter"
            field.sendsSearchStringImmediately = false
            field.sendsWholeSearchString = false
            field.tag = index - 1  // data column index (column 0 is the row number)
            field.target = self
            field.action = #selector(fieldAction(_:))
            (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
            addSubview(field)
            fields[column.identifier] = field
        }
        needsLayout = true
    }

    func focusField(column: Int) {
        guard let field = fields.values.first(where: { $0.tag == column }) else { return }
        window?.makeFirstResponder(field)
    }

    var firstField: NSSearchField? { fields.values.min { $0.tag < $1.tag } }

    @objc private func fieldAction(_ sender: NSSearchField) {
        let commit = NSApp.currentEvent?.type == .keyDown
        onFilterChange?(sender.tag, sender.stringValue, commit)
    }

    override func layout() {
        super.layout()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            guard let field = fields[column.identifier] else { continue }
            let rect = headerRect(ofColumn: index)
            field.frame = NSRect(x: rect.minX + 3, y: Self.titleHeight + 2, width: max(0, rect.width - 6), height: 20)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}

/// Header cell that draws its title in the top row of `FilterHeaderView`.
final class TitleHeaderCell: NSTableHeaderCell {
    /// AppKit passes a text rect already centred in the whole (tall) header; move it into the title row.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var titleFrame = cellFrame
        titleFrame.origin.y = floor((FilterHeaderView.titleHeight - cellFrame.height) / 2) + 1
        super.drawInterior(withFrame: titleFrame, in: controlView)
    }
}
