import AppKit

/// Read-only document: opening a file only reads its footer; data is paged in by the grid. The file
/// is registered in the app-wide catalog, so every query tab can use it while it is open.
final class ParquetDocument: NSDocument {
    private(set) var workspace: Workspace?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        workspace = try Workspace(url: url)
    }

    override func makeWindowControllers() {
        guard let workspace else { return }
        addWindowController(ViewerWindowController(workspace: workspace))
    }

    override func close() {
        workspace?.close()
        super.close()
    }
}

/// Shared window setup for file and query tabs: same size and one system tab group.
enum DocumentWindow {
    static func make(content: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.minSize = NSSize(width: 480, height: 300)
        window.toolbarStyle = .unified
        // System window tabs: files and queries open as tabs of the frontmost window; a tab can be
        // dragged out into its own window (and windows merged back) with the standard Window commands.
        window.tabbingIdentifier = "LaminatDocument"
        window.tabbingMode = .preferred
        window.center()
        return window
    }
}

final class ViewerWindowController: NSWindowController, NSToolbarDelegate {
    private let modeControl = NSSegmentedControl(labels: ["Data", "Stats"], trackingMode: .selectOne, target: nil, action: nil)
    private let documentController: DocumentViewController
    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let newQueryItem = NSToolbarItem.Identifier("newQuery")

    init(workspace: Workspace) {
        documentController = DocumentViewController(workspace: workspace)
        super.init(window: DocumentWindow.make(content: documentController))
        shouldCascadeWindows = true

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setToolTip("Data (⌘1)", forSegment: 0)
        modeControl.setToolTip("Statistics (⌘2)", forSegment: 1)
        documentController.onModeChange = { [weak self] mode in self?.modeControl.selectedSegment = mode.rawValue }

        let toolbar = NSToolbar(identifier: "viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The "+" button in the tab bar: open another file as a new tab.
    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        documentController.mode = DocumentViewController.Mode(rawValue: sender.selectedSegment) ?? .data
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, Self.newQueryItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.modeItem, .flexibleSpace, Self.newQueryItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.modeItem:
            item.view = modeControl
            item.label = "Mode"
            // Leading edge, before the window title — where Finder puts back / forward.
            item.isNavigational = true
        case Self.newQueryItem:
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Query")
            item.label = "New Query"
            item.toolTip = "New Query (⌘N) — SQL over all open files"
            item.action = #selector(AppDelegate.newQuery(_:))
        default:
            return nil
        }
        return item
    }
}

/// File window content: the data grid or the statistics.
final class DocumentViewController: NSViewController {
    enum Mode: Int { case data, stats }

    let workspace: Workspace
    var onModeChange: ((Mode) -> Void)?
    var mode: Mode = .data { didSet { if mode != oldValue { showMode() } } }

    private lazy var dataGrid: GridViewController = {
        let grid = GridViewController(
            session: workspace.fileSession,
            details: ByteCountFormatter.string(fromByteCount: workspace.summary.fileSize, countStyle: .file))
        grid.exportName = workspace.tableName
        return grid
    }()
    private lazy var statsController: StatsViewController = {
        let controller = StatsViewController(workspace: workspace)
        controller.dataView = { [unowned self] in (dataGrid.appliedSpec, dataGrid.appliedRowCount) }
        controller.onOpenSQL = { sql in QueryDocument.open(sql: sql, run: true) }
        dataGrid.onViewChange = { [weak controller] in controller?.dataViewChanged() }
        return controller
    }()

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        showMode()
    }

    private func showMode() {
        let next: NSViewController = mode == .data ? dataGrid : statsController
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        if mode == .data { view.window?.makeFirstResponder(next.view) }
        onModeChange?(mode)
    }

    /// File → Export To when no grid is first responder: export the data view.
    @objc func exportData(_ sender: Any?) {
        guard mode == .data else { NSSound.beep(); return }
        dataGrid.exportData(sender)
    }

    @objc func showData(_ sender: Any?) { mode = .data }
    @objc func showStats(_ sender: Any?) { mode = .stats }
}

extension DocumentViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showData(_:)): item.state = mode == .data ? .on : .off
        case #selector(showStats(_:)): item.state = mode == .stats ? .on : .off
        case #selector(exportData(_:)): return mode == .data
        default: break
        }
        return true
    }
}
