import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Data-based Quick Look preview: returns an HTML page for the selected .parquet file.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html: String
        do {
            html = PreviewHTML.render(try ParquetProbe.probe(url: url))
        } catch {
            html = PreviewHTML.error(error.localizedDescription, fileName: url.lastPathComponent)
        }

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 720, height: 420)) { _ in
            Data(html.utf8)
        }
    }
}
