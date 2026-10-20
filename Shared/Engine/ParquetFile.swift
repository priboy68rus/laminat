import Foundation

struct ParquetColumn {
    enum Kind { case number, text, nested, binary, other }

    let name: String
    let type: String
    let kind: Kind

    init(name: String, type: String) {
        self.name = name
        self.type = type
        self.kind = Self.kind(of: type.uppercased())
    }

    private static func kind(of type: String) -> Kind {
        if type.hasSuffix("]") || ["STRUCT", "MAP", "UNION", "VARIANT"].contains(where: type.hasPrefix) { return .nested }
        if type == "BLOB" { return .binary }
        if type == "VARCHAR" { return .text }
        let numeric = ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT",
                       "UINTEGER", "UBIGINT", "UHUGEINT", "FLOAT", "DOUBLE", "DECIMAL"]
        if numeric.contains(where: type.hasPrefix) { return .number }
        return .other
    }
}

struct ParquetSummary {
    let url: URL
    let fileSize: Int64
    let rowCount: Int64
    let rowGroupCount: Int64
    let createdBy: String?
    let columns: [ParquetColumn]
}

/// Reads Parquet metadata and rows through DuckDB. Values come back as display strings,
/// already truncated, so callers never pull huge cells across the C boundary.
struct ParquetFile {
    let url: URL
    let connection: Connection

    private var source: String { "read_parquet(\(SQL.string(url.path)))" }

    /// Footer-only: schema, row count and row groups, without touching the data pages.
    func summary() throws -> ParquetSummary {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let meta = try connection.query("""
            SELECT num_rows::VARCHAR, num_row_groups::VARCHAR, created_by::VARCHAR
            FROM parquet_file_metadata(\(SQL.string(url.path)))
            """).readStrings().first

        let columns = try connection.query("""
            SELECT column_name::VARCHAR, column_type::VARCHAR FROM (DESCRIBE SELECT * FROM \(source))
            """).readStrings().map { ParquetColumn(name: $0[0] ?? "", type: $0[1] ?? "") }

        return ParquetSummary(
            url: url,
            fileSize: fileSize,
            rowCount: meta?[0].flatMap { Int64($0) } ?? 0,
            rowGroupCount: meta?[1].flatMap { Int64($0) } ?? 0,
            createdBy: meta?[2] ?? nil,
            columns: columns
        )
    }

    /// First `limit` rows, every column converted to a display string of at most `maxChars` characters
    /// (plus one, so the formatter can tell that a value was cut). Binary columns return their byte length.
    func head(columns: [ParquetColumn], limit: Int, maxChars: Int) throws -> [[String?]] {
        guard !columns.isEmpty else { return [] }
        let projection = columns.map { column -> String in
            let ref = SQL.identifier(column.name)
            switch column.kind {
            case .binary: return "octet_length(\(ref))::VARCHAR"
            case .nested: return "left(to_json(\(ref))::VARCHAR, \(maxChars + 1))"
            default: return "left(\(ref)::VARCHAR, \(maxChars + 1))"
            }
        }.joined(separator: ", ")
        return try connection.query("SELECT \(projection) FROM \(source) LIMIT \(limit)").readStrings()
    }
}
