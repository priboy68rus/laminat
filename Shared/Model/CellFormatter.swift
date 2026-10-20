import Foundation

/// Naive v1 value formatting: values as DuckDB renders them, nested types as one-line JSON,
/// long values cut, binary shown by size.
enum CellFormatter {
    static func display(_ raw: String?, kind: ParquetColumn.Kind, maxChars: Int) -> String? {
        guard let raw else { return nil }
        switch kind {
        case .binary:
            let bytes = Int64(raw) ?? 0
            return "<binary \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))>"
        default:
            return raw.count > maxChars ? String(raw.prefix(maxChars)) + "…" : raw
        }
    }
}
