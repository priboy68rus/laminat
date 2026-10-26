import Foundation

/// The app-wide DuckDB database and the tables queries can use: every open file (Parquet, CSV, JSON,
/// Excel), plus files added to a query (Tables sidebar ＋ / drag and drop).
///
/// A single-table file is a view under its file name (`name_2`… on a clash). A workbook is a schema named
/// after the file with one view per sheet (`sales.Orders`). Every table also gets an alias `t1`, `t2`…
/// Tables stay registered while anyone owns the file — its window, or a query it was added to — and are
/// dropped when the last owner lets go. Main thread only.
final class Catalog {
    static let shared: Catalog = {
        do { return try Catalog() } catch { fatalError("Can't open DuckDB: \(error.localizedDescription)") }
    }()

    /// Posted on the main queue whenever tables are added or removed.
    static let didChange = Notification.Name("LaminatCatalogDidChange")

    struct TableEntry {
        /// Schema of a multi-sheet workbook (the file name); nil for single-table files.
        let schema: String?
        /// The file name (single-table files) or the sheet name (workbooks).
        let table: String
        let alias: String
        let url: URL
        let sheet: String?
        let columns: [ParquetColumn]
        let rowCount: Int
        /// Where the rows live: the Parquet file itself, or the table a file / sheet was loaded into.
        let source: TableSession.Source
        let importedTable: String?

        /// Display name: `table` or `schema.table`.
        var name: String { schema.map { "\($0).\(table)" } ?? table }
        /// The name as typed in SQL, each part quoted only if it needs to be.
        var sqlName: String { schema.map { "\(Catalog.sqlName($0)).\(Catalog.sqlName(table))" } ?? Catalog.sqlName(table) }
    }

    let database: Database
    private(set) var tables: [TableEntry] = []
    private var owners: [URL: Set<ObjectIdentifier>] = [:]
    private var nextAliasNumber = 1

    private init() throws {
        database = try Database(settings: EngineProfile.app.settings)
    }

    static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// All tables of a file (one, or one per sheet), in file order.
    func entries(for url: URL) -> [TableEntry] {
        let key = Self.key(url)
        return tables.filter { Self.key($0.url) == key }
    }

    func isOwned(_ url: URL, by owner: AnyObject) -> Bool {
        owners[Self.key(url)]?.contains(ObjectIdentifier(owner)) ?? false
    }

    /// Adds `owner` to an already registered file; nil if the file isn't registered.
    func retain(_ url: URL, owner: AnyObject) -> [TableEntry]? {
        let existing = entries(for: url)
        guard !existing.isEmpty else { return nil }
        owners[Self.key(url), default: []].insert(ObjectIdentifier(owner))
        return existing
    }

    /// Registers a loaded file's tables, owned by `owner` (FileLoader reads off the main thread).
    /// If the file got registered meanwhile, the existing tables are reused.
    @discardableResult
    func register(_ loaded: FileLoader.Loaded, owner: AnyObject) throws -> [TableEntry] {
        let connection = try Connection(database)
        if let existing = retain(loaded.url, owner: owner) {
            for table in loaded.tables {
                if let imported = table.importedTable { try? connection.execute("DROP TABLE IF EXISTS \(SQL.identifier(imported))") }
            }
            return existing
        }

        let base = loaded.url.deletingPathExtension().lastPathComponent
        // A workbook with several sheets becomes a schema; a single-sheet one is just a table, like a CSV.
        let isWorkbook = loaded.tables.count > 1
        let topName = uniqueTopLevelName(base)

        var added: [TableEntry] = []
        if isWorkbook {
            try connection.execute("CREATE SCHEMA IF NOT EXISTS \(SQL.identifier(topName))")
        }
        for table in loaded.tables {
            let alias = "t\(nextAliasNumber)"
            nextAliasNumber += 1
            let entry = TableEntry(schema: isWorkbook ? topName : nil, table: isWorkbook ? (table.sheet ?? base) : topName,
                                   alias: alias, url: loaded.url, sheet: table.sheet, columns: table.summary.columns,
                                   rowCount: Int(table.summary.rowCount), source: table.source,
                                   importedTable: table.importedTable)
            try connection.execute("CREATE OR REPLACE VIEW \(SQL.identifier(alias)) AS SELECT * FROM \(table.relation)")
            try connection.execute("CREATE OR REPLACE VIEW \(qualified(entry)) AS SELECT * FROM \(table.relation)")
            added.append(entry)
        }

        tables.append(contentsOf: added)
        owners[Self.key(loaded.url)] = [ObjectIdentifier(owner)]
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return added
    }

    /// Releases `owner`'s hold on `url`; drops the file's tables when nobody owns it any more.
    func unregister(_ url: URL, owner: AnyObject) {
        let key = Self.key(url)
        owners[key]?.remove(ObjectIdentifier(owner))
        guard owners[key]?.isEmpty ?? true else { return }
        owners[key] = nil
        let dropped = entries(for: url)
        guard !dropped.isEmpty else { return }
        tables.removeAll { Self.key($0.url) == key }
        if let connection = try? Connection(database) {
            for entry in dropped {
                try? connection.execute("DROP VIEW IF EXISTS \(SQL.identifier(entry.alias))")
                try? connection.execute("DROP VIEW IF EXISTS \(qualified(entry))")
                if let table = entry.importedTable { try? connection.execute("DROP TABLE IF EXISTS \(SQL.identifier(table))") }
            }
            if let schema = dropped.first?.schema { try? connection.execute("DROP SCHEMA IF EXISTS \(SQL.identifier(schema))") }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A name that clashes with no table, schema or alias in use (file name, then `_2`, `_3`…).
    private func uniqueTopLevelName(_ base: String) -> String {
        let taken = Set(tables.flatMap { [($0.schema ?? $0.table).lowercased(), $0.alias.lowercased()] })
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased())
                || name.range(of: "^t[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
            name = "\(base)_\(suffix)"
            suffix += 1
        }
        return name
    }

    private func qualified(_ entry: TableEntry) -> String {
        entry.schema.map { "\(SQL.identifier($0)).\(SQL.identifier(entry.table))" } ?? SQL.identifier(entry.table)
    }

    /// A name as it should be typed in SQL: bare if it is a plain identifier, quoted otherwise.
    static func sqlName(_ name: String) -> String {
        let plain = name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        return plain ? name : SQL.identifier(name)
    }
}
