import Foundation

// Developer tool: renders and times the Quick Look preview, and runs SQL (e.g. to generate test files).
//
//   laminat-cli preview <file.parquet> [--html out.html] [--runs N]
//   laminat-cli exec "<sql>"

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

default:
    fail("unknown command \(command)")
}
