import AppKit

/// The data grid of a document window: virtualized NSTableView, lazy page loading,
/// sorting by header click, "contains" filters in the header, and a status bar.
final class GridViewController: NSViewController {
    let session: TableSession
    /// Extra status bar text after the row and column counts (e.g. file size, query time).
    var details: String? { didSet { if isViewLoaded { updateStatus() } } }

    private var currentView: TableSession.View
    private var spec = ViewSpec()

    // Page cache (main thread only).
    private var pages: [Int: [[String?]]] = [:]
    private var pageOrder: [Int] = []
    private var loading: Set<Int> = []
    private let maxCachedPages: Int

    // Pages the user can currently see (± one page), read from the page queue.
    private let wantedLock = NSLock()
    private var wanted: (viewID: Int, pages: ClosedRange<Int>) = (0, 0...0)

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let header = FilterHeaderView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var buildStartedAt: Date?
    private var lastBuildDuration: TimeInterval?
    private var errorText: String?

    private static let rowNumberID = NSUserInterfaceItemIdentifier("#")

    /// Data columns are identified as "c<index>"; returns -1 for the row number column.
    private static func dataColumnIndex(_ column: NSTableColumn) -> Int {
        Int(column.identifier.rawValue.dropFirst()) ?? -1
    }

    init(session: TableSession, details: String? = nil) {
        self.session = session
        self.details = details
        self.currentView = session.identityView
        // Keep roughly 5M cells cached regardless of how wide the file is.
        maxCachedPages = max(8, 5_000_000 / max(1, session.pageSize * max(1, session.columns.count)))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: View setup

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(divider)
        root.addSubview(spinner)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),

            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])

        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        updateStatus()
    }

    private func configureTable() {
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = true
        tableView.usesAutomaticRowHeights = false

        let digits = String(max(1, session.totalRows)).count
        let rowNumber = NSTableColumn(identifier: Self.rowNumberID)
        rowNumber.headerCell = TitleHeaderCell(textCell: "#")
        rowNumber.width = CGFloat(max(3, digits)) * 8 + 16
        rowNumber.minWidth = 30
        tableView.addTableColumn(rowNumber)

        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        for (index, column) in session.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            tableColumn.headerCell = TitleHeaderCell(textCell: column.name)
            tableColumn.headerToolTip = "\(column.name)\n\(column.type)"
            let titleWidth = (column.name as NSString).size(withAttributes: [.font: headerFont]).width + 30
            let typical: CGFloat = switch column.kind {
            case .number: 90
            case .text: 160
            case .nested: 240
            case .binary: 110
            case .other: 150
            }
            tableColumn.width = min(400, max(titleWidth, typical))
            tableColumn.minWidth = 40
            tableView.addTableColumn(tableColumn)
        }

        tableView.headerView = header
        header.setUp(columns: tableView.tableColumns)
        header.onFilterChange = { [weak self] column, text, _ in self?.filterChanged(column: column, text: text) }

        tableView.dataSource = self
        tableView.delegate = self

        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Value", action: #selector(copyValue(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Rows", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Column Name", action: #selector(copyColumnName(_:)), keyEquivalent: "")
        tableView.menu = menu
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        requestVisiblePages()
    }

    // MARK: Paging

    @objc private func visibleAreaChanged(_ note: Notification) {
        requestVisiblePages()
    }

    private func pageCount(for view: TableSession.View) -> Int {
        (view.rowCount + session.pageSize - 1) / session.pageSize
    }

    private func requestVisiblePages() {
        guard currentView.rowCount > 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let firstRow = max(0, visible.location)
        let lastRow = max(firstRow, visible.location + max(visible.length, 1) - 1)
        let firstPage = firstRow / session.pageSize
        let lastPage = min(pageCount(for: currentView) - 1, lastRow / session.pageSize)
        guard firstPage <= lastPage else { return }

        let wantedRange = max(0, firstPage - 1)...min(pageCount(for: currentView) - 1, lastPage + 1)
        wantedLock.lock()
        wanted = (currentView.id, wantedRange)
        wantedLock.unlock()

        // Visible pages first, then the neighbours.
        let order = Array(firstPage...lastPage) + wantedRange.filter { $0 < firstPage || $0 > lastPage }
        for page in order where pages[page] == nil && !loading.contains(page) {
            load(page)
        }
    }

    private func isWanted(_ page: Int, viewID: Int) -> Bool {
        wantedLock.lock()
        defer { wantedLock.unlock() }
        return wanted.viewID == viewID && wanted.pages.contains(page)
    }

    private func load(_ page: Int) {
        loading.insert(page)
        let view = currentView
        session.loadPage(page, of: view, isWanted: { [weak self] in
            self?.isWanted(page, viewID: view.id) ?? false
        }) { [weak self] result in
            guard let self, view.id == self.currentView.id else { return }
            loading.remove(page)
            switch result {
            case nil:
                break  // skipped: scrolled away before the page was read
            case .success(let rows):
                store(page, rows: rows)
                reload(page: page)
            case .failure(let error):
                errorText = error.localizedDescription
                updateStatus()
            }
        }
    }

    private func store(_ page: Int, rows: [[String?]]) {
        pages[page] = rows
        pageOrder.removeAll { $0 == page }
        pageOrder.append(page)
        while pageOrder.count > maxCachedPages, let victim = pageOrder.first(where: { !isWanted($0, viewID: currentView.id) }) {
            pageOrder.removeAll { $0 == victim }
            pages[victim] = nil
        }
    }

    private func reload(page: Int) {
        let pageRows = (page * session.pageSize)..<min(currentView.rowCount, (page + 1) * session.pageSize)
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleRows = visible.location..<(visible.location + visible.length)
        let rows = pageRows.clamped(to: visibleRows)
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func rowValues(_ row: Int) -> [String?]? {
        guard let page = pages[row / session.pageSize] else { return nil }
        let offset = row % session.pageSize
        return offset < page.count ? page[offset] : nil
    }

    // MARK: Sort & filter

    private func filterChanged(column: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { spec.filters[column] = nil } else { spec.filters[column] = trimmed }
        applySpec()
    }

    private func sortClicked(column: Int) {
        // none → ascending → descending → none
        if let sort = spec.sort, sort.column == column {
            spec.sort = sort.ascending ? .init(column: column, ascending: false) : nil
        } else {
            spec.sort = .init(column: column, ascending: true)
        }
        updateSortIndicators()
        applySpec()
    }

    private func updateSortIndicators() {
        for (index, column) in session.columns.enumerated() {
            let tableColumn = tableView.tableColumns[index + 1]
            var title = column.name
            if let sort = spec.sort, sort.column == index { title += sort.ascending ? "  ▲" : "  ▼" }
            tableColumn.headerCell.stringValue = title
        }
        header.needsDisplay = true
    }

    private func applySpec() {
        guard spec != currentView.spec || buildStartedAt != nil else { return }
        let requested = spec
        buildStartedAt = Date()
        errorText = nil
        spinner.startAnimation(nil)
        updateStatus()

        session.makeView(requested) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let newView):
                guard newView.spec == spec else {
                    session.dropView(newView)
                    return
                }
                let old = currentView
                currentView = newView
                session.dropView(old)
                lastBuildDuration = buildStartedAt.map { Date().timeIntervalSince($0) }
                finishBuild()
                pages = [:]
                pageOrder = []
                loading = []
                tableView.deselectAll(nil)
                tableView.reloadData()
                tableView.scrollRowToVisible(0)
                requestVisiblePages()
            case .failure(let error):
                guard requested == spec else { return }
                errorText = error.localizedDescription
                finishBuild()
            }
            updateStatus()
        }
    }

    private func finishBuild() {
        buildStartedAt = nil
        spinner.stopAnimation(nil)
    }

    // MARK: Status bar

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        return f
    }()

    private func format(_ n: Int) -> String { Self.numberFormatter.string(from: NSNumber(value: n)) ?? String(n) }

    private func updateStatus() {
        if let errorText {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = errorText.replacingOccurrences(of: "\n", with: " ")
            return
        }
        statusLabel.textColor = .secondaryLabelColor

        let total = session.totalRows
        var parts: [String] = []
        if currentView.spec.activeFilters.isEmpty {
            parts.append("\(format(total)) rows")
        } else {
            parts.append("\(format(currentView.rowCount)) of \(format(total)) rows")
        }
        parts.append("\(session.columns.count) columns")
        if let details { parts.append(details) }
        if let sort = currentView.spec.sort {
            parts.append("sorted by \(session.columns[sort.column].name) \(sort.ascending ? "▲" : "▼")")
        }
        if buildStartedAt != nil {
            parts.append(spec.sort != currentView.spec.sort ? "sorting…" : "filtering…")
        } else if let lastBuildDuration {
            parts.append(String(format: "%.2f s", lastBuildDuration))
        }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Copy

    /// ⌘C / "Copy Rows": selected rows (or the right-clicked row) as TSV with a header line.
    @objc func copy(_ sender: Any?) {
        var rows = tableView.selectedRowIndexes
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) { rows = IndexSet(integer: tableView.clickedRow) }
        guard !rows.isEmpty else { NSSound.beep(); return }
        guard rows.count <= 100_000 else {
            errorText = "Copy is limited to 100 000 rows"
            updateStatus()
            return
        }

        var lines = [session.columns.map { tsv($0.name) }.joined(separator: "\t")]
        lines.reserveCapacity(rows.count + 1)
        var fetched: [Int: [[String?]]] = [:]
        for row in rows {
            let page = row / session.pageSize
            if pages[page] == nil, fetched[page] == nil {
                fetched[page] = (try? session.loadPageSync(page, of: currentView)) ?? []
            }
            let values = (pages[page] ?? fetched[page])?[safe: row % session.pageSize] ?? []
            lines.append(zip(session.columns, values).map { column, raw in
                tsv(CellFormatter.display(raw, kind: column.kind, maxChars: TableSession.maxCellChars) ?? "")
            }.joined(separator: "\t"))
        }
        writeToPasteboard(lines.joined(separator: "\n"))
    }

    @objc func copyValue(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn - 1
        guard row >= 0, column >= 0, let values = rowValues(row) else { NSSound.beep(); return }
        let raw = values[column]
        writeToPasteboard(CellFormatter.display(raw, kind: session.columns[column].kind, maxChars: TableSession.maxCellChars) ?? "NULL")
    }

    @objc func copyColumnName(_ sender: Any?) {
        let column = tableView.clickedColumn - 1
        guard column >= 0 else { NSSound.beep(); return }
        writeToPasteboard(session.columns[column].name)
    }

    @objc func focusFilter(_ sender: Any?) {
        let selectedColumn = tableView.clickedColumn > 0 ? tableView.clickedColumn - 1 : 0
        header.focusField(column: selectedColumn)
    }

    private func tsv(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private func writeToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

extension GridViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return !tableView.selectedRowIndexes.isEmpty || tableView.clickedRow >= 0
        case #selector(copyValue(_:)):
            return tableView.clickedRow >= 0 && tableView.clickedColumn > 0 && rowValues(tableView.clickedRow) != nil
        case #selector(copyColumnName(_:)):
            return tableView.clickedColumn > 0
        default:
            return true
        }
    }
}

extension GridViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { currentView.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? {
            let cell = GridCell()
            cell.identifier = GridCell.identifier
            return cell
        }()

        guard let tableColumn else { return cell }
        if tableColumn.identifier == Self.rowNumberID {
            cell.text = String(row + 1)
            cell.style = .rowNumber
            return cell
        }

        let index = Self.dataColumnIndex(tableColumn)
        guard index >= 0, let values = rowValues(row), index < values.count else {
            cell.text = ""
            cell.style = .placeholder
            return cell
        }
        let column = session.columns[index]
        if let text = CellFormatter.display(values[index], kind: column.kind, maxChars: TableSession.maxCellChars) {
            cell.text = text
            cell.style = column.kind == .number ? .number : .value
        } else {
            cell.text = "NULL"
            cell.style = .null
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let index = Self.dataColumnIndex(tableColumn)
        guard index >= 0 else { return }
        sortClicked(column: index)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
