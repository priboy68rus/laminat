import Foundation

/// Profile of one column (SPEC §1.6). All values are display strings from DuckDB; nil = not computed
/// or not applicable to the column type.
struct ColumnStats {
    var nonNull: Int?
    var nulls: Int?
    var distinct: Int?
    var min: String?
    var max: String?
    var mean: String?
    var std: String?
    var p25: String?
    var median: String?
    var p75: String?
    var avgLength: String?
    /// True once the full pass (not just footer metadata) has filled this column.
    var isComplete = false
}

/// Histogram and most frequent values of one column, computed on demand.
struct ColumnDetails {
    struct Bin { let lower: Double; let upper: Double; let count: Int }
    enum BinKind { case value, timestamp, length }
    let bins: [Bin]
    /// What the bins measure: the value itself, a timestamp (epoch ms) or the length of a string.
    let binKind: BinKind
    /// One bin per integer value: label bins by value instead of by range.
    var perValue = false
    let top: [(value: String?, count: Int)]
    let rowCount: Int
}

/// Computes column statistics in waves:
/// 1. footer metadata (instant): null counts and min / max of flat columns — only for the whole file;
/// 2. a full pass in small batches of columns, each batch delivered as soon as it is done;
/// 3. on demand, per column: histogram and top values.
/// Work runs on its own queue and connection; a new run or `cancel()` interrupts the current one.
final class StatsCalculator {
    enum Category { case number, temporal, boolean, text, binary, nested, other }

    let url: URL
    let columns: [ParquetColumn]
    static let batchSize = 4
    static let histogramBins = 30

    private let connection: Connection
    private let queue = DispatchQueue(label: "laminat.stats", qos: .userInitiated)
    /// Details get their own connection so a click doesn't wait for the profile to finish.
    private let detailsConnection: Connection
    private let detailsQueue = DispatchQueue(label: "laminat.stats.details", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var running = false

    private var source: String { "read_parquet(\(SQL.string(url.path)))" }

    init(database: Database, url: URL, columns: [ParquetColumn]) throws {
        self.url = url
        self.columns = columns
        connection = try Connection(database)
        detailsConnection = try Connection(database)
    }

    static func category(_ column: ParquetColumn) -> Category {
        let type = column.type.uppercased()
        switch column.kind {
        case .number: return .number
        case .text: return .text
        case .binary: return .binary
        case .nested: return .nested
        case .other:
            if type == "BOOLEAN" { return .boolean }
            if type.hasPrefix("DATE") || type.hasPrefix("TIMESTAMP") || type.hasPrefix("TIME") { return .temporal }
            return .other
        }
    }

    // MARK: Profile

    /// Starts a profile of all columns. `filter` is a SQL condition (nil = whole file) and `rowCount`
    /// the number of rows it selects. `update` receives finished columns; `finish` the total time.
    func run(filter: String?, rowCount: Int,
             update: @escaping (_ stats: [Int: ColumnStats], _ completedColumns: Int) -> Void,
             finish: @escaping (Result<TimeInterval, Error>) -> Void) {
        let token = beginRun()
        queue.async { [self] in
            let start = Date()
            func deliver(_ stats: [Int: ColumnStats], _ completed: Int) {
                DispatchQueue.main.async { if self.isCurrent(token) { update(stats, completed) } }
            }

            if filter == nil, let footer = try? footerStats(rowCount: rowCount) {
                deliver(footer, 0)
            }

            var completed = 0
            for batch in stride(from: 0, to: columns.count, by: Self.batchSize).map({ Array($0..<min($0 + Self.batchSize, columns.count)) }) {
                guard isCurrent(token) else { return }
                do {
                    let stats = try batchStats(batch, filter: filter, rowCount: rowCount)
                    completed += batch.count
                    deliver(stats, completed)
                } catch {
                    endRun(token)
                    DispatchQueue.main.async { if self.isCurrent(token) { finish(.failure(error)) } }
                    return
                }
            }
            endRun(token)
            let duration = Date().timeIntervalSince(start)
            DispatchQueue.main.async { if self.isCurrent(token) { finish(.success(duration)) } }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        let wasRunning = running
        lock.unlock()
        if wasRunning { connection.interrupt() }
    }

    static func isInterrupt(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("interrupt")
    }

    private func beginRun() -> Int {
        cancel()
        lock.lock()
        defer { lock.unlock() }
        running = true
        return generation
    }

    private func endRun(_ token: Int) {
        lock.lock()
        if token == generation { running = false }
        lock.unlock()
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    /// Wave 1: null counts and min / max from the row group statistics in the footer.
    private func footerStats(rowCount: Int) throws -> [Int: ColumnStats] {
        let flat = columns.enumerated().filter { Self.category($0.element) != .nested }
        guard !flat.isEmpty else { return [:] }

        var expressions: [String] = []
        for (_, column) in flat {
            let path = SQL.string(column.name)
            // Statistics are stored as strings; cast back so "9013247" < "29999999" compares as numbers.
            expressions.append("sum(stats_null_count) FILTER (WHERE path_in_schema = \(path))::VARCHAR")
            expressions.append("min(TRY_CAST(stats_min_value AS \(column.type))) FILTER (WHERE path_in_schema = \(path))::VARCHAR")
            expressions.append("max(TRY_CAST(stats_max_value AS \(column.type))) FILTER (WHERE path_in_schema = \(path))::VARCHAR")
        }
        guard let row = try connection.query("""
            SELECT \(expressions.joined(separator: ", ")) FROM parquet_metadata(\(SQL.string(url.path)))
            """).readStrings().first else { return [:] }

        var result: [Int: ColumnStats] = [:]
        for (position, (index, _)) in flat.enumerated() {
            var stats = ColumnStats()
            stats.nulls = row[position * 3].flatMap { Int($0) }
            stats.nonNull = stats.nulls.map { rowCount - $0 }
            stats.min = row[position * 3 + 1]
            stats.max = row[position * 3 + 2]
            result[index] = stats
        }
        return result
    }

    /// Wave 2: one scan for a batch of columns. Falls back to column-by-column (and then to counts only)
    /// if an aggregate isn't supported for some type.
    private func batchStats(_ batch: [Int], filter: String?, rowCount: Int) throws -> [Int: ColumnStats] {
        do {
            return try scan(batch.map { ($0, Self.aggregates(for: columns[$0], full: true)) }, filter: filter, rowCount: rowCount)
        } catch where !Self.isInterrupt(error) && batch.count > 1 {
            var result: [Int: ColumnStats] = [:]
            for index in batch {
                result.merge(try batchStats([index], filter: filter, rowCount: rowCount)) { $1 }
            }
            return result
        } catch where !Self.isInterrupt(error) {
            return try scan([(batch[0], Self.aggregates(for: columns[batch[0]], full: false))], filter: filter, rowCount: rowCount)
        }
    }

    private enum Field { case nonNull, distinct, min, max, mean, std, quantiles, avgLength }

    private static func aggregates(for column: ParquetColumn, full: Bool) -> [(Field, String)] {
        let c = SQL.identifier(column.name)
        var list: [(Field, String)] = [(.nonNull, "count(\(c))"), (.distinct, "approx_count_distinct(\(c))")]
        guard full else { return list }
        switch category(column) {
        case .number:
            list += [(.min, "min(\(c))"), (.max, "max(\(c))"), (.mean, "avg(\(c))"), (.std, "stddev_samp(\(c))"),
                     (.quantiles, "approx_quantile(\(c), [0.25, 0.5, 0.75])")]
        case .temporal:
            list += [(.min, "min(\(c))"), (.max, "max(\(c))"), (.quantiles, "approx_quantile(\(c), [0.25, 0.5, 0.75])")]
        case .boolean:
            // Mean of a boolean = share of true values.
            list += [(.min, "min(\(c))"), (.max, "max(\(c))"), (.mean, "avg(\(c)::INTEGER)")]
        case .text:
            list += [(.min, "min(\(c))"), (.max, "max(\(c))"), (.avgLength, "avg(length(\(c)))")]
        case .binary:
            list += [(.avgLength, "avg(octet_length(\(c)))")]
        case .nested, .other:
            break
        }
        return list
    }

    private func scan(_ plan: [(Int, [(Field, String)])], filter: String?, rowCount: Int) throws -> [Int: ColumnStats] {
        let expressions = plan.flatMap { $0.1.map { "left((\($0.1))::VARCHAR, 200)" } }
        var sql = "SELECT \(expressions.joined(separator: ", ")) FROM \(source)"
        if let filter { sql += " WHERE \(filter)" }
        guard let row = try connection.query(sql).readStrings().first else { return [:] }

        var result: [Int: ColumnStats] = [:]
        var position = 0
        for (index, fields) in plan {
            var stats = ColumnStats(isComplete: true)
            for (field, _) in fields {
                let value = row[position]
                position += 1
                switch field {
                case .nonNull:
                    stats.nonNull = value.flatMap { Int($0) }
                    stats.nulls = stats.nonNull.map { rowCount - $0 }
                case .distinct: stats.distinct = value.flatMap { Int($0) }
                case .min: stats.min = value
                case .max: stats.max = value
                case .mean: stats.mean = value
                case .std: stats.std = value
                case .avgLength: stats.avgLength = value
                case .quantiles:
                    let parts = value.map(Self.parseList) ?? []
                    if parts.count == 3 { (stats.p25, stats.median, stats.p75) = (parts[0], parts[1], parts[2]) }
                }
            }
            result[index] = stats
        }
        return result
    }

    /// "[1.5, 2, 3]" → ["1.5", "2", "3"]; "['2024-01-01', …]" → ["2024-01-01", …]
    private static func parseList(_ s: String) -> [String] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
    }

    // MARK: Details

    /// Wave 3: histogram (numbers and dates) and top 10 values of one column.
    func details(column index: Int, filter: String?, rowCount: Int,
                 completion: @escaping (Result<ColumnDetails, Error>) -> Void) {
        let column = columns[index]
        detailsQueue.async { [self] in
            let result = Result { try computeDetails(column, filter: filter, rowCount: rowCount) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func computeDetails(_ column: ParquetColumn, filter: String?, rowCount: Int) throws -> ColumnDetails {
        let c = SQL.identifier(column.name)
        let category = Self.category(column)
        let whereFilter = filter.map { " WHERE \($0)" } ?? ""
        let andFilter = filter.map { " AND (\($0))" } ?? ""

        var bins: [ColumnDetails.Bin] = []
        var perValueBins = false
        let type = column.type.uppercased()
        let isTimeOfDay = type.hasPrefix("TIME") && !type.hasPrefix("TIMESTAMP")
        let numeric: String? = switch category {
        case .number: "\(c)::DOUBLE"
        case .temporal where !isTimeOfDay: "epoch_ms(\(c)::TIMESTAMP)::DOUBLE"
        case .text: "length(\(c))::DOUBLE"
        default: nil
        }
        let binKind: ColumnDetails.BinKind = switch category {
        case .temporal: .timestamp
        case .text: .length
        default: .value
        }
        if let numeric,
           let range = try detailsConnection.query("SELECT min(\(numeric))::VARCHAR, max(\(numeric))::VARCHAR FROM \(source)\(whereFilter)")
            .readStrings().first,
           let low = range[0].flatMap(Double.init), let high = range[1].flatMap(Double.init), low.isFinite, high.isFinite {
            // Integers over a small range (string lengths, small codes) get one bin per value.
            let integral = binKind == .length || ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT",
                                                  "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT"].contains(type)
            let perValue = integral && high - low < Double(Self.histogramBins)
            let count = perValue ? Int(high - low) + 1 : (high > low ? Self.histogramBins : 1)
            let width = perValue ? 1 : (high > low ? (high - low) / Double(count) : 1)
            perValueBins = perValue
            let rows = try detailsConnection.query("""
                SELECT least(floor((\(numeric) - \(low)) / \(width))::BIGINT, \(count - 1))::VARCHAR AS b, count(*)::VARCHAR
                FROM \(source) WHERE \(c) IS NOT NULL\(andFilter) GROUP BY 1
                """).readStrings()
            var counts = [Int](repeating: 0, count: count)
            for row in rows {
                if let b = row[0].flatMap({ Int($0) }), counts.indices.contains(b) { counts[b] = row[1].flatMap { Int($0) } ?? 0 }
            }
            bins = counts.enumerated().map { i, n in
                ColumnDetails.Bin(lower: low + Double(i) * width, upper: low + Double(i + 1) * width, count: n)
            }
        }

        var top: [(String?, Int)] = []
        if category != .binary {
            let text = category == .nested ? "to_json(\(c))::VARCHAR" : "\(c)::VARCHAR"
            top = try detailsConnection.query("""
                SELECT left(\(text), 200), count(*)::VARCHAR AS n FROM \(source)\(whereFilter)
                GROUP BY 1 ORDER BY count(*) DESC LIMIT 10
                """).readStrings().map { ($0[0], $0[1].flatMap { Int($0) } ?? 0) }
        }

        return ColumnDetails(bins: bins, binKind: binKind, perValue: perValueBins, top: top, rowCount: rowCount)
    }
}
