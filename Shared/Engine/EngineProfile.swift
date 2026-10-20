import Foundation

/// DuckDB settings per process type. Nothing is ever downloaded or loaded from ~/.duckdb:
/// Parquet support is built into libduckdb, and the extensions run sandboxed.
enum EngineProfile {
    /// Quick Look / thumbnail extensions: short-lived, sandboxed, must stay small.
    case previewExtension
    /// The main app.
    case app

    var settings: [(String, String)] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("duckdb").path
        var common: [(String, String)] = [
            ("autoinstall_known_extensions", "false"),
            ("autoload_known_extensions", "false"),
            ("allow_persistent_secrets", "false"),
            ("home_directory", scratch),
            ("temp_directory", scratch),
        ]
        switch self {
        case .previewExtension:
            common += [("threads", "1"), ("memory_limit", "512MB")]
        case .app:
            // DuckDB defaults to 80 % of RAM; sorting 30M rows peaks at several GB. Half is plenty
            // (bigger operations spill to the temp directory) and leaves room for everything else.
            let halfOfRAM = ProcessInfo.processInfo.physicalMemory / 2 / 1_048_576
            common += [("memory_limit", "\(halfOfRAM)MB")]
        }
        // Developer override for experiments: LAMINAT_DUCKDB_SETTINGS="name=value,name=value".
        if let extra = ProcessInfo.processInfo.environment["LAMINAT_DUCKDB_SETTINGS"] {
            for pair in extra.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { common.append((parts[0], parts[1])) }
            }
        }
        return common
    }

    func connect() throws -> Connection {
        try Connection(Database(settings: settings))
    }
}
