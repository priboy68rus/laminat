import AppKit

/// A query tab (File → New Query, ⌘N): SQL over every open file, in the same system tab group as the
/// files. Restored after quitting (text, cursor, added files) like other windows; closing it frees its
/// result and the files added only to it.
///
/// A query can be saved as a .sql file (⌘S / ⇧⌘S), and .sql files open as query tabs. Only a saved query
/// counts as edited ("Save changes?" on close); a new one is a scratchpad and closes without asking.
final class QueryDocument: NSDocument {
    static let sqlType = "org.iso.sql"
    private static var counter = 0

    let session: QuerySession
    private let title: String
    private var initialSQL: String
    private var runOnOpen: Bool
    private weak var editor: SQLViewController?
    /// The text as last read from or written to the file.
    private var savedText: String?

    init(sql: String, run: Bool, title restoredTitle: String? = nil, numbered: Bool = true) throws {
        session = try QuerySession()
        if let restoredTitle {
            title = restoredTitle
            // Keep numbering after restored tabs: "Query 3" restored → the next new one is "Query 4".
            if let number = Int(restoredTitle.split(separator: " ").last ?? "") { Self.counter = max(Self.counter, number) }
        } else if numbered {
            Self.counter += 1
            title = "Query \(Self.counter)"
        } else {
            title = "Query"
        }
        initialSQL = sql
        runOnOpen = run
        super.init()
    }

    /// Used by the document system to open a .sql file (followed by `read(from:ofType:)`).
    override convenience init() {
        try! self.init(sql: "", run: false, numbered: false)
    }

    override var displayName: String! {
        // The file's name as Finder shows it (with or without the extension, per the Finder setting).
        get { fileURL.map { FileManager.default.displayName(atPath: $0.path) } ?? title }
        set {}
    }

    var queryTitle: String { title }
    var text: String { editor?.queryText ?? initialSQL }

    override class var autosavesInPlace: Bool { false }

    override var isDocumentEdited: Bool { fileURL != nil && text != savedText }

    /// The editor changed: refresh the edited dot in the close button.
    func textDidChange() {
        let edited = isDocumentEdited
        for controller in windowControllers where controller.window?.isDocumentEdited != edited {
            controller.setDocumentEdited(edited)
        }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        initialSQL = text
        savedText = text
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        let current = text
        try Data(current.utf8).write(to: url, options: .atomic)
        savedText = current
    }

    /// Restoring a saved query: tie it to its file again; `text` may hold changes that weren't saved.
    func reattach(to url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        savedText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        fileURL = url
        fileType = Self.sqlType
        fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        textDidChange()
    }

    override func makeWindowControllers() {
        let controller = SQLViewController(session: session, initialSQL: initialSQL)
        editor = controller
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
        /// The .sql file of a saved query.
        var file: String?
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
        sql.onTextChange = { [weak self, weak window] in
            window?.invalidateRestorableState()
            (self?.document as? QueryDocument)?.textDidChange()
        }
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
                               addedFiles: document.session.addedFiles.map(\.path), file: document.fileURL?.path)
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
            // A saved query whose file is gone comes back as a new one.
            if let file = saved.file, FileManager.default.fileExists(atPath: file) {
                document.reattach(to: URL(fileURLWithPath: file))
            }
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
