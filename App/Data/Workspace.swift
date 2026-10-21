import Foundation

/// One open Parquet file: its footer summary, its table in the app-wide catalog, and the data grid's
/// session. SQL lives in query tabs (QuerySession), which see every open file.
final class Workspace {
    let url: URL
    let summary: ParquetSummary
    let table: Catalog.TableEntry
    let fileSession: TableSession

    /// Identifies this window as an owner of its catalog table.
    private let owner = NSObject()

    var database: Database { Catalog.shared.database }
    /// The file's table name: file name without extension (SPEC §1.5).
    var tableName: String { table.name }
    var tableNameForSQL: String { Catalog.sqlName(table.name) }

    init(url: URL) throws {
        self.url = url
        let connection = try Connection(Catalog.shared.database)
        summary = try ParquetFile(url: url, connection: connection).summary()
        table = try Catalog.shared.register(url, owner: owner, summary: summary)
        fileSession = try TableSession(database: Catalog.shared.database, source: .parquet(url),
                                       columns: summary.columns, totalRows: Int(summary.rowCount))
    }

    /// The window closed: let go of the file's table.
    func close() {
        Catalog.shared.unregister(url, owner: owner)
    }
}
