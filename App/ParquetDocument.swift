import AppKit

/// Read-only document: opening a file only reads its footer; data is paged in by the grid.
final class ParquetDocument: NSDocument {
    private(set) var session: DataSession?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        session = try DataSession(url: url)
    }

    override func makeWindowControllers() {
        guard let session else { return }
        addWindowController(ViewerWindowController(session: session))
    }
}

final class ViewerWindowController: NSWindowController {
    init(session: DataSession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = GridViewController(session: session)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.minSize = NSSize(width: 480, height: 240)
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
