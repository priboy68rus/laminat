import SwiftUI
import UniformTypeIdentifiers

@main
struct LaminatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 320)
        }
    }
}

/// Placeholder until the viewer window lands: opens a file and shows its footer metadata.
struct ContentView: View {
    @State private var summary: ParquetSummary?
    @State private var errorText: String?
    @State private var importing = false

    private var parquetType: UTType {
        UTType("org.apache.parquet") ?? UTType(filenameExtension: "parquet") ?? .data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Laminat").font(.largeTitle.bold())
            Text("Prototype. Select a .parquet file in Finder and press Space to see the Quick Look preview.")
                .foregroundStyle(.secondary)

            Button("Open .parquet…") { importing = true }

            if let s = summary {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("File").foregroundStyle(.secondary); Text(s.url.lastPathComponent) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: s.fileSize, countStyle: .file)) }
                    GridRow { Text("Rows").foregroundStyle(.secondary); Text("\(s.rowCount)") }
                    GridRow { Text("Columns").foregroundStyle(.secondary); Text("\(s.columns.count)") }
                    GridRow { Text("Row groups").foregroundStyle(.secondary); Text("\(s.rowGroupCount)") }
                    GridRow { Text("Created by").foregroundStyle(.secondary); Text(s.createdBy ?? "—") }
                }
            }
            if let e = errorText { Text(e).foregroundStyle(.red) }
            Spacer()
            Text("DuckDB \(Database.libraryVersion)").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [parquetType]) { result in
            switch result {
            case .success(let url):
                do {
                    summary = try ParquetFile(url: url, connection: EngineProfile.app.connect()).summary()
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                    summary = nil
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}
