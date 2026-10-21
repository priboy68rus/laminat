import AppKit

/// A read-only data file: Parquet, CSV, JSON or Excel. The window opens at once; the file is loaded in
/// the background (Parquet: footer only; other formats: into a DuckDB table) and registered in the
/// app-wide catalog, so every query tab can use it while it is open.
final class ParquetDocument: NSDocument {
    private(set) var workspace: Workspace?
    private var loader: FileLoader?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        loader = try FileLoader(url: url)  // checks the format; reading happens in the window
    }

    override func makeWindowControllers() {
        guard let loader else { return }
        let controller = ViewerWindowController(fileName: loader.url.lastPathComponent, format: loader.format)
        addWindowController(controller)
        controller.onCancel = { [weak self] in
            self?.loader?.cancel()
            self?.close()
        }
        loader.load { [weak self, weak controller] result in
            guard let self, let controller else { return }
            self.loader = nil
            switch result {
            case .success(let loaded):
                do {
                    let workspace = try Workspace(loaded)
                    self.workspace = workspace
                    controller.show(workspace)
                } catch {
                    fail(error)
                }
            case .failure(let error):
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        if !error.localizedDescription.localizedCaseInsensitiveContains("interrupt") {
            let alert = NSAlert()
            alert.messageText = "Can't open \(fileURL?.lastPathComponent ?? "the file")"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        close()
    }

    override func close() {
        workspace?.close()
        workspace = nil
        super.close()
    }
}

/// Shown while a file loads: the progress overlay with Cancel.
private final class LoadingViewController: NSViewController {
    let message: String
    var onCancel: (() -> Void)?
    private let overlay = ProgressOverlay(frame: .zero)

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        overlay.install(in: view)
        overlay.onCancel = { [weak self] in self?.onCancel?() }
        overlay.start(message)
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
    private var documentController: DocumentViewController?
    private let loading: LoadingViewController
    var onCancel: (() -> Void)? { didSet { loading.onCancel = onCancel } }
    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let newQueryItem = NSToolbarItem.Identifier("newQuery")

    init(fileName: String, format: DataFormat) {
        loading = LoadingViewController(message: "Loading \(format.name)…")
        super.init(window: DocumentWindow.make(content: loading))
        shouldCascadeWindows = true

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setToolTip("Data (⌘1)", forSegment: 0)
        modeControl.setToolTip("Statistics (⌘2)", forSegment: 1)
        modeControl.isEnabled = false

        let toolbar = NSToolbar(identifier: "viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The "+" button in the tab bar (or ⌘T): open a file as a new tab. Queries: ⌘N or New Query.
    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    /// The file finished loading: replace the progress view with the grid.
    func show(_ workspace: Workspace) {
        let controller = DocumentViewController(workspace: workspace)
        controller.onModeChange = { [weak self] mode in self?.modeControl.selectedSegment = mode.rawValue }
        documentController = controller
        let frame = window?.frame
        window?.contentViewController = controller
        if let frame { window?.setFrame(frame, display: true) }  // keep the size the user saw
        modeControl.isEnabled = true
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        documentController?.mode = DocumentViewController.Mode(rawValue: sender.selectedSegment) ?? .data
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
            // Icon and title in the button itself: an icon-only toolbar hides item labels.
            let button = NSButton(title: "New Query",
                                  image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)!,
                                  target: nil, action: #selector(AppDelegate.newQuery(_:)))
            button.imagePosition = .imageLeading
            button.bezelStyle = .toolbar
            button.toolTip = "New Query (⌘N) — SQL over all open files"
            item.view = button
            item.label = "New Query"
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
