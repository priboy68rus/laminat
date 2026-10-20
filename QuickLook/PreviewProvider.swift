import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Data-based Quick Look preview: returns an HTML page with the schema and the first rows.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html: String
        do {
            html = try QuickLookPreview.html(for: url).html
        } catch {
            html = QuickLookPreview.error(error.localizedDescription, fileName: url.lastPathComponent)
        }

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 600)) { _ in
            Data(html.utf8)
        }
    }
}
