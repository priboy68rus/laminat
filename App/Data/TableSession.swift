import Foundation

/// Sort and filters applied to a grid.
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

/// Paged, sortable, filterable access to one relation: the Parquet file itself or a SQL result table.
///
/// Paging strategy (see SPEC §3):
/// - identity view: pages are ranges of the row id (`file_row_number` for the file, `rowid` for a
///   table), so DuckDB only reads the row groups that contain them;
/// - sorted / filtered view: a small index table `(position → row id)` is built once, then each page
///   looks up its row ids and fetches just those rows.
///
/// DuckDB work runs on two serial queues — page reads and view builds — each with its own connection.
/// Completions are delivered on the main queue.
final class TableSession {
    enum Source {
        case parquet(URL)
        case table(String)

        var expression: String {
            switch self {
            case .parquet(let url): "read_parquet(\(SQL.string(url.path)), file_row_number = true)"
            case .table(let name): SQL.identifier(name)
            }
        }

        var rowID: String {
            switch self {
            case .parquet: "file_row_number"
            case .table: "rowid"
            }
        }
    }

    struct View {
        let id: Int
        let spec: ViewSpec
        /// Index table name, nil for the identity view.
        let indexTable: String?
        let rowCount: Int

        /// Rows per page. Fetching rows by number costs about the same for 1 000 or 5 000 of them
        /// (the time goes into decoding the row groups they live in), so index views use bigger pages.
        var pageSize: Int { indexTable == nil ? 1000 : 5000 }
    }

    /// One page, column-major: data column index → values (display strings, nil = NULL).
    typealias PageColumns = [Int: [String?]]

    let source: Source
    let columns: [ParquetColumn]
    /// Rows in the relation before filtering.
    let totalRows: Int

    static let maxCellChars = 300

    private let pageConnection: Connection
    private let buildConnection: Connection
    private let pageQueue = DispatchQueue(label: "laminat.pages", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "laminat.build", qos: .userInitiated)

    private let lock = NSLock()
    private var latestBuildID = 0
    private var buildingID: Int?
    private var nextViewID = 1
    private var liveIndexTables: Set<String> = []

    /// Unique prefix for this session's index tables (several sessions share one database).
    private let tablePrefix = "__laminat_view_\(UUID().uuidString.prefix(8))"

    init(database: Database, source: Source, columns: [ParquetColumn], totalRows: Int) throws {
        self.source = source
        self.columns = columns
        self.totalRows = totalRows
        pageConnection = try Connection(database)
        buildConnection = try Connection(database)
    }

    deinit {
        let connection = buildConnection
        let tables = liveIndexTables
        buildQueue.async {
            for table in tables { try? connection.execute("DROP TABLE IF EXISTS \(SQL.identifier(table))") }
        }
    }

    var identityView: View {
        View(id: 0, spec: ViewSpec(), indexTable: nil, rowCount: totalRows)
    }

    // MARK: Pages

    /// Loads `columns` of page `page` of `view`. Only visible columns are requested: decoding wide or
    /// heavy columns nobody looks at is what makes pages slow. Right before the query `stillWanted`
    /// narrows the request to the columns that are still on screen (empty = skip the page), so a fast
    /// scroll doesn't leave a backlog of reads for columns and rows the user has already passed.
    /// The completion gets nil for a skipped request.
    func loadPage(_ page: Int, columns requested: [Int], of view: View,
                  stillWanted: @escaping ([Int]) -> [Int],
                  completion: @escaping (Result<PageColumns, Error>?) -> Void) {
        pageQueue.async { [self] in
            let columns = stillWanted(requested)
            guard !columns.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = Result { try fetchPage(page, columns: columns, of: view) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous variant for copy: blocks the caller until the page is read.
    func loadPageSync(_ page: Int, columns wanted: [Int], of view: View) throws -> PageColumns {
        try pageQueue.sync { try fetchPage(page, columns: wanted, of: view) }
    }

    private func fetchPage(_ page: Int, columns wanted: [Int], of view: View) throws -> PageColumns {
        let start = page * view.pageSize
        let end = min(start + view.pageSize, view.rowCount)
        guard start < end, !wanted.isEmpty else { return [:] }

        let rowID = source.rowID
        let projection = (wanted.map { ParquetFile.displayExpression(columns[$0], maxChars: Self.maxCellChars) }
                          + ["\(rowID)::VARCHAR"]).joined(separator: ", ")

        let rows: [[String?]]
        if let indexTable = view.indexTable {
            let rowIDs = try pageConnection.query("""
                SELECT r::VARCHAR FROM \(SQL.identifier(indexTable)) WHERE rowid >= \(start) AND rowid < \(end) ORDER BY rowid
                """).readStrings().compactMap { $0[0] }
            guard !rowIDs.isEmpty else { return [:] }
            let fetched = try pageConnection.query("""
                SELECT \(projection) FROM \(source.expression) WHERE \(rowID) IN (\(rowIDs.joined(separator: ",")))
                """).readStrings()
            // The scan returns rows in storage order; put them back in view order.
            var byRowID: [String: [String?]] = [:]
            byRowID.reserveCapacity(fetched.count)
            for row in fetched {
                if let key = row.last ?? nil { byRowID[key] = row }
            }
            rows = rowIDs.map { byRowID[$0] ?? Array(repeating: nil, count: wanted.count + 1) }
        } else {
            rows = try pageConnection.query("""
                SELECT \(projection) FROM \(source.expression)
                WHERE \(rowID) >= \(start) AND \(rowID) < \(end)
                ORDER BY \(rowID)
                """).readStrings()
        }

        var result: PageColumns = [:]
        for (position, column) in wanted.enumerated() {
            result[column] = rows.map { $0[position] }
        }
        return result
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
        buildQueue.async { [self] in
            try? buildConnection.execute("DROP TABLE IF EXISTS \(SQL.identifier(table))")
            lock.lock()
            liveIndexTables.remove(table)
            lock.unlock()
        }
    }

    /// SQL conditions (joined with AND) for the "contains" filters of `spec`.
    static func filterConditions(_ spec: ViewSpec, columns: [ParquetColumn]) -> [String] {
        spec.activeFilters.sorted { $0.key < $1.key }.map { column, text in
            "contains(lower(\(ParquetFile.textExpression(columns[column]))), \(SQL.string(text.lowercased())))"
        }
    }

    private func buildView(_ spec: ViewSpec, id: Int) throws -> View {
        guard !spec.isIdentity else {
            return View(id: id, spec: spec, indexTable: nil, rowCount: totalRows)
        }

        let conditions = Self.filterConditions(spec, columns: columns)
        var sql = "SELECT \(source.rowID) AS r FROM \(source.expression)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if let sort = spec.sort {
            sql += " ORDER BY \(SQL.identifier(columns[sort.column].name)) \(sort.ascending ? "ASC" : "DESC") NULLS LAST, r"
        } else {
            sql += " ORDER BY r"
        }

        let table = "\(tablePrefix)_\(id)"
        try buildConnection.execute("CREATE TABLE \(SQL.identifier(table)) AS \(sql)")
        lock.lock()
        liveIndexTables.insert(table)
        lock.unlock()
        let count = try buildConnection.query("SELECT count(*)::VARCHAR FROM \(SQL.identifier(table))").readStrings().first?[0]
        return View(id: id, spec: spec, indexTable: table, rowCount: count.flatMap { Int($0) } ?? 0)
    }
}
