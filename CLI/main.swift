import Foundation

// Developer tool: renders and times the Quick Look preview, and runs SQL (e.g. to generate test files).
//
//   laminat-cli preview <file.parquet> [--html out.html] [--runs N]
//   laminat-cli exec "<sql>"
//   laminat-cli bench <file.parquet> [visible-columns]   — times grid paging (same code as the app)
//   laminat-cli join <file.parquet> <other.parquet> "<sql>" — adds a second table like the SQL sidebar does

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func ms(_ t: TimeInterval) -> String { String(format: "%7.1f ms", t * 1000) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: laminat-cli preview <file> [--html out.html] [--runs N] | exec \"<sql>\"")
}

switch command {
case "preview":
    guard args.count >= 2 else { fail("usage: laminat-cli preview <file> [--html out.html] [--runs N]") }
    let url = URL(fileURLWithPath: args[1])
    let htmlOut = args.firstIndex(of: "--html").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    let runs = args.firstIndex(of: "--runs").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 1

    do {
        print("DuckDB \(Database.libraryVersion)")
        for run in 1...runs {
            let (html, t) = try QuickLookPreview.html(for: url)
            print("run \(run): open \(ms(t.open))  summary \(ms(t.summary))  rows \(ms(t.rows))  render \(ms(t.render))  total \(ms(t.total))  html \(html.utf8.count / 1024) KB")
            if run == runs, let htmlOut {
                try html.write(toFile: htmlOut, atomically: true, encoding: .utf8)
            }
        }
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "exec":
    guard args.count >= 2 else { fail("usage: laminat-cli exec \"<sql>\"") }
    do {
        let start = Date()
        try EngineProfile.app.connect().execute(args[1])
        print("ok \(ms(Date().timeIntervalSince(start)))")
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "bench":
    guard args.count >= 2 else { fail("usage: laminat-cli bench <file> [visible-columns]") }
    do {
        let url = URL(fileURLWithPath: args[1])
        let database = try Database(settings: EngineProfile.app.settings)
        let summary = try ParquetFile(url: url, connection: try Connection(database)).summary()
        let session = try TableSession(database: database, source: .parquet(url), columns: summary.columns,
                                       totalRows: Int(summary.rowCount))
        let visible = Array(0..<min(args.count > 2 ? Int(args[2]) ?? 12 : 12, summary.columns.count))
        let all = Array(summary.columns.indices)

        func time(_ label: String, _ body: () throws -> Void) rethrows {
            let start = Date()
            try body()
            print(String(format: "%-46@ %8.1f ms", label as NSString, Date().timeIntervalSince(start) * 1000))
        }
        func page(_ view: TableSession.View, _ index: Int, _ columns: [Int], _ label: String) throws {
            try time(label) { _ = try session.loadPageSync(index, columns: columns, of: view) }
        }

        let identity = session.identityView
        let middle = identity.rowCount / identity.pageSize / 2
        try page(identity, middle, all, "plain page, all \(all.count) columns")
        try page(identity, middle + 3, visible, "plain page, \(visible.count) visible columns")

        // Sort by the last visible column (makeView completes on the main queue).
        var sorted: TableSession.View?
        var buildError: Error?
        let start = Date()
        session.makeView(ViewSpec(sort: .init(column: visible.last ?? 0, ascending: true))) { result in
            switch result {
            case .success(let view): sorted = view
            case .failure(let error): buildError = error
            }
        }
        while sorted == nil && buildError == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if let buildError { throw buildError }
        print(String(format: "%-46@ %8.1f ms", "build sort index" as NSString, Date().timeIntervalSince(start) * 1000))

        let view = sorted!
        let sortedMiddle = view.rowCount / view.pageSize / 2
        try page(view, sortedMiddle, all, "sorted page (\(view.pageSize) rows), all columns")
        try page(view, sortedMiddle + 3, visible, "sorted page (\(view.pageSize) rows), visible columns")

        // Resident memory once the work is done (the peak is reported by /usr/bin/time -l).
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        print(String(format: "%-46@ %8.0f MB", "resident memory after" as NSString, Double(info.resident_size) / 1_048_576))
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "join":
    guard args.count >= 4 else { fail("usage: laminat-cli join <file> <other> \"<sql>\"") }
    do {
        // Same objects as the app: the first file as an open window, the second added to a query tab.
        let workspace = try Workspace(url: URL(fileURLWithPath: args[1]))
        let query = try QuerySession()
        let added = try query.addFileSync(URL(fileURLWithPath: args[2]))
        let again = try query.addFileSync(URL(fileURLWithPath: args[2]))
        print("tables:", Catalog.shared.tables.map { "\($0.name) (\($0.alias))" }.joined(separator: ", "))
        print("re-adding returns the same entries:", again.map(\.alias) == added.map(\.alias),
              "| window tables:", workspace.sheets.map(\.sqlName).joined(separator: ", "))
        var done = false
        query.run(args[3]) { result in
            switch result {
            case .success(let r):
                print("rows: \(r.rowCount), columns: \(r.session.columns.map(\.name).joined(separator: ", "))")
                if let page = try? r.session.loadPageSync(0, columns: Array(r.session.columns.indices), of: r.session.identityView) {
                    for row in 0..<min(3, page.values.first?.count ?? 0) {
                        print("  ", r.session.columns.indices.map { page[$0]?[row] ?? "NULL" }.joined(separator: " | "))
                    }
                }
            case .failure(let error): print("error:", error.localizedDescription)
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        query.close()
        workspace.close()
        print("after closing both:", Catalog.shared.tables.count, "tables")
    } catch {
        fail("error: \(error.localizedDescription)")
    }

default:
    fail("unknown command \(command)")
}
