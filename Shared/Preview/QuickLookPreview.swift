import Foundation

/// Builds the Quick Look HTML for a Parquet file (SPEC §1.1). Lives in Shared so the CLI can
/// render and time exactly what the extension shows.
enum QuickLookPreview {
    static let headRows = 100
    static let fullRows = 1000
    static let fullCells = 50_000
    static let maxCellChars = 200
    /// Reading the first row means decoding the first page of every column, so memory grows with the
    /// column count. Wide files show only the first columns.
    static let maxColumns = 100

    struct Timings {
        var open: TimeInterval = 0
        var summary: TimeInterval = 0
        var rows: TimeInterval = 0
        var render: TimeInterval = 0
        var total: TimeInterval { open + summary + rows + render }
    }

    static func html(for url: URL, profile: EngineProfile = .previewExtension) throws -> (html: String, timings: Timings) {
        var timings = Timings()
        var mark = Date()
        func lap(_ keyPath: WritableKeyPath<Timings, TimeInterval>) {
            let now = Date()
            timings[keyPath: keyPath] = now.timeIntervalSince(mark)
            mark = now
        }

        let file = ParquetFile(url: url, connection: try profile.connect())
        lap(\.open)

        let summary = try file.summary()
        lap(\.summary)

        let columns = Array(summary.columns.prefix(maxColumns))
        let showAll = summary.rowCount <= fullRows && summary.rowCount * Int64(columns.count) <= fullCells
        let rows = try file.head(columns: columns, limit: showAll ? fullRows : headRows, maxChars: maxCellChars)
        lap(\.rows)

        let html = render(summary: summary, rows: rows)
        lap(\.render)
        return (html, timings)
    }

    static func render(summary: ParquetSummary, rows: [[String?]]) -> String {
        let columns = Array(summary.columns.prefix(maxColumns))
        var out = String()
        out.reserveCapacity(64 + rows.count * columns.count * 24)

        out += """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; --muted: #8a8a8e; --line: rgba(127,127,127,.22); --head: rgba(246,246,246,.96); }
        @media (prefers-color-scheme: dark) { :root { --head: rgba(40,40,42,.96); } }
        body { font: 12px -apple-system, system-ui, sans-serif; margin: 0; }
        header { padding: 14px 16px 10px; }
        h1 { font-size: 15px; font-weight: 600; margin: 0 0 3px; word-break: break-all; }
        .meta { color: var(--muted); }
        table { border-collapse: separate; border-spacing: 0; font-variant-numeric: tabular-nums; }
        th, td { padding: 3px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; text-align: left; vertical-align: top; }
        th { position: sticky; top: 0; background: var(--head); font-weight: 600; }
        th small { display: block; font-weight: 400; color: var(--muted); }
        td.n, th.n { text-align: right; }
        td.i, th.i { color: var(--muted); text-align: right; }
        .null { color: var(--muted); opacity: .6; }
        .partial { margin-top: 4px; color: var(--muted); font-style: italic; }
        </style></head><body>
        """

        let size = ByteCountFormatter.string(fromByteCount: summary.fileSize, countStyle: .file)
        out += "<header><h1>\(escape(summary.url.lastPathComponent))</h1><div class=\"meta\">"
        out += "\(format(summary.rowCount)) rows · \(summary.columns.count) columns · \(size)"
        out += " · \(format(summary.rowGroupCount)) row group\(summary.rowGroupCount == 1 ? "" : "s")"
        out += "</div>"

        // Say up front that the table below is partial.
        var notes: [String] = []
        if Int64(rows.count) < summary.rowCount {
            notes.append("first \(format(Int64(rows.count))) of \(format(summary.rowCount)) rows")
        }
        if columns.count < summary.columns.count {
            notes.append("first \(columns.count) of \(summary.columns.count) columns")
        }
        if !notes.isEmpty {
            out += "<div class=\"partial\">Showing \(notes.joined(separator: ", "))</div>"
        }
        out += "</header>"

        out += "<table><thead><tr><th class=\"i\">#</th>"
        for column in columns {
            let cls = column.kind == .number ? " class=\"n\"" : ""
            out += "<th\(cls)>\(escape(column.name))<small>\(escape(column.type))</small></th>"
        }
        out += "</tr></thead><tbody>"

        for (index, row) in rows.enumerated() {
            out += "<tr><td class=\"i\">\(index + 1)</td>"
            for (column, raw) in zip(columns, row) {
                let cls = column.kind == .number ? " class=\"n\"" : ""
                if let value = CellFormatter.display(raw, kind: column.kind, maxChars: maxCellChars) {
                    out += "<td\(cls)>\(escape(value))</td>"
                } else {
                    out += "<td\(cls)><span class=\"null\">NULL</span></td>"
                }
            }
            out += "</tr>"
        }
        out += "</tbody></table></body></html>"
        return out
    }

    static func error(_ message: String, fileName: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>:root{color-scheme:light dark}</style></head>
        <body style="font:13px -apple-system,system-ui;margin:24px">
        <h1 style="font-size:15px;margin:0 0 8px">\(escape(fileName))</h1>
        <p>Can't read this file as Parquet.</p>
        <p style="color:#8a8a8e;white-space:pre-wrap">\(escape(message))</p>
        </body></html>
        """
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        return f
    }()

    private static func format(_ n: Int64) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
