import Foundation

/// The DuckDB side of one query tab: runs read-only SQL against the app-wide catalog on its own
/// connection, keeps the current result in a temp table, and owns the files added to this query.
final class QuerySession {
    /// SQL results keep at most this many rows; the rest is reported as truncated.
    static let maxResultRows = 1_000_000

    struct SQLResult {
        let session: TableSession
        let resultTable: String
        let rowCount: Int
        let truncated: Bool
        let duration: TimeInterval
    }

    private let connection: Connection
    private let queue = DispatchQueue(label: "laminat.sql", qos: .userInitiated)
    private let lock = NSLock()
    private var isRunning = false
    private var resultCounter = 0
    /// Result tables share the app-wide database, so names carry a per-session prefix.
    private let resultPrefix = "__laminat_result_\(UUID().uuidString.prefix(8))"
    private(set) var addedFiles: [URL] = []

    init() throws {
        connection = try Connection(Catalog.shared.database)
    }

    // MARK: Tables

    /// Adds a Parquet file to the catalog on behalf of this query (sidebar ＋ / drag and drop).
    @discardableResult
    func addFile(_ url: URL) throws -> Catalog.TableEntry {
        let entry = try Catalog.shared.register(url, owner: self)
        if !addedFiles.contains(where: { Catalog.key($0) == Catalog.key(url) }) { addedFiles.append(url) }
        return entry
    }

    func removeFile(_ url: URL) {
        addedFiles.removeAll { Catalog.key($0) == Catalog.key(url) }
        Catalog.shared.unregister(url, owner: self)
    }

    func owns(_ url: URL) -> Bool { Catalog.shared.isOwned(url, by: self) }

    /// The tab closed: release added files.
    func close() {
        for url in addedFiles { Catalog.shared.unregister(url, owner: self) }
        addedFiles = []
    }

    // MARK: SQL

    /// Runs one read-only statement and stores its result (up to `maxResultRows` rows) in a table that
    /// the result grid pages through. Completion is called on the main queue.
    func run(_ sql: String, completion: @escaping (Result<SQLResult, Error>) -> Void) {
        queue.async { [self] in
            lock.lock()
            isRunning = true
            resultCounter += 1
            let table = "\(resultPrefix)_\(resultCounter)"
            lock.unlock()

            let start = Date()
            let result = Result { try execute(sql, into: table, start: start) }

            lock.lock()
            isRunning = false
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Cancels the running statement, if any.
    func cancel() {
        lock.lock()
        let running = isRunning
        lock.unlock()
        if running { connection.interrupt() }
    }

    /// Frees a result table that is no longer displayed.
    func dropResult(_ result: SQLResult) {
        queue.async { [self] in
            try? connection.execute("DROP TABLE IF EXISTS \(SQL.identifier(result.resultTable))")
        }
    }

    private func execute(_ sql: String, into table: String, start: Date) throws -> SQLResult {
        let statement = Self.stripTrailingSemicolons(sql)
        let kinds = try connection.statementKinds(statement)
        guard kinds.count == 1 else {
            throw EngineError(message: "Run one statement at a time: select it and press ⌘↩.")
        }
        guard kinds[0] == .select else {
            throw EngineError(message: "Only read-only queries (SELECT, WITH, DESCRIBE, SUMMARIZE, …) are allowed.")
        }

        // Newlines around the statement keep a trailing "-- comment" from swallowing the parenthesis.
        try connection.execute("""
            CREATE TABLE \(SQL.identifier(table)) AS SELECT * FROM (
            \(statement)
            ) LIMIT \(Self.maxResultRows + 1)
            """)

        let count = try connection.query("SELECT count(*)::VARCHAR FROM \(SQL.identifier(table))")
            .readStrings().first?[0].flatMap { Int($0) } ?? 0
        let columns = try connection.query("""
            SELECT column_name::VARCHAR, column_type::VARCHAR FROM (DESCRIBE \(SQL.identifier(table)))
            """).readStrings().map { ParquetColumn(name: $0[0] ?? "", type: $0[1] ?? "") }

        let truncated = count > Self.maxResultRows
        if truncated {
            try connection.execute("DELETE FROM \(SQL.identifier(table)) WHERE rowid >= \(Self.maxResultRows)")
        }
        let rowCount = min(count, Self.maxResultRows)
        let session = try TableSession(database: Catalog.shared.database, source: .table(table),
                                       columns: columns, totalRows: rowCount)
        return SQLResult(session: session, resultTable: table, rowCount: rowCount, truncated: truncated,
                         duration: Date().timeIntervalSince(start))
    }

    private static func stripTrailingSemicolons(_ sql: String) -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
