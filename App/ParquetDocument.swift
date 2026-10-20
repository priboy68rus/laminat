import AppKit

/// Read-only document: opening a file only reads its footer; data is paged in by the grid.
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
}

final class ViewerWindowController: NSWindowController, NSToolbarDelegate {
    private let modeControl = NSSegmentedControl(labels: ["Data", "SQL", "Stats"], trackingMode: .selectOne, target: nil, action: nil)
    private let documentController: DocumentViewController
    private static let modeItem = NSToolbarItem.Identifier("mode")

    init(workspace: Workspace) {
        documentController = DocumentViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = documentController
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.minSize = NSSize(width: 480, height: 300)
        window.toolbarStyle = .unified
        // System window tabs: new files open as tabs of the frontmost window; a tab can be dragged out
        // into its own window (and windows merged back) with the standard Window menu commands.
        window.tabbingIdentifier = "LaminatDocument"
        window.tabbingMode = .preferred
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setToolTip("Data (⌘1)", forSegment: 0)
        modeControl.setToolTip("SQL (⌘2)", forSegment: 1)
        modeControl.setToolTip("Statistics (⌘3)", forSegment: 2)
        documentController.onModeChange = { [weak self] mode in self?.modeControl.selectedSegment = mode.rawValue }

        let toolbar = NSToolbar(identifier: "viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
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
        [.flexibleSpace, Self.modeItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.modeItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = modeControl
        item.label = "Mode"
        return item
    }
}

/// Window content: switches between the data grid and the SQL editor.
final class DocumentViewController: NSViewController {
    enum Mode: Int { case data, sql, stats }

    let workspace: Workspace
    var onModeChange: ((Mode) -> Void)?
    var mode: Mode = .data { didSet { if mode != oldValue { showMode() } } }

    private lazy var dataGrid = GridViewController(
        session: workspace.fileSession,
        details: ByteCountFormatter.string(fromByteCount: workspace.summary.fileSize, countStyle: .file))
    private lazy var sqlController = SQLViewController(workspace: workspace)
    private lazy var statsController: StatsViewController = {
        let controller = StatsViewController(workspace: workspace)
        controller.dataView = { [unowned self] in (dataGrid.appliedSpec, dataGrid.appliedRowCount) }
        controller.onOpenSQL = { [unowned self] sql in
            mode = .sql
            sqlController.setQuery(sql, run: true)
        }
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
        let next: NSViewController = switch mode {
        case .data: dataGrid
        case .sql: sqlController
        case .stats: statsController
        }
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

    @objc func showData(_ sender: Any?) { mode = .data }
    @objc func showSQL(_ sender: Any?) { mode = .sql }
    @objc func showStats(_ sender: Any?) { mode = .stats }

    /// Query menu commands work from either mode: they switch to SQL first.
    @objc func runQuery(_ sender: Any?) {
        mode = .sql
        sqlController.runQuery(sender)
    }

    @objc func stopQuery(_ sender: Any?) { sqlController.stopQuery(sender) }

    @objc func showTemplates(_ sender: Any?) {
        mode = .sql
        sqlController.showTemplates(sender)
    }
}

extension DocumentViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showData(_:)): item.state = mode == .data ? .on : .off
        case #selector(showSQL(_:)): item.state = mode == .sql ? .on : .off
        case #selector(showStats(_:)): item.state = mode == .stats ? .on : .off
        case #selector(runQuery(_:)), #selector(stopQuery(_:)): return sqlController.validateMenuItem(item)
        default: break
        }
        return true
    }
}
