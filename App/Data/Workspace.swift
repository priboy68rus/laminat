import Foundation

/// Everything DuckDB-side for one document window: the database, the file registered as a table
/// (under its file name and as `t1`), the data grid's session, and SQL execution.
final class Workspace {
    let url: URL
    let summary: ParquetSummary
    /// The file's table name: file name without extension (SPEC §1.5).
    let tableName: String
    static let alias = "t1"
    /// SQL results keep at most this many rows; the rest is reported as truncated.
    static let maxResultRows = 1_000_000

    let database: Database
    let fileSession: TableSession

    private let sqlConnection: Connection
    private let sqlQueue = DispatchQueue(label: "laminat.sql", qos: .userInitiated)
    private let lock = NSLock()
    private var isRunningSQL = false
    private var resultCounter = 0

    init(url: URL) throws {
        self.url = url
        database = try Database(settings: EngineProfile.app.settings)
        sqlConnection = try Connection(database)
        summary = try ParquetFile(url: url, connection: sqlConnection).summary()

        tableName = url.deletingPathExtension().lastPathComponent
        try Self.registerViews(name: tableName, alias: Self.alias, url: url, on: sqlConnection)
        tables = [TableEntry(name: tableName, alias: Self.alias, url: url, columns: summary.columns, isPrimary: true)]

        fileSession = try TableSession(database: database, source: .parquet(url),
                                       columns: summary.columns, totalRows: Int(summary.rowCount))
    }

    /// The table name as it should be typed in SQL: bare if it is a plain identifier, quoted otherwise.
    var tableNameForSQL: String { Self.sqlName(tableName) }

    static func sqlName(_ name: String) -> String {
        let plain = name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        return plain ? name : SQL.identifier(name)
    }

    // MARK: Tables

    /// A file available to SQL in this window, under its file name and an alias (t1, t2, …).
    struct TableEntry {
        let name: String
        let alias: String
        let url: URL
        let columns: [ParquetColumn]
        /// The window's own file (can't be removed).
        let isPrimary: Bool
    }

    /// The window's file first, then files added in the SQL tab, in the order they were added.
    private(set) var tables: [TableEntry]
    private var nextAliasNumber = 2

    /// Makes another Parquet file queryable in this window (SQL tab → Tables → ＋ or drag and drop).
    /// Returns the existing entry if the file is already there. Footer only, so it is quick.
    func addFile(_ url: URL) throws -> TableEntry {
        if let existing = tables.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            return existing
        }
        let connection = try Connection(database)  // DDL off the SQL queue: a query may be running
        let summary = try ParquetFile(url: url, connection: connection).summary()

        // File name as the table name; "_2", "_3"… on a clash with a name or an alias already in use.
        let taken = Set(tables.flatMap { [$0.name.lowercased(), $0.alias.lowercased()] })
        let base = url.deletingPathExtension().lastPathComponent
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased()) || name.range(of: "^t[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
            name = "\(base)_\(suffix)"
            suffix += 1
        }
        let alias = "t\(nextAliasNumber)"
        nextAliasNumber += 1

        try Self.registerViews(name: name, alias: alias, url: url, on: connection)
        let entry = TableEntry(name: name, alias: alias, url: url, columns: summary.columns, isPrimary: false)
        tables.append(entry)
        return entry
    }

    func removeTable(alias: String) {
        guard let index = tables.firstIndex(where: { $0.alias == alias && !$0.isPrimary }),
              let connection = try? Connection(database) else { return }
        let entry = tables.remove(at: index)
        try? connection.execute("DROP VIEW IF EXISTS \(SQL.identifier(entry.alias))")
        try? connection.execute("DROP VIEW IF EXISTS \(SQL.identifier(entry.name))")
    }

    private static func registerViews(name: String, alias: String, url: URL, on connection: Connection) throws {
        let file = "read_parquet(\(SQL.string(url.path)))"
        try connection.execute("CREATE OR REPLACE VIEW \(SQL.identifier(alias)) AS SELECT * FROM \(file)")
        if name.lowercased() != alias.lowercased() {
            try connection.execute("CREATE OR REPLACE VIEW \(SQL.identifier(name)) AS SELECT * FROM \(file)")
        }
    }

    // MARK: SQL

    struct SQLResult {
        let session: TableSession
        let resultTable: String
        let rowCount: Int
        let truncated: Bool
        let duration: TimeInterval
    }

    /// Runs one read-only statement and stores its result (up to `maxResultRows` rows) in a table that
    /// the result grid pages through. Completion is called on the main queue.
    func runSQL(_ sql: String, completion: @escaping (Result<SQLResult, Error>) -> Void) {
        sqlQueue.async { [self] in
            lock.lock()
            isRunningSQL = true
            resultCounter += 1
            let table = "__laminat_result_\(resultCounter)"
            lock.unlock()

            let start = Date()
            let result = Result { try execute(sql, into: table, start: start) }

            lock.lock()
            isRunningSQL = false
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Cancels the running SQL statement, if any.
    func cancelSQL() {
        lock.lock()
        let running = isRunningSQL
        lock.unlock()
        if running { sqlConnection.interrupt() }
    }

    /// Frees a result table that is no longer displayed.
    func dropResult(_ result: SQLResult) {
        sqlQueue.async { [self] in
            try? sqlConnection.execute("DROP TABLE IF EXISTS \(SQL.identifier(result.resultTable))")
        }
    }

    private func execute(_ sql: String, into table: String, start: Date) throws -> SQLResult {
        let statement = Self.stripTrailingSemicolons(sql)
        let kinds = try sqlConnection.statementKinds(statement)
        guard kinds.count == 1 else {
            throw EngineError(message: "Run one statement at a time: select it and press ⌘↩.")
        }
        guard kinds[0] == .select else {
            throw EngineError(message: "Only read-only queries (SELECT, WITH, DESCRIBE, SUMMARIZE, …) are allowed.")
        }

        // Newlines around the statement keep a trailing "-- comment" from swallowing the parenthesis.
        try sqlConnection.execute("""
            CREATE TABLE \(SQL.identifier(table)) AS SELECT * FROM (
            \(statement)
            ) LIMIT \(Self.maxResultRows + 1)
            """)

        let count = try sqlConnection.query("SELECT count(*)::VARCHAR FROM \(SQL.identifier(table))")
            .readStrings().first?[0].flatMap { Int($0) } ?? 0
        let columns = try sqlConnection.query("""
            SELECT column_name::VARCHAR, column_type::VARCHAR FROM (DESCRIBE \(SQL.identifier(table)))
            """).readStrings().map { ParquetColumn(name: $0[0] ?? "", type: $0[1] ?? "") }

        let truncated = count > Self.maxResultRows
        if truncated {
            try sqlConnection.execute("DELETE FROM \(SQL.identifier(table)) WHERE rowid >= \(Self.maxResultRows)")
        }
        let rowCount = min(count, Self.maxResultRows)
        let session = try TableSession(database: database, source: .table(table), columns: columns, totalRows: rowCount)
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
