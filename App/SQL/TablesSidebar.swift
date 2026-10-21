import AppKit
import UniformTypeIdentifiers

/// Query tab sidebar: every table in the app-wide catalog (open files plus files added to queries)
/// with its columns. ＋ or dropping .parquet files adds tables; double-click inserts a name; Space (or
/// Preview) shows the first rows in a popover, like Quick Look.
final class TablesSidebar: NSViewController {
    let session: QuerySession
    /// Inserts text at the editor's cursor.
    var onInsert: ((String) -> Void)?
    /// Called after tables were added or removed (for completion, etc.).
    var onTablesChanged: (() -> Void)?
    /// Reports a problem (e.g. a file that isn't Parquet).
    var onError: ((String) -> Void)?

    private let outline = SidebarOutlineView()
    private var catalogObserver: NSObjectProtocol?
    private var previewPopover: NSPopover?

    /// Outline items are reference types so NSOutlineView can track them.
    private final class TableItem {
        let entry: Catalog.TableEntry
        lazy var columns = entry.columns.map { ColumnItem(column: $0) }
        init(_ entry: Catalog.TableEntry) { self.entry = entry }
    }

    private final class ColumnItem {
        let column: ParquetColumn
        init(column: ParquetColumn) { self.column = column }
    }

    private var items: [TableItem] = []

    init(session: QuerySession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        catalogObserver = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, isViewLoaded else { return }
            reload()
            onTablesChanged?()
        }
    }

    deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
    }

    /// Name of the table selected in the list (or owning the selected column), for templates.
    var selectedTableName: String? {
        let item = outline.item(atRow: outline.selectedRow)
        if let table = item as? TableItem { return table.entry.name }
        if let column = item, let parent = outline.parent(forItem: column) as? TableItem { return parent.entry.name }
        return nil
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: "TABLES")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add File")!,
                           target: self, action: #selector(addFile(_:)))
        add.bezelStyle = .accessoryBarAction
        add.isBordered = false
        add.toolTip = "Add a Parquet file (or drop files here)"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.target = self
        outline.registerForDraggedTypes([.fileURL])
        outline.onSpace = { [weak self] in self?.previewSelected() }
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let hint = NSTextField(wrappingLabelWithString: "Every open file is listed here. Drop more Parquet, CSV, JSON or Excel files to join them; Space previews a table.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [title, add, scroll, hint, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            add.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -6),
            add.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        reload()
        if items.count == 1 { outline.expandItem(items.first) }
    }

    func reload() {
        let expanded = Set(items.filter { outline.isItemExpanded($0) }.map(\.entry.alias))
        items = Catalog.shared.tables.map(TableItem.init)
        outline.reloadData()
        for item in items where expanded.contains(item.entry.alias) { outline.expandItem(item) }
    }

    // MARK: Adding files

    @objc private func addFile(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFormat.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Add Parquet, CSV, JSON or Excel files to this query"
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            add(panel.urls)
        }
    }

    /// Adds files as tables. Parquet and already-open files are immediate; CSV / JSON / Excel load in
    /// the background. `completion` gets the entries once all of them are in (files that failed to
    /// load are reported through `onError` and left out).
    func add(_ urls: [URL], completion: (([Catalog.TableEntry]) -> Void)? = nil) {
        guard !urls.isEmpty else { completion?([]); return }
        var results = [Catalog.TableEntry?](repeating: nil, count: urls.count)
        var remaining = urls.count
        loadingCount += urls.count
        for (index, url) in urls.enumerated() {
            session.addFile(url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let entry): results[index] = entry
                case .failure(let error): onError?("Can't add \(url.lastPathComponent): \(error.localizedDescription)")
                }
                loadingCount -= 1
                remaining -= 1
                guard remaining == 0 else { return }
                let added = results.compactMap { $0 }
                reload()
                if let last = added.last, let item = items.first(where: { $0.entry.alias == last.alias }) {
                    outline.expandItem(item)
                    outline.scrollRowToVisible(outline.row(forItem: item))
                }
                onTablesChanged?()
                completion?(added)
            }
        }
    }

    /// Files being loaded right now (shown as a spinner next to the title).
    private var loadingCount = 0 { didSet { loadingCount > 0 ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }
    private let spinner = NSProgressIndicator()

    /// Supported data files on a drag pasteboard.
    static func dataFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { DataFormat(url: $0) != nil }
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            onInsert?(Catalog.sqlName(table.entry.name))
        } else if let column = item as? ColumnItem {
            onInsert?(Catalog.sqlName(column.column.name))
        }
    }

    @objc private func insertName(_ sender: NSMenuItem) {
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            onInsert?(Catalog.sqlName(sender.tag == 1 ? table.entry.alias : table.entry.name))
        } else if let column = item as? ColumnItem {
            onInsert?(Catalog.sqlName(column.column.name))
        }
    }

    // MARK: Preview (Space, like Quick Look)

    @objc private func previewClicked(_ sender: Any?) {
        guard let table = outline.item(atRow: outline.clickedRow) as? TableItem else { return }
        preview(table, row: outline.clickedRow)
    }

    private func previewSelected() {
        if let popover = previewPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        var row = outline.selectedRow
        var item = outline.item(atRow: row)
        if item is ColumnItem, let parent = outline.parent(forItem: item) as? TableItem {
            item = parent
            row = outline.row(forItem: parent)
        }
        guard let table = item as? TableItem else { return }
        preview(table, row: row)
    }

    /// A popover with the table's grid: lazy paging, sorting and filters work there too.
    private func preview(_ table: TableItem, row: Int) {
        guard row >= 0, let tableSession = try? TableSession(
            database: Catalog.shared.database, source: table.entry.source,
            columns: table.entry.columns, totalRows: table.entry.rowCount) else { NSSound.beep(); return }
        let grid = GridViewController(session: tableSession, details: table.entry.name)
        grid.exportName = table.entry.name
        grid.view.frame = NSRect(x: 0, y: 0, width: 760, height: 440)

        previewPopover?.performClose(nil)
        let popover = NSPopover()
        popover.contentViewController = grid
        popover.contentSize = NSSize(width: 760, height: 440)
        popover.behavior = .transient
        popover.show(relativeTo: outline.rect(ofRow: row), of: outline, preferredEdge: .maxX)
        previewPopover = popover
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let table = outline.item(atRow: outline.clickedRow) as? TableItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([table.entry.url])
    }

    @objc private func removeTable(_ sender: Any?) {
        guard let table = outline.item(atRow: outline.clickedRow) as? TableItem, session.owns(table.entry.url) else { return }
        session.removeFile(table.entry.url)  // the catalog notifies, which reloads the list
    }
}

extension TablesSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            menu.addItem(withTitle: "Preview", action: #selector(previewClicked(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Insert Name", action: #selector(insertName(_:)), keyEquivalent: "").target = self
            let alias = menu.addItem(withTitle: "Insert Alias (\(table.entry.alias))", action: #selector(insertName(_:)), keyEquivalent: "")
            alias.target = self
            alias.tag = 1
            menu.addItem(.separator())
            menu.addItem(withTitle: "Show in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
            if session.owns(table.entry.url) {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Remove from This Query", action: #selector(removeTable(_:)), keyEquivalent: "").target = self
            }
        } else if item is ColumnItem {
            menu.addItem(withTitle: "Insert Name", action: #selector(insertName(_:)), keyEquivalent: "").target = self
        }
    }
}

extension TablesSidebar: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return items.count }
        return (item as? TableItem)?.columns.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return items[index] }
        return (item as! TableItem).columns[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TableItem
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(item is TableItem ? "table" : "column")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier: identifier)
        if let table = item as? TableItem {
            cell.configure(icon: "tablecells", title: table.entry.name, detail: table.entry.alias,
                           toolTip: table.entry.url.path, bold: true)
        } else if let column = item as? ColumnItem {
            cell.configure(icon: nil, title: column.column.name, detail: column.column.type,
                           toolTip: "\(column.column.name)  \(column.column.type)", bold: false)
        }
        return cell
    }

    // Dropping .parquet files from Finder anywhere on the list adds them.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard !Self.dataFileURLs(from: info.draggingPasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = Self.dataFileURLs(from: info.draggingPasteboard)
        add(urls)
        return !urls.isEmpty
    }
}

/// Sidebar row: optional symbol, a name and a dimmed detail (alias or type) on the right.
private final class SidebarCell: NSTableCellView {
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentHuggingPriority(.required, for: .horizontal)
        textField = title
        imageView = icon
        for v in [icon, title, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(icon symbol: String?, title: String, detail: String, toolTip: String, bold: Bool) {
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = symbol == nil
        textField?.stringValue = title
        textField?.font = bold ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
        self.detail.stringValue = detail
        self.toolTip = toolTip
    }
}

/// Outline view that reports the Space bar (preview), like Finder's Quick Look.
private final class SidebarOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onSpace?() } else { super.keyDown(with: event) }
    }
}
