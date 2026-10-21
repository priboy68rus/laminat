import Foundation

/// The app-wide DuckDB database and the tables queries can use: every open Parquet file, plus files
/// added to a query (Tables sidebar ＋ / drag and drop). Each table is a view under the file name
/// (`name_2`… on a clash) and an alias `t1`, `t2`… A table stays registered while anyone owns it — the
/// file's window, or a query it was added to — and is dropped when the last owner lets go.
/// Main thread only.
final class Catalog {
    static let shared: Catalog = {
        do { return try Catalog() } catch { fatalError("Can't open DuckDB: \(error.localizedDescription)") }
    }()

    /// Posted on the main queue whenever tables are added or removed.
    static let didChange = Notification.Name("LaminatCatalogDidChange")

    struct TableEntry {
        let name: String
        let alias: String
        let url: URL
        let columns: [ParquetColumn]
        let rowCount: Int
    }

    let database: Database
    private(set) var tables: [TableEntry] = []
    private var owners: [URL: Set<ObjectIdentifier>] = [:]
    private var nextAliasNumber = 1

    private init() throws {
        database = try Database(settings: EngineProfile.app.settings)
    }

    static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    func entry(for url: URL) -> TableEntry? {
        let key = Self.key(url)
        return tables.first { Self.key($0.url) == key }
    }

    func isOwned(_ url: URL, by owner: AnyObject) -> Bool {
        owners[Self.key(url)]?.contains(ObjectIdentifier(owner)) ?? false
    }

    /// Makes `url` a table (or adds `owner` to an existing one). Reads only the footer.
    @discardableResult
    func register(_ url: URL, owner: AnyObject, summary known: ParquetSummary? = nil) throws -> TableEntry {
        let key = Self.key(url)
        if let existing = entry(for: url) {
            owners[key, default: []].insert(ObjectIdentifier(owner))
            return existing
        }

        let connection = try Connection(database)
        let summary = try known ?? ParquetFile(url: url, connection: connection).summary()

        // File name as the table name; "_2", "_3"… on a clash with a name or alias in use.
        let taken = Set(tables.flatMap { [$0.name.lowercased(), $0.alias.lowercased()] })
        let base = url.deletingPathExtension().lastPathComponent
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased())
                || name.range(of: "^t[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
            name = "\(base)_\(suffix)"
            suffix += 1
        }
        let alias = "t\(nextAliasNumber)"
        nextAliasNumber += 1

        let file = "read_parquet(\(SQL.string(url.path)))"
        try connection.execute("CREATE OR REPLACE VIEW \(SQL.identifier(alias)) AS SELECT * FROM \(file)")
        if name.lowercased() != alias.lowercased() {
            try connection.execute("CREATE OR REPLACE VIEW \(SQL.identifier(name)) AS SELECT * FROM \(file)")
        }

        let entry = TableEntry(name: name, alias: alias, url: url, columns: summary.columns, rowCount: Int(summary.rowCount))
        tables.append(entry)
        owners[key] = [ObjectIdentifier(owner)]
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return entry
    }

    /// Releases `owner`'s hold on `url`; drops the table when nobody owns it any more.
    func unregister(_ url: URL, owner: AnyObject) {
        let key = Self.key(url)
        owners[key]?.remove(ObjectIdentifier(owner))
        guard owners[key]?.isEmpty ?? true, let index = tables.firstIndex(where: { Self.key($0.url) == key }) else { return }
        owners[key] = nil
        let entry = tables.remove(at: index)
        if let connection = try? Connection(database) {
            try? connection.execute("DROP VIEW IF EXISTS \(SQL.identifier(entry.alias))")
            try? connection.execute("DROP VIEW IF EXISTS \(SQL.identifier(entry.name))")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A table name as it should be typed in SQL: bare if it is a plain identifier, quoted otherwise.
    static func sqlName(_ name: String) -> String {
        let plain = name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        return plain ? name : SQL.identifier(name)
    }
}
