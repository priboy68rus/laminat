import Foundation

/// One open file (Parquet, CSV, JSON or Excel): its tables in the app-wide catalog — one, or one per
/// workbook sheet — each with the data grid's session. SQL lives in query tabs (QuerySession), which see
/// every open file.
final class Workspace {
    /// One table of the file: the file itself, or a workbook sheet.
    struct Sheet {
        let entry: Catalog.TableEntry
        let summary: ParquetSummary
        let session: TableSession

        /// Sheet name for workbooks, nil otherwise.
        var name: String? { entry.sheet }
        var source: TableSession.Source { entry.source }
        var sqlName: String { entry.sqlName }
    }

    let url: URL
    let format: DataFormat
    let sheets: [Sheet]
    /// The sheet shown in the window (kept here so New Query can start from it).
    var currentSheet = 0

    /// Identifies this window as an owner of its catalog tables.
    private let owner = NSObject()

    var database: Database { Catalog.shared.database }
    var fileSize: Int64 { sheets.first?.summary.fileSize ?? 0 }
    var current: Sheet { sheets[min(currentSheet, sheets.count - 1)] }
    var isWorkbook: Bool { sheets.count > 1 || sheets.first?.name != nil }

    /// Main thread: registers a file that FileLoader has read.
    init(_ loaded: FileLoader.Loaded) throws {
        url = loaded.url
        format = loaded.format
        let entries = try Catalog.shared.register(loaded, owner: owner)
        sheets = try zip(entries, loaded.tables).map { entry, table in
            Sheet(entry: entry, summary: table.summary,
                  session: try TableSession(database: Catalog.shared.database, source: entry.source,
                                            columns: entry.columns, totalRows: entry.rowCount))
        }
    }

    /// Synchronous open (CLI and tests): read and register in one go.
    convenience init(url: URL) throws {
        try self.init(FileLoader(url: url).loadSync())
    }

    /// The window closed: let go of the file's tables.
    func close() {
        Catalog.shared.unregister(url, owner: owner)
    }
}
