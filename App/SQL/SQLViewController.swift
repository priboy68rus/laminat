import AppKit

/// SQL mode (SPEC §1.5): editor on top, result grid below. The file is available as its file name
/// and as `t1`. ⌘↩ runs the selection or the whole text, ⎋ / Stop cancels, ⌘⇧T inserts a template.
final class SQLViewController: NSViewController {
    let workspace: Workspace

    private let split = NSSplitView()
    private let textView: NSTextView
    private let editorScroll: NSScrollView
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let templatesButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsContainer = NSView()
    private let overlay = ProgressOverlay(frame: .zero)

    private var resultGrid: GridViewController?
    private var currentResult: Workspace.SQLResult?
    private var history: [String] = []
    private var isRunning = false { didSet { updateControls() } }

    init(workspace: Workspace) {
        self.workspace = workspace
        editorScroll = NSTextView.scrollableTextView()
        textView = editorScroll.documentView as! NSTextView
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
        showPlaceholder("Press ⌘↩ to run the query. The file is available as \(workspace.tableNameForSQL) and as \(Workspace.alias).")

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorPane)
        split.addArrangedSubview(resultsContainer)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        textView.string = SQLTemplate.all[0].sql.replacingOccurrences(of: "{t}", with: workspace.tableNameForSQL)
        if let storage = textView.textStorage { SQLHighlighter.apply(to: storage) }
    }

    private func makeBar() -> NSView {
        runButton.bezelStyle = .rounded
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        runButton.imagePosition = .imageLeading
        runButton.target = self
        runButton.action = #selector(runQuery(_:))
        runButton.toolTip = "Run (⌘↩)"

        stopButton.bezelStyle = .rounded
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
        let stack = NSStackView(views: [runButton, stopButton, templatesButton, historyButton, spacer, spinner, statusLabel])
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
        workspace.runSQL(text) { [weak self] result in
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
        workspace.cancelSQL()
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

    /// ⌘⇧T: pop up the templates menu.
    @objc func showTemplates(_ sender: Any?) {
        templatesButton.performClick(nil)
    }

    @objc private func insertTemplate(_ sender: NSMenuItem) {
        let template = SQLTemplate.all[sender.tag]
        let sql = template.sql.replacingOccurrences(of: "{t}", with: workspace.tableNameForSQL)
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

    private func show(_ result: Workspace.SQLResult) {
        var details = String(format: "%.2f s", result.duration)
        if result.truncated { details += " · result truncated to \(Workspace.maxResultRows.formatted()) rows" }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "\(result.rowCount.formatted()) row\(result.rowCount == 1 ? "" : "s") · " + details

        let grid = GridViewController(session: result.session, details: details)
        grid.exportName = "\(workspace.tableName)_query"
        setResultView(grid.view, controller: grid)
        if let previous = currentResult { workspace.dropResult(previous) }
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
        let candidates = workspace.summary.columns.map(\.name)
            + [workspace.tableNameForSQL, Workspace.alias]
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
        default: return true
        }
    }
}
