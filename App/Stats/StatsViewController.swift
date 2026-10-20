import AppKit

/// Statistics tab (SPEC §1.6): one row per column of the file, filled in waves, plus a details pane
/// with a histogram and the top values of the selected column.
final class StatsViewController: NSViewController {
    let workspace: Workspace
    /// Applied sort / filter and row count of the data grid, for the "Filtered rows" scope.
    var dataView: () -> (spec: ViewSpec, rowCount: Int) = { (ViewSpec(), 0) }
    /// Opens a query in the SQL tab.
    var onOpenSQL: ((String) -> Void)?

    private let calculator: StatsCalculator?
    private var stats: [Int: ColumnStats] = [:]
    private var order: [Int] = []             // displayed column indices (sorted / filtered)
    private var sortKey: String?
    private var sortAscending = true
    private var nameFilter = ""

    private var scopeFilter: String?
    private var scopeRows = 0
    private var hasRun = false
    private var isStale = false
    private var isRunning = false { didSet { updateControls() } }
    private var detailsToken = 0

    private let scopeControl = NSSegmentedControl(labels: ["Whole file", "Filtered rows"], trackingMode: .selectOne, target: nil, action: nil)
    private let recalcButton = NSButton(title: "Recalculate", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let detailsTitle = NSTextField(labelWithString: "")
    private let detailsSpinner = NSProgressIndicator()
    private let openSQLButton = NSButton(title: "Open in SQL", target: nil, action: nil)
    private let histogram = HistogramView()
    private let topValues = TopValuesView()
    private var histogramTitle = NSTextField(labelWithString: "")
    private let detailsMessage = NSTextField(labelWithString: "Select a column to see its distribution and most frequent values.")

    private struct StatColumn {
        let id: String
        let title: String
        let width: CGFloat
        let numeric: Bool
        let value: (ColumnStats, ParquetColumn, Int) -> String?
    }

    private lazy var statColumns: [StatColumn] = [
        StatColumn(id: "name", title: "Column", width: 170, numeric: false) { _, c, _ in c.name },
        StatColumn(id: "type", title: "Type", width: 130, numeric: false) { _, c, _ in c.type },
        StatColumn(id: "nulls", title: "Nulls", width: 90, numeric: true) { s, _, _ in s.nulls.map(Format.count) },
        StatColumn(id: "nullpct", title: "Nulls %", width: 70, numeric: true) { s, _, rows in s.nulls.map { Format.percent($0, of: rows) } },
        StatColumn(id: "distinct", title: "Unique ≈", width: 90, numeric: true) { s, _, _ in s.distinct.map(Format.count) },
        StatColumn(id: "min", title: "Min", width: 140, numeric: true) { s, _, _ in s.min.map(Format.number) },
        StatColumn(id: "max", title: "Max", width: 140, numeric: true) { s, _, _ in s.max.map(Format.number) },
        StatColumn(id: "mean", title: "Mean", width: 100, numeric: true) { s, _, _ in s.mean.map(Format.number) },
        StatColumn(id: "std", title: "Std", width: 100, numeric: true) { s, _, _ in s.std.map(Format.number) },
        StatColumn(id: "p25", title: "P25 ≈", width: 100, numeric: true) { s, _, _ in s.p25.map(Format.number) },
        StatColumn(id: "median", title: "Median ≈", width: 100, numeric: true) { s, _, _ in s.median.map(Format.number) },
        StatColumn(id: "p75", title: "P75 ≈", width: 100, numeric: true) { s, _, _ in s.p75.map(Format.number) },
        StatColumn(id: "avglen", title: "Avg length", width: 80, numeric: true) { s, _, _ in s.avgLength.map(Format.number) },
    ]

    init(workspace: Workspace) {
        self.workspace = workspace
        calculator = try? StatsCalculator(database: workspace.database, url: workspace.url, columns: workspace.summary.columns)
        super.init(nibName: nil, bundle: nil)
        order = Array(workspace.summary.columns.indices)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))

        let bar = makeBar()
        let tableScroll = makeTable()
        let details = makeDetails()

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(details)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)

        for v in [bar, split] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            details.heightAnchor.constraint(greaterThanOrEqualToConstant: 270),
        ])
        view = root
        updateControls()
    }

    private func makeBar() -> NSView {
        scopeControl.selectedSegment = 0
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        scopeControl.setToolTip("Statistics for the rows matching the Data tab filters", forSegment: 1)

        recalcButton.bezelStyle = .rounded
        recalcButton.target = self
        recalcButton.action = #selector(recalculate(_:))
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stop(_:))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "Find column"
        searchField.controlSize = .small
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [scopeControl, recalcButton, stopButton, spinner, progressLabel, spacer, searchField])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func makeTable() -> NSScrollView {
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        for column in statColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            if column.numeric { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func makeDetails() -> NSView {
        detailsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailsTitle.lineBreakMode = .byTruncatingTail
        detailsSpinner.style = .spinning
        detailsSpinner.controlSize = .small
        detailsSpinner.isDisplayedWhenStopped = false
        openSQLButton.bezelStyle = .rounded
        openSQLButton.controlSize = .small
        openSQLButton.target = self
        openSQLButton.action = #selector(openInSQL(_:))
        openSQLButton.isHidden = true
        detailsMessage.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [detailsTitle, detailsSpinner, spacer, openSQLButton])
        header.orientation = .horizontal
        header.spacing = 8

        histogramTitle = sectionLabel("Distribution")
        let topTitle = sectionLabel("Top 10 values")

        let pane = NSView()
        for v in [header, detailsMessage, histogramTitle, histogram, topTitle, topValues] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),

            detailsMessage.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            detailsMessage.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),

            histogramTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            histogramTitle.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            histogram.topAnchor.constraint(equalTo: histogramTitle.bottomAnchor, constant: 4),
            histogram.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 4),
            histogram.trailingAnchor.constraint(equalTo: pane.centerXAnchor, constant: -12),
            histogram.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -10),

            topTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            topTitle.leadingAnchor.constraint(equalTo: pane.centerXAnchor, constant: 12),
            topValues.topAnchor.constraint(equalTo: topTitle.bottomAnchor, constant: 6),
            topValues.leadingAnchor.constraint(equalTo: pane.centerXAnchor, constant: 12),
            topValues.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            topValues.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -10),
        ])
        histogramTitle.identifier = NSUserInterfaceItemIdentifier("histogramTitle")
        topTitle.identifier = NSUserInterfaceItemIdentifier("topTitle")
        setDetailsVisible(false)
        return pane
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func setDetailsVisible(_ visible: Bool) {
        detailsMessage.isHidden = visible
        histogram.isHidden = !visible
        topValues.isHidden = !visible
        histogram.superview?.subviews
            .filter { ["histogramTitle", "topTitle"].contains($0.identifier?.rawValue ?? "") }
            .forEach { $0.isHidden = !visible }
    }

    // MARK: Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()
        updateControls()
        if !hasRun || isStale { recalculate(nil) }
    }

    /// The data grid applied a new sort / filter.
    func dataViewChanged() {
        guard scopeControl.selectedSegment == 1 else { updateControls(); return }
        if view.window != nil && !view.isHiddenOrHasHiddenAncestor { recalculate(nil) } else { isStale = true }
    }

    // MARK: Actions

    /// Recalculates only when the scope actually changed (clicking the selected segment is a no-op).
    @objc private func scopeChanged(_ sender: Any?) {
        let wantsFilter = scopeControl.selectedSegment == 1
        guard wantsFilter != (scopeFilter != nil) || isStale else { return }
        recalculate(nil)
    }

    @objc private func recalculate(_ sender: Any?) {
        guard let calculator else {
            progressLabel.stringValue = "Statistics are unavailable"
            return
        }
        let data = dataView()
        let useFilter = scopeControl.selectedSegment == 1 && !data.spec.activeFilters.isEmpty
        if !useFilter { scopeControl.selectedSegment = 0 }
        scopeFilter = useFilter ? TableSession.filterConditions(data.spec, columns: workspace.summary.columns).joined(separator: " AND ") : nil
        scopeRows = useFilter ? data.rowCount : Int(workspace.summary.rowCount)

        hasRun = true
        isStale = false
        stats = [:]
        isRunning = true
        progressLabel.stringValue = "Computing…"
        tableView.reloadData()
        refreshDetails()

        let total = workspace.summary.columns.count
        calculator.run(filter: scopeFilter, rowCount: scopeRows, update: { [weak self] update, completed in
            guard let self else { return }
            stats.merge(update) { old, new in new.isComplete || !old.isComplete ? new : old }
            progressLabel.stringValue = "Computing… \(completed) of \(total) columns"
            applyOrder()
        }, finish: { [weak self] result in
            guard let self else { return }
            isRunning = false
            switch result {
            case .success(let duration):
                progressLabel.stringValue = "\(Format.count(scopeRows)) rows · \(total) columns · " + String(format: "%.2f s", duration)
            case .failure(let error):
                progressLabel.stringValue = StatsCalculator.isInterrupt(error) ? "Stopped" : "Error: \(error.localizedDescription)"
            }
        })
    }

    @objc private func stop(_ sender: Any?) {
        calculator?.cancel()
        isRunning = false
        progressLabel.stringValue = "Stopped"
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        nameFilter = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        applyOrder()
    }

    @objc private func openInSQL(_ sender: Any?) {
        guard let index = selectedColumnIndex else { return }
        let column = workspace.summary.columns[index]
        var sql = "SELECT \(SQL.identifier(column.name)), count(*) AS n\nFROM \(workspace.tableNameForSQL)"
        if let scopeFilter { sql += "\nWHERE \(scopeFilter)" }
        sql += "\nGROUP BY 1\nORDER BY n DESC\nLIMIT 100"
        onOpenSQL?(sql)
    }

    /// ⌘C: selected rows (or all) as TSV.
    @objc func copy(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes.isEmpty ? IndexSet(integersIn: 0..<order.count) : tableView.selectedRowIndexes
        var lines = [statColumns.map(\.title).joined(separator: "\t")]
        for row in rows where order.indices.contains(row) {
            let index = order[row]
            let s = stats[index] ?? ColumnStats()
            lines.append(statColumns.map { $0.value(s, workspace.summary.columns[index], scopeRows) ?? "" }.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let hasFilter = !dataView().spec.activeFilters.isEmpty
        scopeControl.setEnabled(hasFilter, forSegment: 1)
        scopeControl.setLabel(hasFilter ? "Filtered rows (\(Format.count(dataView().rowCount)))" : "Filtered rows", forSegment: 1)
        recalcButton.isEnabled = !isRunning
        stopButton.isEnabled = isRunning
        if isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Ordering

    private func applyOrder() {
        let selected = selectedColumnIndex
        let columns = workspace.summary.columns
        var indices = Array(columns.indices)
        if !nameFilter.isEmpty {
            indices = indices.filter { columns[$0].name.lowercased().contains(nameFilter) }
        }
        if let sortKey, let statColumn = statColumns.first(where: { $0.id == sortKey }) {
            indices.sort { a, b in
                let va = sortValue(statColumn, a), vb = sortValue(statColumn, b)
                let ascending: Bool
                switch (va, vb) {
                case (.number(let x), .number(let y)): ascending = x < y
                case (.text(let x), .text(let y)): ascending = x.localizedStandardCompare(y) == .orderedAscending
                case (.number, _): ascending = true
                case (_, .number): ascending = false
                case (.text, .missing): ascending = true
                default: ascending = false
                }
                return sortAscending ? ascending : !ascending
            }
        }
        order = indices
        tableView.reloadData()
        if let selected, let row = order.firstIndex(of: selected) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private enum SortValue { case number(Double), text(String), missing }

    private func sortValue(_ statColumn: StatColumn, _ index: Int) -> SortValue {
        let s = stats[index] ?? ColumnStats()
        let raw: String? = switch statColumn.id {
        case "nulls", "nullpct": s.nulls.map(String.init)
        case "distinct": s.distinct.map(String.init)
        case "min": s.min
        case "max": s.max
        case "mean": s.mean
        case "std": s.std
        case "p25": s.p25
        case "median": s.median
        case "p75": s.p75
        case "avglen": s.avgLength
        default: statColumn.value(s, workspace.summary.columns[index], scopeRows)
        }
        guard let raw else { return .missing }
        return Double(raw).map(SortValue.number) ?? .text(raw)
    }

    // MARK: Details

    private var selectedColumnIndex: Int? {
        let row = tableView.selectedRow
        return order.indices.contains(row) ? order[row] : nil
    }

    private func refreshDetails() {
        detailsToken += 1
        let token = detailsToken
        guard let index = selectedColumnIndex, let calculator else {
            detailsMessage.stringValue = "Select a column to see its distribution and most frequent values."
            detailsTitle.stringValue = ""
            openSQLButton.isHidden = true
            detailsSpinner.stopAnimation(nil)
            setDetailsVisible(false)
            return
        }
        let column = workspace.summary.columns[index]
        detailsTitle.stringValue = "\(column.name)  ·  \(column.type)"
        openSQLButton.isHidden = false
        detailsSpinner.startAnimation(nil)
        // Dim the previous column's charts until the new ones arrive.
        histogram.alphaValue = 0.3
        topValues.alphaValue = 0.3
        if histogram.isHidden { detailsMessage.stringValue = "Loading…" }

        calculator.details(column: index, filter: scopeFilter, rowCount: scopeRows) { [weak self] result in
            guard let self, token == detailsToken else { return }
            detailsSpinner.stopAnimation(nil)
            switch result {
            case .success(let details):
                setDetailsVisible(true)
                histogram.alphaValue = 1
                topValues.alphaValue = 1
                histogram.kind = details.binKind
                histogram.perValue = details.perValue
                histogramTitle.stringValue = details.binKind == .length ? "LENGTH DISTRIBUTION" : "DISTRIBUTION"
                histogram.bins = details.bins
                topValues.total = details.rowCount
                topValues.values = details.top
            case .failure(let error):
                setDetailsVisible(false)
                detailsMessage.isHidden = false
                detailsMessage.stringValue = error.localizedDescription
            }
        }
    }
}

extension StatsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? {
            let cell = GridCell()
            cell.identifier = GridCell.identifier
            return cell
        }()
        guard let tableColumn, order.indices.contains(row),
              let statColumn = statColumns.first(where: { $0.id == tableColumn.identifier.rawValue }) else { return cell }

        let index = order[row]
        let s = stats[index]
        if let value = s.flatMap({ statColumn.value($0, workspace.summary.columns[index], scopeRows) })
            ?? (["name", "type"].contains(statColumn.id) ? statColumn.value(ColumnStats(), workspace.summary.columns[index], scopeRows) : nil) {
            cell.text = value
            cell.style = statColumn.numeric ? .number : .value
        } else if isRunning && !(s?.isComplete ?? false) {
            cell.text = "…"
            cell.style = .placeholder
        } else {
            cell.text = ""
            cell.style = .placeholder
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let key = tableColumn.identifier.rawValue
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = !(statColumns.first { $0.id == key }?.numeric ?? false) }
        for column in tableView.tableColumns {
            let title = statColumns.first { $0.id == column.identifier.rawValue }?.title ?? ""
            column.title = column.identifier.rawValue == key ? title + (sortAscending ? " ▲" : " ▼") : title
        }
        applyOrder()
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.canDrawSubviewsIntoLayer = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDetails()
    }
}
