import AppKit

/// A query tab (File → New Query, ⌘N): SQL over every open file, in the same system tab group as the
/// files. Not saved to disk, but restored after quitting (text, cursor, added files) like other windows;
/// closing it frees its result and the files added only to it.
final class QueryDocument: NSDocument {
    private static var counter = 0

    let session: QuerySession
    private let title: String
    private var initialSQL: String
    private var runOnOpen: Bool

    init(sql: String, run: Bool, title restoredTitle: String? = nil) throws {
        session = try QuerySession()
        if let restoredTitle {
            title = restoredTitle
            // Keep numbering after restored tabs: "Query 3" restored → the next new one is "Query 4".
            if let number = Int(restoredTitle.split(separator: " ").last ?? "") { Self.counter = max(Self.counter, number) }
        } else {
            Self.counter += 1
            title = "Query \(Self.counter)"
        }
        initialSQL = sql
        runOnOpen = run
        super.init()
    }

    override var displayName: String! {
        get { title }
        set {}
    }

    var queryTitle: String { title }

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }  // nothing to save, so no "Save changes?" on close

    override func makeWindowControllers() {
        let controller = SQLViewController(session: session, initialSQL: initialSQL)
        let window = DocumentWindow.make(content: controller)
        let windowController = QueryWindowController(window: window, sql: controller)
        windowController.shouldCascadeWindows = true
        addWindowController(windowController)
        // Adding the window to a document makes NSDocumentController its restoration class, which can't
        // reopen a document with no file. Query tabs restore themselves instead.
        window.restorationClass = QueryWindowController.self
        window.isRestorable = true
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
final class QueryWindowController: NSWindowController, NSMenuItemValidation, NSToolbarDelegate, NSWindowDelegate,
                                   NSWindowRestoration {
    private let sql: SQLViewController
    private var catalogObserver: NSObjectProtocol?
    private static let stateKey = "LaminatQueryState"

    /// What a query tab brings back after the app quits.
    struct SavedState: Codable {
        var title: String
        var sql: String
        var selectionLocation: Int
        var selectionLength: Int
        var addedFiles: [String]
    }
    private static let runItem = NSToolbarItem.Identifier("run")
    private static let newQueryItem = NSToolbarItem.Identifier("newQuery")

    init(window: NSWindow, sql: SQLViewController) {
        self.sql = sql
        super.init(window: window)
        // Same toolbar layout as a file tab (control on the leading edge, New Query on the right), so the
        // window keeps its height and content doesn't jump when switching between files and queries.
        let toolbar = NSToolbar(identifier: "query")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // Query tabs aren't files, so the document system can't reopen them: restore them ourselves.
        window.identifier = NSUserInterfaceItemIdentifier("LaminatQuery")
        window.restorationClass = QueryWindowController.self
        window.isRestorable = true
        window.delegate = self
        sql.onTextChange = { [weak window] in window?.invalidateRestorableState() }
        catalogObserver = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil, queue: .main) {
            [weak window] _ in window?.invalidateRestorableState()  // files added to / removed from the query
        }
    }

    deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard let document = document as? QueryDocument else { return }
        let saved = SavedState(title: document.queryTitle, sql: sql.queryText,
                               selectionLocation: sql.selection.location, selectionLength: sql.selection.length,
                               addedFiles: document.session.addedFiles.map(\.path))
        if let data = try? JSONEncoder().encode(saved) { state.encode(data, forKey: Self.stateKey) }
    }

    /// Called by AppKit at launch for each query tab that was open when the app quit.
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard let data = state.decodeObject(of: NSData.self, forKey: stateKey) as Data?,
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else {
            completionHandler(nil, nil)
            return
        }
        do {
            let document = try QueryDocument(sql: saved.sql, run: false, title: saved.title)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? QueryWindowController else {
                completionHandler(nil, nil)
                return
            }
            controller.sql.selection = NSRange(location: saved.selectionLocation, length: saved.selectionLength)
            // Files that are gone are skipped quietly.
            for path in saved.addedFiles where FileManager.default.fileExists(atPath: path) {
                document.session.addFile(URL(fileURLWithPath: path)) { _ in }
            }
            completionHandler(controller.window, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.runItem, Self.newQueryItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.runItem, .flexibleSpace, Self.newQueryItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.runItem:
            let stack = NSStackView(views: [sql.runButton, sql.stopButton])
            stack.spacing = 6
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "Run"
            item.isNavigational = true  // leading edge, where a file tab has Data / Stats
            return item
        case Self.newQueryItem:
            return DocumentWindow.newQueryItem(itemIdentifier)
        default:
            return nil
        }
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
