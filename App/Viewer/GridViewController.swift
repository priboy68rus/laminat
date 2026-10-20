import AppKit

/// The data grid of a document window: virtualized NSTableView, lazy page loading,
/// sorting by header click, "contains" filters in the header, and a status bar.
final class GridViewController: NSViewController {
    let session: TableSession
    /// Extra status bar text after the row and column counts (e.g. file size, query time).
    var details: String? { didSet { if isViewLoaded { updateStatus() } } }

    private var currentView: TableSession.View
    /// Sort and filters currently applied (not just typed).
    var appliedSpec: ViewSpec { currentView.spec }
    var appliedRowCount: Int { currentView.rowCount }
    /// Called after a new sort / filter has been applied.
    var onViewChange: (() -> Void)?
    private var spec = ViewSpec()

    // Cache (main thread only): page → the columns loaded for it. Only visible columns (plus a
    // margin) are fetched; the rest come in as the user scrolls sideways.
    private var pages: [Int: TableSession.PageColumns] = [:]
    private var pageOrder: [Int] = []           // least recently used first
    private var loading: [Int: Set<Int>] = [:]  // page → columns being fetched
    private var cachedCells = 0
    private static let maxCachedCells = 5_000_000
    private static let columnMargin = 2

    // Pages the user can currently see (± one page), read from the page queue.
    private let wantedLock = NSLock()
    private var wanted: (viewID: Int, pages: ClosedRange<Int>, columns: Set<Int>) = (0, 0...0, [])

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let header = FilterHeaderView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let overlay = ProgressOverlay(frame: .zero)

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

        overlay.install(in: root, over: scrollView.contentView)  // header with filters stays usable
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
        // No built-in zebra / grid: NSTableView draws them on its background view over the whole content
        // height (600M points for 30M rows), which stalls horizontal scrolling for seconds. Row views
        // (visible rows only) get the alternating colour instead, and cells draw their own grid line.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
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
        (view.rowCount + view.pageSize - 1) / view.pageSize
    }

    /// Data columns on screen, plus a small margin on each side.
    private func visibleDataColumns() -> [Int] {
        let onScreen = tableView.columnIndexes(in: tableView.visibleRect)
        guard let first = onScreen.first, let last = onScreen.last else { return [] }
        let low = max(1, first - Self.columnMargin)
        let high = min(tableView.numberOfColumns - 1, last + Self.columnMargin)
        guard low <= high else { return [] }
        return (low...high).map { $0 - 1 }  // table column 0 is the row number
    }

    private func requestVisiblePages() {
        guard currentView.rowCount > 0 else { return }
        let pageSize = currentView.pageSize
        let visible = tableView.rows(in: tableView.visibleRect)
        let firstRow = max(0, visible.location)
        let lastRow = max(firstRow, visible.location + max(visible.length, 1) - 1)
        let firstPage = firstRow / pageSize
        let lastPage = min(pageCount(for: currentView) - 1, lastRow / pageSize)
        guard firstPage <= lastPage else { return }

        let wantedRange = max(0, firstPage - 1)...min(pageCount(for: currentView) - 1, lastPage + 1)
        let columns = visibleDataColumns()
        wantedLock.lock()
        wanted = (currentView.id, wantedRange, Set(columns))
        wantedLock.unlock()
        guard !columns.isEmpty else { return }
        // Visible pages first, then the neighbours.
        let order = Array(firstPage...lastPage) + wantedRange.filter { $0 < firstPage || $0 > lastPage }
        for page in order {
            let have = Set(pages[page].map { Array($0.keys) } ?? []).union(loading[page] ?? [])
            let missing = columns.filter { !have.contains($0) }
            if !missing.isEmpty { load(page, columns: missing) }
        }
    }

    private func isWanted(_ page: Int, viewID: Int) -> Bool {
        wantedLock.lock()
        defer { wantedLock.unlock() }
        return wanted.viewID == viewID && wanted.pages.contains(page)
    }

    /// Called on the page queue: the requested columns of `page` that are still on screen.
    private func stillWanted(_ page: Int, _ columns: [Int], viewID: Int) -> [Int] {
        wantedLock.lock()
        defer { wantedLock.unlock() }
        guard wanted.viewID == viewID, wanted.pages.contains(page) else { return [] }
        return columns.filter(wanted.columns.contains)
    }

    private func load(_ page: Int, columns: [Int]) {
        loading[page, default: []].formUnion(columns)
        let view = currentView
        session.loadPage(page, columns: columns, of: view, stillWanted: { [weak self] requested in
            self?.stillWanted(page, requested, viewID: view.id) ?? []
        }) { [weak self] result in
            guard let self, view.id == self.currentView.id else { return }
            loading[page]?.subtract(columns)
            if loading[page]?.isEmpty == true { loading[page] = nil }
            switch result {
            case nil:
                break  // skipped: scrolled away before the page was read
            case .success(let data):
                store(page, data)
                reload(page: page, columns: Array(data.keys))
            case .failure(let error):
                errorText = error.localizedDescription
                updateStatus()
                return  // don't retry in a loop
            }
            // Columns dropped from this request (scrolled away and back) are requested again.
            requestVisiblePages()
        }
    }

    private func store(_ page: Int, _ data: TableSession.PageColumns) {
        var entry = pages[page] ?? [:]
        for (column, values) in data where entry[column] == nil {
            entry[column] = values
            cachedCells += values.count
        }
        pages[page] = entry
        pageOrder.removeAll { $0 == page }
        pageOrder.append(page)

        while cachedCells > Self.maxCachedCells,
              let victim = pageOrder.first(where: { !isWanted($0, viewID: currentView.id) }) {
            pageOrder.removeAll { $0 == victim }
            cachedCells -= pages[victim]?.values.reduce(0) { $0 + $1.count } ?? 0
            pages[victim] = nil
        }
    }

    private func reload(page: Int, columns: [Int]) {
        let pageSize = currentView.pageSize
        let pageRows = (page * pageSize)..<min(currentView.rowCount, (page + 1) * pageSize)
        let visible = tableView.rows(in: tableView.visibleRect)
        let rows = pageRows.clamped(to: visible.location..<(visible.location + visible.length))
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows),
                             columnIndexes: IndexSet(columns.map { $0 + 1 }))
    }

    /// The raw value of a cell: `.none` while not loaded, `.some(nil)` for NULL.
    private func value(_ row: Int, _ column: Int) -> String?? {
        let pageSize = currentView.pageSize
        guard let values = pages[row / pageSize]?[column] else { return .none }
        let offset = row % pageSize
        return offset < values.count ? .some(values[offset]) : .none
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
        overlay.start(requested.sort != currentView.spec.sort ? "Sorting…" : "Filtering…")
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
                loading = [:]
                cachedCells = 0
                tableView.deselectAll(nil)
                tableView.reloadData()
                tableView.scrollRowToVisible(0)
                requestVisiblePages()
                onViewChange?()
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
        overlay.stop()
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
        let pageSize = currentView.pageSize
        let allColumns = Array(session.columns.indices)
        var complete: [Int: TableSession.PageColumns] = [:]  // pages with every column
        for row in rows {
            let page = row / pageSize
            if complete[page] == nil {
                var data = pages[page] ?? [:]
                let missing = allColumns.filter { data[$0] == nil }
                if !missing.isEmpty, let fetched = try? session.loadPageSync(page, columns: missing, of: currentView) {
                    data.merge(fetched) { $1 }
                }
                complete[page] = data
            }
            let offset = row % pageSize
            lines.append(session.columns.enumerated().map { index, column in
                let raw = complete[page]?[index]?[safe: offset] ?? nil
                return tsv(CellFormatter.display(raw, kind: column.kind, maxChars: TableSession.maxCellChars) ?? "")
            }.joined(separator: "\t"))
        }
        writeToPasteboard(lines.joined(separator: "\n"))
    }

    @objc func copyValue(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn - 1
        guard row >= 0, column >= 0, case .some(let raw) = value(row, column) else { NSSound.beep(); return }
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
            return tableView.clickedRow >= 0 && tableView.clickedColumn > 0
                && value(tableView.clickedRow, tableView.clickedColumn - 1) != nil
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
        guard index >= 0, case .some(let raw) = value(row, index) else {
            cell.text = ""
            cell.style = .placeholder
            return cell
        }
        let column = session.columns[index]
        if let text = CellFormatter.display(raw, kind: column.kind, maxChars: TableSession.maxCellChars) {
            cell.text = text
            cell.style = column.kind == .number ? .number : .value
        } else {
            cell.text = "NULL"
            cell.style = .null
        }
        return cell
    }

    /// Cells draw into their row's single layer instead of each owning a backing store.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.canDrawSubviewsIntoLayer = true
        rowView.backgroundColor = GridCell.rowBackground(row)
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
