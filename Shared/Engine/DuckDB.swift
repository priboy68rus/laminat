import Foundation
import CDuckDB

struct EngineError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// In-memory DuckDB instance. Settings are applied at open time (see `EngineProfile`).
final class Database {
    fileprivate var handle: duckdb_database?

    init(settings: [(String, String)] = []) throws {
        var config: duckdb_config?
        guard duckdb_create_config(&config) == DuckDBSuccess else {
            throw EngineError(message: "Failed to create DuckDB config")
        }
        defer { duckdb_destroy_config(&config) }

        for (name, value) in settings where duckdb_set_config(config, name, value) != DuckDBSuccess {
            throw EngineError(message: "Invalid DuckDB setting \(name)=\(value)")
        }

        var error: UnsafeMutablePointer<CChar>?
        if duckdb_open_ext(nil, &handle, config, &error) != DuckDBSuccess {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            duckdb_free(error)
            throw EngineError(message: "Failed to open DuckDB: \(message)")
        }
    }

    deinit { duckdb_close(&handle) }

    static var libraryVersion: String { String(cString: duckdb_library_version()) }
}

final class Connection {
    let database: Database
    private var handle: duckdb_connection?

    init(_ database: Database) throws {
        self.database = database
        guard duckdb_connect(database.handle, &handle) == DuckDBSuccess else {
            throw EngineError(message: "Failed to connect to DuckDB")
        }
    }

    deinit { duckdb_disconnect(&handle) }

    /// Cancels the query currently running on this connection (safe to call from another thread).
    func interrupt() { duckdb_interrupt(handle) }

    func query(_ sql: String) throws -> QueryResult {
        var result = duckdb_result()
        if duckdb_query(handle, sql, &result) != DuckDBSuccess {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown error"
            duckdb_destroy_result(&result)
            throw EngineError(message: message)
        }
        return QueryResult(result)
    }

    func execute(_ sql: String) throws {
        _ = try query(sql)
    }

    enum StatementKind { case select, explain, other }

    /// Parses and binds `sql` without running it and returns the kind of every statement in it.
    /// Throws the parser / binder error (with DuckDB's position marker) for invalid SQL.
    func statementKinds(_ sql: String) throws -> [StatementKind] {
        var extracted: duckdb_extracted_statements?
        defer { duckdb_destroy_extracted(&extracted) }
        let count = duckdb_extract_statements(handle, sql, &extracted)
        if count == 0 {
            let message = duckdb_extract_statements_error(extracted).map { String(cString: $0) }
            throw EngineError(message: message ?? "No SQL statement to run")
        }

        return try (0..<count).map { index in
            var prepared: duckdb_prepared_statement?
            defer { duckdb_destroy_prepare(&prepared) }
            if duckdb_prepare_extracted_statement(handle, extracted, index, &prepared) != DuckDBSuccess {
                let message = duckdb_prepare_error(prepared).map { String(cString: $0) } ?? "unknown error"
                throw EngineError(message: message)
            }
            switch duckdb_prepared_statement_type(prepared) {
            case DUCKDB_STATEMENT_TYPE_SELECT: return .select
            case DUCKDB_STATEMENT_TYPE_EXPLAIN: return .explain
            default: return .other
            }
        }
    }
}

final class QueryResult {
    private var result: duckdb_result
    let columnNames: [String]

    fileprivate init(_ result: duckdb_result) {
        var result = result
        let count = duckdb_column_count(&result)
        columnNames = (0..<count).map { String(cString: duckdb_column_name(&result, $0)) }
        self.result = result
    }

    deinit { duckdb_destroy_result(&result) }

    /// Reads every row. All result columns must be VARCHAR: callers cast in SQL, which keeps
    /// value formatting in DuckDB's vectorized code instead of per-value Swift conversions.
    func readStrings() throws -> [[String?]] {
        let columnCount = columnNames.count
        for column in 0..<columnCount where duckdb_column_type(&result, idx_t(column)) != DUCKDB_TYPE_VARCHAR {
            throw EngineError(message: "Column \(columnNames[column]) is not VARCHAR")
        }

        var rows: [[String?]] = []
        while let fetched = duckdb_fetch_chunk(result) {
            var chunk: duckdb_data_chunk? = fetched
            defer { duckdb_destroy_data_chunk(&chunk) }
            let size = Int(duckdb_data_chunk_get_size(chunk))

            let vectors = (0..<columnCount).map { column -> (UnsafeMutablePointer<duckdb_string_t>, UnsafeMutablePointer<UInt64>?) in
                let vector = duckdb_data_chunk_get_vector(chunk, idx_t(column))
                let data = duckdb_vector_get_data(vector)!.assumingMemoryBound(to: duckdb_string_t.self)
                return (data, duckdb_vector_get_validity(vector))
            }

            rows.reserveCapacity(rows.count + size)
            for row in 0..<size {
                var values = [String?]()
                values.reserveCapacity(columnCount)
                for (data, validity) in vectors {
                    if let validity, !duckdb_validity_row_is_valid(validity, idx_t(row)) {
                        values.append(nil)
                        continue
                    }
                    let string = data + row
                    let length = Int(duckdb_string_t_length(string.pointee))
                    let bytes = UnsafeRawBufferPointer(start: duckdb_string_t_data(string), count: length)
                    values.append(String(decoding: bytes, as: UTF8.self))
                }
                rows.append(values)
            }
        }
        return rows
    }
}

enum SQL {
    static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func string(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
