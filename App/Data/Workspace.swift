import Foundation

/// One open file (Parquet, CSV, JSON or Excel): its summary, its table in the app-wide catalog, and the
/// data grid's session. SQL lives in query tabs (QuerySession), which see every open file.
final class Workspace {
    let url: URL
    let format: DataFormat
    let summary: ParquetSummary
    let table: Catalog.TableEntry
    let fileSession: TableSession

    /// Identifies this window as an owner of its catalog table.
    private let owner = NSObject()

    var database: Database { Catalog.shared.database }
    /// Where the rows live (the Parquet file, or the table another format was loaded into).
    var source: TableSession.Source { table.source }
    /// The file's table name: file name without extension (SPEC §1.5).
    var tableName: String { table.name }
    var tableNameForSQL: String { Catalog.sqlName(table.name) }

    /// Main thread: registers a file that FileLoader has read.
    init(_ loaded: FileLoader.Loaded) throws {
        url = loaded.url
        format = loaded.format
        summary = loaded.summary
        table = try Catalog.shared.register(loaded, owner: owner)
        fileSession = try TableSession(database: Catalog.shared.database, source: table.source,
                                       columns: summary.columns, totalRows: Int(summary.rowCount))
    }

    /// Synchronous open (CLI and tests): read and register in one go.
    convenience init(url: URL) throws {
        try self.init(FileLoader(url: url).loadSync())
    }

    /// The window closed: let go of the file's table.
    func close() {
        Catalog.shared.unregister(url, owner: owner)
    }
}
