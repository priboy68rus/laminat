import AppKit

/// SQL tab sidebar: the window's tables (its file plus any added ones) with their columns.
/// ＋ or dropping .parquet files from Finder adds tables; double-click inserts a name into the query.
final class TablesSidebar: NSViewController {
    let workspace: Workspace
    /// Inserts text at the editor's cursor.
    var onInsert: ((String) -> Void)?
    /// Called after tables were added or removed (for completion, etc.).
    var onTablesChanged: (() -> Void)?
    /// Reports a problem (e.g. a file that isn't Parquet).
    var onError: ((String) -> Void)?

    private let outline = NSOutlineView()

    /// Outline items are reference types so NSOutlineView can track them.
    private final class TableItem {
        let entry: Workspace.TableEntry
        lazy var columns = entry.columns.map { ColumnItem(column: $0) }
        init(_ entry: Workspace.TableEntry) { self.entry = entry }
    }

    private final class ColumnItem {
        let column: ParquetColumn
        init(column: ParquetColumn) { self.column = column }
    }

    private var items: [TableItem] = []

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
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
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let hint = NSTextField(wrappingLabelWithString: "Drop .parquet files here to query them together.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        for v in [title, add, scroll, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            add.centerYAnchor.constraint(equalTo: title.centerYAnchor),
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
        outline.expandItem(items.first)
    }

    func reload() {
        let expanded = Set(items.filter { outline.isItemExpanded($0) }.map(\.entry.alias))
        items = workspace.tables.map(TableItem.init)
        outline.reloadData()
        for item in items where expanded.contains(item.entry.alias) { outline.expandItem(item) }
    }

    // MARK: Adding files

    @objc private func addFile(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init("org.apache.parquet") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Add Parquet files to query them together with \(workspace.tableName)"
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            _ = add(panel.urls)
        }
    }

    /// Adds files as tables; returns the entries (existing ones for files already added).
    @discardableResult
    func add(_ urls: [URL]) -> [Workspace.TableEntry] {
        var added: [Workspace.TableEntry] = []
        for url in urls {
            do {
                let entry = try workspace.addFile(url)
                added.append(entry)
            } catch {
                onError?("Can't add \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        if let last = added.last, let item = items.first(where: { $0.entry.alias == last.alias }) {
            outline.expandItem(item)
            outline.scrollRowToVisible(outline.row(forItem: item))
        }
        onTablesChanged?()
        return added
    }

    static func parquetURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "parquet" }
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            onInsert?(Workspace.sqlName(table.entry.name))
        } else if let column = item as? ColumnItem {
            onInsert?(Workspace.sqlName(column.column.name))
        }
    }

    @objc private func insertName(_ sender: NSMenuItem) {
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            onInsert?(Workspace.sqlName(sender.tag == 1 ? table.entry.alias : table.entry.name))
        } else if let column = item as? ColumnItem {
            onInsert?(Workspace.sqlName(column.column.name))
        }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let table = outline.item(atRow: outline.clickedRow) as? TableItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([table.entry.url])
    }

    @objc private func removeTable(_ sender: Any?) {
        guard let table = outline.item(atRow: outline.clickedRow) as? TableItem, !table.entry.isPrimary else { return }
        workspace.removeTable(alias: table.entry.alias)
        reload()
        onTablesChanged?()
    }
}

extension TablesSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        if let table = item as? TableItem {
            menu.addItem(withTitle: "Insert Name", action: #selector(insertName(_:)), keyEquivalent: "").target = self
            let alias = menu.addItem(withTitle: "Insert Alias (\(table.entry.alias))", action: #selector(insertName(_:)), keyEquivalent: "")
            alias.target = self
            alias.tag = 1
            menu.addItem(.separator())
            menu.addItem(withTitle: "Show in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
            if !table.entry.isPrimary {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Remove from Query Tables", action: #selector(removeTable(_:)), keyEquivalent: "").target = self
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
        guard !Self.parquetURLs(from: info.draggingPasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        !add(Self.parquetURLs(from: info.draggingPasteboard)).isEmpty
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
