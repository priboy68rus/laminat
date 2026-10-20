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

struct ContentView: View {
    @State private var probe: ParquetProbe?
    @State private var errorText: String?
    @State private var importing = false

    private var parquetType: UTType {
        UTType("org.apache.parquet") ?? UTType(filenameExtension: "parquet") ?? .data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Laminat").font(.largeTitle.bold())
            Text("Prototype. Select a .parquet file in Finder and press Space to test the Quick Look extension.")
                .foregroundStyle(.secondary)

            Button("Open .parquet…") { importing = true }

            if let p = probe {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("File").foregroundStyle(.secondary); Text(p.fileName) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text("\(p.fileSize) bytes") }
                    GridRow { Text("Magic").foregroundStyle(.secondary); Text(p.isValid ? "PAR1 ✅" : "invalid ⚠️") }
                    GridRow { Text("Footer").foregroundStyle(.secondary); Text(p.footerLength.map { "\($0) bytes" } ?? "—") }
                }
            }
            if let e = errorText { Text(e).foregroundStyle(.red) }
            Spacer()
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [parquetType]) { result in
            switch result {
            case .success(let url):
                do { probe = try ParquetProbe.probe(url: url); errorText = nil }
                catch { errorText = error.localizedDescription; probe = nil }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}
