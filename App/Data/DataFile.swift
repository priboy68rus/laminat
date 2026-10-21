import Foundation

/// File formats the viewer opens. Parquet is read in place (random access by row number); the others
/// are loaded into a DuckDB table once, since reaching row N of a CSV / JSON / Excel file means reading
/// everything before it.
enum DataFormat {
    case parquet, csv, json, xlsx

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "parquet", "parq": self = .parquet
        case "csv", "tsv", "tab", "txt": self = .csv
        case "json", "jsonl", "ndjson": self = .json
        case "xlsx": self = .xlsx
        default: return nil
        }
    }

    static let fileExtensions = ["parquet", "csv", "tsv", "json", "jsonl", "ndjson", "xlsx"]

    var name: String {
        switch self {
        case .parquet: "Parquet"
        case .csv: "CSV"
        case .json: "JSON"
        case .xlsx: "Excel"
        }
    }

    /// DuckDB table function reading the whole file (schema and types auto-detected).
    func reader(_ url: URL) -> String {
        let path = SQL.string(url.path)
        return switch self {
        case .parquet: "read_parquet(\(path))"
        case .csv: "read_csv(\(path))"
        case .json: "read_json(\(path))"
        case .xlsx: "read_xlsx(\(path))"  // first sheet, header row detected
        }
    }
}

/// Official DuckDB extensions bundled in the app (Contents/Resources/extensions/<arch>/), loaded on
/// demand. They are signed by DuckDB, so they load without network access or unsigned-extension flags.
enum BundledExtensions {
    private static let lock = NSLock()
    private static var loaded: Set<String> = []

    static func load(_ name: String, on connection: Connection) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded.contains(name) else { return }
        #if arch(arm64)
        let arch = "osx_arm64"
        #else
        let arch = "osx_amd64"
        #endif
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("extensions/\(arch)/\(name).duckdb_extension")
        // Developer builds of the CLI run outside the app bundle: use the fetched copy.
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Vendor/duckdb/extensions/\(arch)/\(name).duckdb_extension").standardizedFileURL
        guard let url = [bundled, vendored].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw EngineError(message: "The \(name) extension is missing from the app")
        }
        try connection.execute("LOAD \(SQL.string(url.path))")
        loaded.insert(name)  // extensions load into the database, so once is enough
    }
}

/// Loads any supported file into the app-wide database: Parquet as a view over the file, other formats
/// into a table. Runs off the main thread; `cancel()` interrupts a long import.
final class FileLoader {
    struct Loaded {
        let url: URL
        let format: DataFormat
        let summary: ParquetSummary
        /// What tables and the grid read: `read_parquet(…)` for Parquet, the imported table otherwise.
        let source: TableSession.Source
        /// SQL relation behind the catalog views.
        let relation: String
        /// Name of the imported table to drop when the file is closed (nil for Parquet).
        let importedTable: String?
    }

    let url: URL
    let format: DataFormat
    private let connection: Connection
    private static let queue = DispatchQueue(label: "laminat.load", qos: .userInitiated, attributes: .concurrent)

    init(url: URL) throws {
        guard let format = DataFormat(url: url) else {
            throw EngineError(message: "\(url.lastPathComponent): unsupported file type")
        }
        self.url = url
        self.format = format
        connection = try Connection(Catalog.shared.database)
    }

    func cancel() { connection.interrupt() }

    func load(completion: @escaping (Result<Loaded, Error>) -> Void) {
        Self.queue.async { [self] in
            let result = Result { try loadSync() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func loadSync() throws -> Loaded {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if format == .parquet {
            let summary = try ParquetFile(url: url, connection: connection).summary()
            return Loaded(url: url, format: format, summary: summary, source: .parquet(url),
                          relation: format.reader(url), importedTable: nil)
        }

        if format == .xlsx { try BundledExtensions.load("excel", on: connection) }
        let table = "__laminat_file_\(UUID().uuidString.prefix(8))"
        do {
            try connection.execute("CREATE TABLE \(SQL.identifier(table)) AS SELECT * FROM \(format.reader(url))")
        } catch {
            try? connection.execute("DROP TABLE IF EXISTS \(SQL.identifier(table))")
            throw error
        }
        let count = try connection.query("SELECT count(*)::VARCHAR FROM \(SQL.identifier(table))")
            .readStrings().first?[0].flatMap { Int64($0) } ?? 0
        let columns = try connection.query("""
            SELECT column_name::VARCHAR, column_type::VARCHAR FROM (DESCRIBE \(SQL.identifier(table)))
            """).readStrings().map { ParquetColumn(name: $0[0] ?? "", type: $0[1] ?? "") }
        let summary = ParquetSummary(url: url, fileSize: fileSize, rowCount: count, rowGroupCount: 0,
                                     createdBy: nil, columns: columns)
        return Loaded(url: url, format: format, summary: summary, source: .table(table),
                      relation: SQL.identifier(table), importedTable: table)
    }
}
