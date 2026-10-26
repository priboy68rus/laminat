import AppKit

/// A query tab (SPEC §1.5): tables sidebar on the left (every open file plus files added here);
/// editor on top, result grid below. ⌘↩ runs the selection or the whole text, ⎋ / Stop cancels,
/// ⌘⇧T inserts a template.
final class SQLViewController: NSViewController {
    let session: QuerySession
    private let initialSQL: String

    private let split = NSSplitView()
    private let outerSplit = NSSplitView()
    private lazy var sidebar = TablesSidebar(session: session)
    private let textView: SQLTextView
    private let editorScroll: NSScrollView
    /// Run / Stop live in the window toolbar (QueryWindowController), like Xcode's run button.
    let runButton = NSButton(title: "Run", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let templatesButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsContainer = NSView()
    private let overlay = ProgressOverlay(frame: .zero)

    private var resultGrid: GridViewController?
    private var currentResult: QuerySession.SQLResult?
    private var history: [String] = []
    private var isRunning = false { didSet { updateControls() } }

    init(session: QuerySession, initialSQL: String) {
        self.session = session
        self.initialSQL = initialSQL
        (editorScroll, textView) = SQLTextView.makeScrollable()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))

        configureEditor()
        let editorPane = NSView()
        let bar = makeBar()
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        editorPane.addSubview(bar)
        editorPane.addSubview(editorScroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: editorPane.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor, constant: -8),
            editorScroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            editorScroll.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
        ])

        overlay.install(in: resultsContainer)
        overlay.onCancel = { [weak self] in self?.stopQuery(nil) }
        showPlaceholder("Press ⌘↩ to run the query. Every open file is a table (see the list on the left).\nDrop more Parquet, CSV, JSON or Excel files on the list or the editor to join them; press Space on a table to preview it.")

        // Tables sidebar: inserting names, adding files dropped on the editor.
        addChild(sidebar)
        sidebar.onInsert = { [weak self] text in self?.insertAtCursor(text) }
        sidebar.onError = { [weak self] message in
            self?.statusLabel.textColor = .systemRed
            self?.statusLabel.stringValue = message
        }
        textView.onDropFiles = { [weak self] urls, insertNames in
            // Files dropped into the query become tables; their names go where they were dropped.
            self?.sidebar.add(urls) { entries in
                if !entries.isEmpty { insertNames(entries.map(\.sqlName).joined(separator: ", ")) }
            }
        }

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorPane)
        split.addArrangedSubview(resultsContainer)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.addArrangedSubview(sidebar.view)
        outerSplit.addArrangedSubview(split)
        outerSplit.setHoldingPriority(.defaultLow + 2, forSubviewAt: 0)  // sidebar keeps its width
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outerSplit)
        NSLayoutConstraint.activate([
            outerSplit.topAnchor.constraint(equalTo: root.topAnchor),
            outerSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outerSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outerSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            split.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            editorPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            resultsContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        view = root
        updateControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if split.subviews.first?.frame.height ?? 0 > 0, !didPositionDivider {
            didPositionDivider = true
            split.setPosition(220, ofDividerAt: 0)
            outerSplit.setPosition(230, ofDividerAt: 0)
        }
        view.window?.makeFirstResponder(textView)
    }

    private var didPositionDivider = false

    private func configureEditor() {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = SQLHighlighter.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.usesFindBar = true  // Edit → Find (⌘F, ⌘G…) like any macOS text editor
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        textView.string = initialSQL
        if let storage = textView.textStorage { SQLHighlighter.apply(to: storage) }
    }

    private func makeBar() -> NSView {
        runButton.bezelStyle = .toolbar
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        runButton.imagePosition = .imageLeading
        runButton.target = self
        runButton.action = #selector(runQuery(_:))
        runButton.toolTip = "Run (⌘↩)"

        stopButton.bezelStyle = .toolbar
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.imagePosition = .imageLeading
        stopButton.target = self
        stopButton.action = #selector(stopQuery(_:))
        stopButton.toolTip = "Stop (⎋)"

        templatesButton.addItem(withTitle: "Templates")
        for (index, template) in SQLTemplate.all.enumerated() {
            let item = NSMenuItem(title: template.title, action: #selector(insertTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            templatesButton.menu?.addItem(item)
        }
        templatesButton.toolTip = "Insert a template (⌘⇧T)"

        historyButton.addItem(withTitle: "History")
        historyButton.toolTip = "Queries run in this window"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [templatesButton, historyButton, spacer, spinner, statusLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    // MARK: Actions

    @objc func runQuery(_ sender: Any?) {
        guard !isRunning else { return }
        let selection = textView.selectedRange()
        let text = selection.length > 0 ? (textView.string as NSString).substring(with: selection) : textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }

        isRunning = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Running…"
        overlay.start("Executing query…")
        let startedAt = Date()
        session.run(text) { [weak self] result in
            guard let self else { return }
            isRunning = false
            overlay.stop()
            switch result {
            case .success(let sqlResult):
                remember(text)
                show(sqlResult)
            case .failure(let error) where error.localizedDescription.localizedCaseInsensitiveContains("interrupt"):
                // Cancelled by the user: keep the previous result on screen.
                statusLabel.textColor = .secondaryLabelColor
                statusLabel.stringValue = String(format: "Cancelled after %.1f s", Date().timeIntervalSince(startedAt))
            case .failure(let error):
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Error"
                showError(error.localizedDescription)
            }
        }
    }

    @objc func stopQuery(_ sender: Any?) {
        session.cancel()
    }

    /// Replaces the editor text (undoably) and optionally runs it.
    func setQuery(_ sql: String, run: Bool) {
        _ = view  // make sure the editor exists
        replaceText(with: sql)
        if run { runQuery(nil) }
    }

    /// File → Export… while the editor has focus: export the current result.
    var canExportResult: Bool { resultGrid != nil && !isRunning }

    @objc func exportResult(_ sender: Any?) {
        resultGrid?.exportData(sender)
    }

    /// File → Export To while the editor has focus: export the current result.
    @objc func exportData(_ sender: Any?) {
        guard canExportResult else { NSSound.beep(); return }
        resultGrid?.exportData(sender)
    }

    /// Table used by templates: the one selected in the sidebar, else the first open file.
    private var templateTable: String {
        sidebar.selectedTableName ?? Catalog.shared.tables.first?.sqlName ?? "my_table"
    }

    /// ⌘⇧T: pop up the templates menu.
    @objc func showTemplates(_ sender: Any?) {
        templatesButton.performClick(nil)
    }

    @objc private func insertTemplate(_ sender: NSMenuItem) {
        let template = SQLTemplate.all[sender.tag]
        let sql = template.sql.replacingOccurrences(of: "{t}", with: templateTable)
        replaceText(with: sql)
        if !selectNextPlaceholder() {
            textView.setSelectedRange(NSRange(location: (sql as NSString).length, length: 0))
        }
        view.window?.makeFirstResponder(textView)
    }

    @objc private func restoreHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        replaceText(with: history[sender.tag])
        view.window?.makeFirstResponder(textView)
    }

    /// Inserts `text` at the cursor (replacing the selection), undoably, and focuses the editor.
    private func insertAtCursor(_ text: String) {
        let range = textView.selectedRange()
        if textView.shouldChangeText(in: range, replacementString: text) {
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
        view.window?.makeFirstResponder(textView)
    }

    /// Replaces the editor text through the text system so the change can be undone.
    private func replaceText(with text: String) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: full, replacementString: text) {
            textView.replaceCharacters(in: full, with: text)
            textView.didChangeText()
        }
    }

    /// Selects the next `⟨…⟩` placeholder after the cursor (wrapping around). Returns false if there is none.
    @discardableResult
    private func selectNextPlaceholder() -> Bool {
        let text = textView.string as NSString
        let from = NSMaxRange(textView.selectedRange())
        let pattern = "⟨[^⟩]*⟩"
        var range = text.range(of: pattern, options: .regularExpression,
                               range: NSRange(location: from, length: text.length - from))
        if range.location == NSNotFound {
            range = text.range(of: pattern, options: .regularExpression)
        }
        guard range.location != NSNotFound else { return false }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    private func remember(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 30 { history.removeLast() }

        while historyButton.numberOfItems > 1 { historyButton.removeItem(at: 1) }
        for (index, query) in history.enumerated() {
            let title = query.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
            let item = NSMenuItem(title: String(title.prefix(80)), action: #selector(restoreHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.toolTip = query
            historyButton.menu?.addItem(item)
        }
    }

    private func updateControls() {
        runButton.isEnabled = !isRunning
        stopButton.isEnabled = isRunning
        if isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Results

    private func show(_ result: QuerySession.SQLResult) {
        var details = String(format: "%.2f s", result.duration)
        if result.truncated { details += " · result truncated to \(QuerySession.maxResultRows.formatted()) rows" }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "\(result.rowCount.formatted()) row\(result.rowCount == 1 ? "" : "s") · " + details

        let grid = GridViewController(session: result.session, details: details)
        grid.exportName = "query"
        setResultView(grid.view, controller: grid)
        if let previous = currentResult { session.dropResult(previous) }
        currentResult = result
    }

    private func showError(_ message: String) {
        let scroll = NSTextView.scrollableTextView()
        let errorView = scroll.documentView as! NSTextView
        errorView.isEditable = false
        errorView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        errorView.textColor = .systemRed
        errorView.textContainerInset = NSSize(width: 8, height: 8)
        errorView.string = message
        setResultView(scroll, controller: nil)
    }

    private func showPlaceholder(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        setResultView(container, controller: nil)
    }

    private func setResultView(_ newView: NSView, controller: GridViewController?) {
        resultGrid?.removeFromParent()
        resultsContainer.subviews.filter { $0 !== overlay }.forEach { $0.removeFromSuperview() }
        resultGrid = controller
        if let controller { addChild(controller) }
        newView.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(newView, positioned: .below, relativeTo: overlay)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            newView.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
        ])
    }
}

extension SQLViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if let storage = textView.textStorage { SQLHighlighter.apply(to: storage) }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            return selectNextPlaceholder()
        case #selector(NSResponder.cancelOperation(_:)) where isRunning:
            stopQuery(nil)
            return true
        default:
            return false
        }
    }

    /// Completion (⎋ or F5): column names, table names and keywords matching the typed prefix.
    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
        let tables = Catalog.shared.tables
        let candidates = tables.flatMap { $0.columns.map(\.name) }
            + tables.flatMap { [$0.sqlName, $0.alias] + ($0.schema.map { [Catalog.sqlName($0)] } ?? []) }
            + SQLHighlighter.keywords
        var seen = Set<String>()
        return candidates.filter { $0.lowercased().hasPrefix(prefix) && seen.insert($0).inserted }
    }
}

extension SQLViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(runQuery(_:)): return !isRunning
        case #selector(stopQuery(_:)): return isRunning
        case #selector(exportData(_:)): return canExportResult
        default: return true
        }
    }
}
