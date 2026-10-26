import AppKit

/// A query tab (File → New Query, ⌘N): SQL over every open file, in the same system tab group as the
/// files. Not saved; closing it frees its result and the files added only to it.
final class QueryDocument: NSDocument {
    private static var counter = 0

    let session: QuerySession
    private let title: String
    private var initialSQL: String
    private var runOnOpen: Bool

    init(sql: String, run: Bool) throws {
        session = try QuerySession()
        Self.counter += 1
        title = "Query \(Self.counter)"
        initialSQL = sql
        runOnOpen = run
        super.init()
    }

    override var displayName: String! {
        get { title }
        set {}
    }

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }  // nothing to save, so no "Save changes?" on close

    override func makeWindowControllers() {
        let controller = SQLViewController(session: session, initialSQL: initialSQL)
        let window = DocumentWindow.make(content: controller)
        let windowController = QueryWindowController(window: window, sql: controller)
        windowController.shouldCascadeWindows = true
        addWindowController(windowController)
        if runOnOpen { controller.runQuery(nil) }
    }

    override func close() {
        session.close()
        super.close()
    }

    /// Opens a query tab. Without SQL it starts from the first-rows template for the file in front.
    @discardableResult
    static func open(sql: String? = nil, run: Bool = false) -> QueryDocument? {
        let text = sql ?? defaultSQL()
        do {
            // The window in front, before ours exists: the query joins its tab group.
            let front = NSApp.mainWindow ?? NSApp.keyWindow
            let document = try QueryDocument(sql: text, run: run)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            if let window = document.windowControllers.first?.window, let front,
               front.tabbingIdentifier == window.tabbingIdentifier, front.isVisible {
                front.addTabbedWindow(window, ordered: .above)
            }
            document.showWindows()
            return document
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    /// `select * from <table> limit 100` for the file whose tab is in front (or any open file).
    private static func defaultSQL() -> String {
        let front = (NSDocumentController.shared.currentDocument as? ParquetDocument)?.workspace?.current.sqlName
        guard let name = front ?? Catalog.shared.tables.first?.sqlName else {
            return "-- Open files or drop them on the Tables list, then query them by name.\n"
        }
        return SQLTemplate.all[0].sql.replacingOccurrences(of: "{t}", with: name)
    }
}

/// Keeps the Query and File → Export To commands working when nothing in the tab has focus: the window
/// controller is in the responder chain even when the editor isn't.
final class QueryWindowController: NSWindowController, NSMenuItemValidation {
    private let sql: SQLViewController

    init(window: NSWindow, sql: SQLViewController) {
        self.sql = sql
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The "+" button in the tab bar (or ⌘T): open a file as a new tab.
    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc func runQuery(_ sender: Any?) { sql.runQuery(sender) }
    @objc func stopQuery(_ sender: Any?) { sql.stopQuery(sender) }
    @objc func showTemplates(_ sender: Any?) { sql.showTemplates(sender) }
    @objc func exportData(_ sender: Any?) { sql.exportData(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { sql.validateMenuItem(item) }
}
