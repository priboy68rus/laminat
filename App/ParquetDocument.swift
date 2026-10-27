import AppKit

/// A read-only data file: Parquet, CSV, JSON or Excel. The window opens at once; the file is loaded in
/// the background (Parquet: footer only; other formats: into a DuckDB table) and registered in the
/// app-wide catalog, so every query tab can use it while it is open.
final class ParquetDocument: NSDocument {
    private(set) var workspace: Workspace?
    private var loader: FileLoader?

    override class var autosavesInPlace: Bool { false }

    /// A viewer: File → Save / Save As don't apply to data files.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(saveTo(_:)), #selector(revertToSaved(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

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

/// Shared window setup for file and query tabs: same size, the same toolbar layout (a control on the
/// leading edge, New Query on the right, so switching tabs doesn't shift the content) and one tab group.
enum DocumentWindow {
    /// The New Query toolbar button. Icon and title live in the button itself: an icon-only toolbar
    /// hides item labels.
    static func newQueryItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let button = NSButton(title: "New Query",
                              image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)!,
                              target: nil, action: #selector(AppDelegate.newQuery(_:)))
        button.imagePosition = .imageLeading
        button.bezelStyle = .toolbar
        button.toolTip = "New Query (⌘N) — SQL over all open files"
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = "New Query"
        return item
    }

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

final class ViewerWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let modeControl = NSSegmentedControl(labels: ["Data", "Stats"], trackingMode: .selectOne, target: nil, action: nil)
    private var documentController: DocumentViewController?
    private let loading: LoadingViewController
    /// View state decoded at launch, applied once the file has loaded.
    private var pendingState: DocumentViewController.SavedState?
    private static let stateKey = "LaminatFileState"
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
        // The document system restores the window and its file after quitting; the delegate adds the
        // view state (mode, sheet, sort, filters, scroll).
        window?.delegate = self

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
        if let pendingState {
            self.pendingState = nil
            controller.restore(pendingState)
        }
        controller.onStateChange = { [weak self] in self?.window?.invalidateRestorableState() }
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard let saved = documentController?.savedState ?? pendingState,
              let data = try? JSONEncoder().encode(saved) else { return }
        state.encode(data, forKey: Self.stateKey)
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        guard let data = state.decodeObject(of: NSData.self, forKey: Self.stateKey) as Data?,
              let saved = try? JSONDecoder().decode(DocumentViewController.SavedState.self, from: data) else { return }
        if let documentController { documentController.restore(saved) } else { pendingState = saved }
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
            return DocumentWindow.newQueryItem(itemIdentifier)
        default:
            return nil
        }
        return item
    }
}

/// File window content: the data grid or the statistics of the current sheet, and — for workbooks with
/// several sheets — a sheet bar along the bottom, like Excel's.
final class DocumentViewController: NSViewController {
    enum Mode: Int { case data, stats }

    let workspace: Workspace
    var onModeChange: ((Mode) -> Void)?
    /// Something a restored window should bring back changed (mode, sheet, sort, filters, scroll).
    var onStateChange: (() -> Void)?
    var mode: Mode = .data { didSet { if mode != oldValue { showContent() } } }

    /// Restorable state of the window (SPEC: restore after quitting).
    struct SavedState: Codable {
        var mode = Mode.data.rawValue
        var sheet = 0
        var grid: GridViewController.SavedState?
    }

    var savedState: SavedState {
        SavedState(mode: mode.rawValue, sheet: workspace.currentSheet, grid: grids[workspace.currentSheet]?.savedState)
    }

    func restore(_ state: SavedState) {
        if workspace.sheets.indices.contains(state.sheet) { workspace.currentSheet = state.sheet }
        mode = Mode(rawValue: state.mode) ?? .data
        showContent()
        if let gridState = state.grid { grid(for: workspace.currentSheet).restore(gridState) }
    }

    /// Grid and statistics of each sheet, created when the sheet is first shown.
    private var grids: [Int: GridViewController] = [:]
    private var stats: [Int: StatsViewController] = [:]

    private let contentView = NSView()
    private let sheetBar = NSStackView()
    private var sheetButtons: [NSButton] = []

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        if workspace.sheets.count > 1 {
            let bar = makeSheetBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bar)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: root.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: bar.topAnchor),
                bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 30),
            ])
        } else {
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: root.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        showContent()
    }

    /// Sheet buttons in a horizontally scrolling strip, the selected one highlighted.
    private func makeSheetBar() -> NSView {
        let container = NSVisualEffectView()
        container.material = .titlebar
        container.blendingMode = .withinWindow

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        sheetBar.orientation = .horizontal
        sheetBar.spacing = 2
        sheetBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for (index, sheet) in workspace.sheets.enumerated() {
            let button = NSButton(title: sheet.name ?? "Sheet \(index + 1)", target: self, action: #selector(sheetClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.setButtonType(.pushOnPushOff)
            button.controlSize = .small
            button.tag = index
            button.toolTip = "\(sheet.sqlName) — \(sheet.entry.rowCount.formatted()) rows × \(sheet.entry.columns.count) columns"
            sheetButtons.append(button)
            sheetBar.addArrangedSubview(button)
        }
        let count = NSTextField(labelWithString: "\(workspace.sheets.count) sheets")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .tertiaryLabelColor
        sheetBar.addArrangedSubview(count)

        let scroll = NSScrollView()
        scroll.documentView = sheetBar
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sheetBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(divider)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sheetBar.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            sheetBar.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            sheetBar.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        return container
    }

    @objc private func sheetClicked(_ sender: NSButton) {
        selectSheet(sender.tag)
    }

    func selectSheet(_ index: Int) {
        guard workspace.sheets.indices.contains(index) else { return }
        workspace.currentSheet = index
        showContent()
    }

    private func grid(for index: Int) -> GridViewController {
        if let grid = grids[index] { return grid }
        let sheet = workspace.sheets[index]
        var details = ByteCountFormatter.string(fromByteCount: workspace.fileSize, countStyle: .file)
        if let name = sheet.name, workspace.sheets.count > 1 { details = "sheet \(name) · " + details }
        let grid = GridViewController(session: sheet.session, details: details)
        grid.onStateChange = { [weak self] in self?.onStateChange?() }
        let base = workspace.url.deletingPathExtension().lastPathComponent
        grid.exportName = sheet.name.map { "\(base)_\($0)" } ?? base
        grids[index] = grid
        return grid
    }

    private func statsController(for index: Int) -> StatsViewController {
        if let controller = stats[index] { return controller }
        let grid = grid(for: index)
        let controller = StatsViewController(workspace: workspace, sheet: workspace.sheets[index])
        controller.dataView = { [unowned grid] in (grid.appliedSpec, grid.appliedRowCount) }
        controller.onOpenSQL = { sql in QueryDocument.open(sql: sql, run: true) }
        grid.onViewChange = { [weak controller] in controller?.dataViewChanged() }
        stats[index] = controller
        return controller
    }

    private func showContent() {
        let index = workspace.currentSheet
        let next: NSViewController = mode == .data ? grid(for: index) : statsController(for: index)
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(next)
        next.view.frame = contentView.bounds
        next.view.autoresizingMask = [.width, .height]
        contentView.addSubview(next.view)
        for button in sheetButtons { button.state = button.tag == index ? .on : .off }
        if mode == .data { view.window?.makeFirstResponder(next.view) }
        onModeChange?(mode)
        onStateChange?()
    }

    /// File → Export To when no grid is first responder: export the current sheet's data view.
    @objc func exportData(_ sender: Any?) {
        guard mode == .data else { NSSound.beep(); return }
        grid(for: workspace.currentSheet).exportData(sender)
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
