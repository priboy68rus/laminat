import Foundation

/// Minimal, dependency-free look at a Parquet file: checks the "PAR1" magic
/// at both ends and reads the footer length. Enough to prove the Quick Look
/// extension can open the file inside its sandbox.
struct ParquetProbe {
    let fileName: String
    let fileSize: UInt64
    let headerMagicOK: Bool
    let footerMagicOK: Bool
    let footerLength: UInt32?

    var isValid: Bool { headerMagicOK && footerMagicOK }

    enum ProbeError: Error, LocalizedError {
        case tooSmall(UInt64)
        var errorDescription: String? {
            switch self {
            case .tooSmall(let size): return "File is too small to be Parquet (\(size) bytes)"
            }
        }
    }

    static let magic = Data("PAR1".utf8)

    static func probe(url: URL) throws -> ParquetProbe {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size >= 12 else { throw ProbeError.tooSmall(size) }

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 4) ?? Data()

        try handle.seek(toOffset: size - 8)
        let tail = try handle.read(upToCount: 8) ?? Data()

        var footerLength: UInt32?
        if tail.count == 8 {
            let b = [UInt8](tail.prefix(4))
            footerLength = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        return ParquetProbe(
            fileName: url.lastPathComponent,
            fileSize: size,
            headerMagicOK: head == magic,
            footerMagicOK: tail.suffix(4) == magic,
            footerLength: footerLength
        )
    }
}

enum PreviewHTML {
    static func render(_ p: ParquetProbe) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(p.fileSize), countStyle: .file)
        let status = p.isValid ? "✅ Valid Parquet magic (PAR1)" : "⚠️ Not a valid Parquet file"
        let footer = p.footerLength.map { "\($0) bytes" } ?? "—"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, system-ui, sans-serif; margin: 32px; }
          h1 { font-size: 20px; margin: 0 0 4px; }
          .sub { color: #888; margin-bottom: 20px; }
          table { border-collapse: collapse; }
          td { padding: 6px 16px 6px 0; border-bottom: 1px solid rgba(127,127,127,.25); }
          td:first-child { color: #888; }
        </style></head>
        <body>
          <h1>\(escape(p.fileName))</h1>
          <div class="sub">Laminat — Quick Look prototype</div>
          <table>
            <tr><td>Status</td><td>\(status)</td></tr>
            <tr><td>File size</td><td>\(size)</td></tr>
            <tr><td>Footer (metadata) size</td><td>\(footer)</td></tr>
          </table>
        </body></html>
        """
    }

    static func error(_ message: String, fileName: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font:14px system-ui;margin:32px\"><h1 style=\"font-size:20px\">\(escape(fileName))</h1><p>⚠️ \(escape(message))</p></body></html>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
