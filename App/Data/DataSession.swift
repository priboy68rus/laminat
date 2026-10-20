import Foundation

/// Sort and filters applied to the grid.
struct ViewSpec: Equatable {
    struct Sort: Equatable {
        var column: Int
        var ascending: Bool
    }

    var sort: Sort?
    /// Column index → "contains" text (case-insensitive). Empty strings are ignored.
    var filters: [Int: String] = [:]

    var activeFilters: [Int: String] { filters.filter { !$0.value.isEmpty } }
    var isIdentity: Bool { sort == nil && activeFilters.isEmpty }
}

/// One open Parquet file: a DuckDB instance plus the current view of the data.
///
/// Paging strategy (see SPEC §3):
/// - identity view: pages are row ranges read straight from the file by `file_row_number`,
///   so DuckDB only decodes the row groups that contain them;
/// - sorted / filtered view: a small index table `(position → file_row_number)` is built once,
///   then each page looks up its row numbers and fetches just those rows from the file.
///
/// All DuckDB work runs on two serial queues — one for page reads, one for building views — each
/// with its own connection. Completions are delivered on the main queue.
final class DataSession {
    struct View {
        let id: Int
        let spec: ViewSpec
        /// Index table name, nil for the identity view.
        let indexTable: String?
        let rowCount: Int
    }

    let url: URL
    let summary: ParquetSummary
    var columns: [ParquetColumn] { summary.columns }

    static let maxCellChars = 300
    /// Rows per page, smaller for wide files so a page stays around 100k cells.
    let pageSize: Int

    private let database: Database
    private let pageConnection: Connection
    private let buildConnection: Connection
    private let pageQueue = DispatchQueue(label: "laminat.pages", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "laminat.build", qos: .userInitiated)

    private let lock = NSLock()
    private var latestBuildID = 0
    private var buildingID: Int?
    private var nextViewID = 1

    private var source: String { "read_parquet(\(SQL.string(url.path)), file_row_number = true)" }

    init(url: URL) throws {
        self.url = url
        database = try Database(settings: EngineProfile.app.settings)
        pageConnection = try Connection(database)
        buildConnection = try Connection(database)
        summary = try ParquetFile(url: url, connection: pageConnection).summary()
        pageSize = max(100, min(1000, 100_000 / max(1, summary.columns.count)))
    }

    var identityView: View {
        View(id: 0, spec: ViewSpec(), indexTable: nil, rowCount: Int(summary.rowCount))
    }

    // MARK: Pages

    /// Loads page `page` of `view`. `isWanted` is checked on the page queue right before the query,
    /// so pages the user has already scrolled past are skipped instead of queueing up.
    func loadPage(_ page: Int, of view: View, isWanted: @escaping () -> Bool,
                  completion: @escaping (Result<[[String?]], Error>?) -> Void) {
        pageQueue.async { [self] in
            guard isWanted() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = Result { try fetchPage(page, of: view) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous variant for copy: blocks the caller until the page is read.
    func loadPageSync(_ page: Int, of view: View) throws -> [[String?]] {
        try pageQueue.sync { try fetchPage(page, of: view) }
    }

    private func fetchPage(_ page: Int, of view: View) throws -> [[String?]] {
        let start = page * pageSize
        let end = min(start + pageSize, view.rowCount)
        guard start < end else { return [] }

        let projection = (columns.map { ParquetFile.displayExpression($0, maxChars: Self.maxCellChars) }
                          + ["file_row_number::VARCHAR"]).joined(separator: ", ")

        guard let indexTable = view.indexTable else {
            let rows = try pageConnection.query("""
                SELECT \(projection) FROM \(source)
                WHERE file_row_number >= \(start) AND file_row_number < \(end)
                ORDER BY file_row_number
                """).readStrings()
            return rows.map { Array($0.dropLast()) }
        }

        let rowNumbers = try pageConnection.query("""
            SELECT r::VARCHAR FROM \(indexTable) WHERE rowid >= \(start) AND rowid < \(end) ORDER BY rowid
            """).readStrings().compactMap { $0[0] }
        guard !rowNumbers.isEmpty else { return [] }

        let rows = try pageConnection.query("""
            SELECT \(projection) FROM \(source) WHERE file_row_number IN (\(rowNumbers.joined(separator: ",")))
            """).readStrings()

        // The file scan returns rows in file order; put them back in view order.
        var byRowNumber: [String: [String?]] = [:]
        byRowNumber.reserveCapacity(rows.count)
        for row in rows {
            if let key = row.last ?? nil { byRowNumber[key] = Array(row.dropLast()) }
        }
        return rowNumbers.map { byRowNumber[$0] ?? Array(repeating: nil, count: columns.count) }
    }

    // MARK: Views

    /// Builds the view for `spec`. A newer call cancels a build that is still running; the cancelled
    /// call never completes.
    func makeView(_ spec: ViewSpec, completion: @escaping (Result<View, Error>) -> Void) {
        lock.lock()
        latestBuildID += 1
        let buildID = latestBuildID
        let interruptRunning = buildingID != nil
        lock.unlock()
        if interruptRunning { buildConnection.interrupt() }

        buildQueue.async { [self] in
            lock.lock()
            guard buildID == latestBuildID else { lock.unlock(); return }
            buildingID = buildID
            let viewID = nextViewID
            nextViewID += 1
            lock.unlock()

            var result = Result { try buildView(spec, id: viewID) }
            // An interrupt aimed at the previous build can land on this one if that build had just
            // finished; retry once when we are still the latest request.
            if case .failure(let error) = result, error.localizedDescription.localizedCaseInsensitiveContains("interrupt") {
                lock.lock()
                let stillLatest = buildID == latestBuildID
                lock.unlock()
                if stillLatest { result = Result { try buildView(spec, id: viewID) } }
            }

            lock.lock()
            buildingID = nil
            let isLatest = buildID == latestBuildID
            lock.unlock()

            guard isLatest else {
                if case .success(let view) = result { dropView(view) }
                return
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Frees the index table of a view that is no longer displayed.
    func dropView(_ view: View) {
        guard let table = view.indexTable else { return }
        buildQueue.async { [self] in try? buildConnection.execute("DROP TABLE IF EXISTS \(table)") }
    }

    private func buildView(_ spec: ViewSpec, id: Int) throws -> View {
        guard !spec.isIdentity else {
            return View(id: id, spec: spec, indexTable: nil, rowCount: Int(summary.rowCount))
        }

        let conditions = spec.activeFilters.sorted { $0.key < $1.key }.map { column, text in
            "contains(lower(\(ParquetFile.textExpression(columns[column]))), \(SQL.string(text.lowercased())))"
        }
        var sql = "SELECT file_row_number AS r FROM \(source)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if let sort = spec.sort {
            sql += " ORDER BY \(SQL.identifier(columns[sort.column].name)) \(sort.ascending ? "ASC" : "DESC") NULLS LAST, r"
        } else {
            sql += " ORDER BY r"
        }

        let table = "view_\(id)"
        try buildConnection.execute("CREATE TABLE \(table) AS \(sql)")
        let count = try buildConnection.query("SELECT count(*)::VARCHAR FROM \(table)").readStrings().first?[0]
        return View(id: id, spec: spec, indexTable: table, rowCount: count.flatMap { Int($0) } ?? 0)
    }
}
