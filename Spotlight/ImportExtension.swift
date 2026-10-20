import CoreSpotlight
import Foundation
import os

/// Spotlight import extension (SPEC §1.3): indexes column names and types as the file's text, so
/// searching for a column name finds the files that contain it. Reads only the footer.
class ImportExtension: CSImportExtension {
    private static let log = Logger(subsystem: "com.priboy68rus.laminat.Spotlight", category: "import")

    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        do {
            try importFile(attributes, contentURL)
        } catch {
            let readable = FileManager.default.isReadableFile(atPath: contentURL.path)
            Self.log.error("import failed for \(contentURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); readable=\(readable, privacy: .public)")
            throw error
        }
    }

    private func importFile(_ attributes: CSSearchableItemAttributeSet, _ contentURL: URL) throws {
        // Spotlight hands over a security-scoped URL; the sandbox hides the file until it is opened up.
        let scoped = contentURL.startAccessingSecurityScopedResource()
        defer { if scoped { contentURL.stopAccessingSecurityScopedResource() } }

        let connection = try EngineProfile.previewExtension.connect()
        let summary = try ParquetFile(url: contentURL, connection: connection).summary()

        let rows = summary.rowCount.formatted()
        attributes.contentDescription = "Apache Parquet · \(rows) rows · \(summary.columns.count) columns"
        // Full-text content: "name type" per column, one per line.
        attributes.textContent = summary.columns.map { "\($0.name) \($0.type)" }.joined(separator: "\n")
        attributes.keywords = summary.columns.map(\.name)
        if let createdBy = summary.createdBy, !createdBy.isEmpty {
            attributes.creator = createdBy
        }
    }
}
