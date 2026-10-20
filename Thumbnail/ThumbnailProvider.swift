import AppKit
import QuickLookThumbnailing

/// Finder / Quick Look icon for .parquet files: a miniature table with the first columns and rows
/// (SPEC §1.2). Reads only the footer and the start of the first row group.
class ThumbnailProvider: QLThumbnailProvider {
    static let maxRows = 12
    static let maxCellChars = 24

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Landscape "sheet" that fits the requested box.
        let box = request.maximumSize
        let size = CGSize(width: box.width, height: floor(min(box.height, box.width * 0.78)))

        var columns: [ParquetColumn] = []
        var rows: [[String?]] = []
        if let connection = try? EngineProfile.previewExtension.connect() {
            let file = ParquetFile(url: request.fileURL, connection: connection)
            if let summary = try? file.summary() {
                // Roughly one column per 60 points; tiny icons just show the grid.
                columns = Array(summary.columns.prefix(max(1, Int(size.width / 60))))
                rows = (try? file.head(columns: columns, limit: Self.maxRows, maxChars: Self.maxCellChars)) ?? []
            }
        }

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            TableThumbnail.draw(columns: columns, rows: rows, in: CGRect(origin: .zero, size: size))
            return true
        }
        reply.extensionBadge = "parquet"
        handler(reply, nil)
    }
}

enum TableThumbnail {
    static func draw(columns: [ParquetColumn], rows: [[String?]], in rect: CGRect) {
        let sheet = rect.insetBy(dx: max(1, rect.width * 0.02), dy: max(1, rect.height * 0.02))
        let radius = max(2, sheet.width * 0.03)
        let path = NSBezierPath(roundedRect: sheet, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let rowCount = max(rows.count, 6)
        let rowHeight = sheet.height / CGFloat(rowCount + 1)
        let columnCount = max(columns.count, 1)
        let columnWidth = sheet.width / CGFloat(columnCount)
        let showText = rowHeight >= 7

        // Header band (non-flipped context: the top row is at maxY).
        let header = CGRect(x: sheet.minX, y: sheet.maxY - rowHeight, width: sheet.width, height: rowHeight)
        NSColor(calibratedRed: 0.23, green: 0.47, blue: 0.85, alpha: 1).setFill()
        header.fill()

        // Zebra rows and grid.
        for row in 0..<rowCount where row % 2 == 1 {
            NSColor(white: 0.95, alpha: 1).setFill()
            CGRect(x: sheet.minX, y: header.minY - CGFloat(row + 1) * rowHeight, width: sheet.width, height: rowHeight).fill()
        }
        NSColor(white: 0.82, alpha: 1).setFill()
        for column in 1..<columnCount {
            CGRect(x: sheet.minX + CGFloat(column) * columnWidth, y: sheet.minY, width: max(0.5, rect.width / 400), height: header.minY - sheet.minY).fill()
        }

        if showText {
            let fontSize = min(rowHeight * 0.62, 13)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ]
            let cellAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor(white: 0.15, alpha: 1), .paragraphStyle: paragraph,
            ]
            let nullAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor(white: 0.65, alpha: 1), .paragraphStyle: paragraph,
            ]
            let padding = max(1.5, columnWidth * 0.06)
            let textInset = (rowHeight - fontSize * 1.25) / 2

            for (index, column) in columns.enumerated() {
                // draw(in:) starts at the top of the rect; leave the inset above the text.
                let cell = CGRect(x: sheet.minX + CGFloat(index) * columnWidth + padding, y: header.minY,
                                  width: columnWidth - padding * 2, height: rowHeight - textInset)
                (column.name as NSString).draw(in: cell, withAttributes: headerAttributes)
            }
            for (rowIndex, row) in rows.enumerated() {
                let y = header.minY - CGFloat(rowIndex + 1) * rowHeight
                for (index, column) in columns.enumerated() where index < row.count {
                    let cell = CGRect(x: sheet.minX + CGFloat(index) * columnWidth + padding, y: y,
                                      width: columnWidth - padding * 2, height: rowHeight - textInset)
                    if let text = CellFormatter.display(row[index], kind: column.kind, maxChars: ThumbnailProvider.maxCellChars) {
                        (text as NSString).draw(in: cell, withAttributes: cellAttributes)
                    } else {
                        ("NULL" as NSString).draw(in: cell, withAttributes: nullAttributes)
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.7, alpha: 1).setStroke()
        path.lineWidth = max(0.5, rect.width / 256)
        path.stroke()
    }
}
