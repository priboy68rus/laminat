import AppKit

/// A query tab (SPEC §1.5): tables sidebar on the left (every open file plus files added here);
/// editor on top, result grid below. ⌘↩ runs the selection or the statement under the cursor, ⎋ / Stop
/// cancels, ⌘⇧T inserts a template.
final class SQLViewController: NSViewController {
    let session: QuerySession
    private let initialSQL: String
    /// The text or the cursor changed (the window then refreshes its restorable state).
    var onTextChange: (() -> Void)?

    /// Editor contents and cursor, for restoring the tab after quitting.
    var queryText: String { textView.string }
    var selection: NSRange {
        get { textView.selectedRange() }
        set {
            let length = (textView.string as NSString).length
            let location = min(newValue.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(newValue.length, length - location)))
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private let split = NSSplitView()
    private let outerSplit = NSSplitView()
    private lazy var sidebar = TablesSidebar(session: session)
    private let textView: SQLTextView
    private let editorScroll: NSScrollView
    private lazy var ruler = LineNumberRuler(textView: textView)
    private lazy var completion = SQLCompletion(textView: textView)
    private var resignObserver: NSObjectProtocol?
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

        editorScroll.verticalRulerView = ruler
        editorScroll.hasVerticalRuler = true
        editorScroll.rulersVisible = true
        editorScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: editorScroll.contentView,
                                               queue: .main) { [weak self] _ in
            self?.ruler.needsDisplay = true
            self?.completion.hide()
        }
        textView.onTyped = { [weak self] text in self?.completion.typed(text) }
        textView.onComplete = { [weak self] in self?.completion.show() }
        textView.onDismissCompletion = { [weak self] in self?.completion.hide() }

        overlay.install(in: resultsContainer)
        overlay.onCancel = { [weak self] in self?.stopQuery(nil) }
        showPlaceholder("Press ⌘↩ to run the query under the cursor. Every open file is a table (see the list on the left).\nDrop more Parquet, CSV, JSON or Excel files on the list or the editor to join them; press Space on a table to preview it.")

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
        if let window = view.window, resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                    queue: .main) { [weak self] _ in self?.completion.hide() }
        }
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
        completion.hide()
        let all = textView.string as NSString
        let selection = textView.selectedRange()
        let range: NSRange
        if selection.length > 0 {
            range = selection
        } else if let statement = SQLLexer.statement(at: selection.location, tokens: textView.tokens, length: all.length) {
            range = statement
            // Several statements in the editor: flash the one that runs.
            if SQLLexer.statements(textView.tokens, length: all.length).filter({ $0.code != nil }).count > 1 {
                textView.showFindIndicator(for: statement)
            }
        } else {
            NSSound.beep()
            return
        }
        let text = all.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        textView.errorRange = nil
        ruler.errorLine = nil

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
                markError(error.localizedDescription, ran: range)
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

    /// Underlines the place DuckDB points at ("LINE 2: …" and a caret under it) and puts the cursor there.
    private func markError(_ message: String, ran range: NSRange) {
        let all = textView.string as NSString
        guard NSMaxRange(range) <= all.length,
              let offset = Self.errorOffset(message, in: all.substring(with: range)) else { return }
        let position = min(range.location + offset, all.length)
        let tokens = textView.tokens.filter { $0.kind != .comment }
        let token = tokens.first { $0.range.location <= position && position < NSMaxRange($0.range) }
            ?? tokens.last { $0.range.location < position }
        textView.errorRange = token?.range
        ruler.errorLine = all.substring(to: position).reduce(into: 1) { count, c in if c == "\n" { count += 1 } }
        textView.setSelectedRange(NSRange(location: position, length: 0))
        textView.scrollRangeToVisible(NSRange(location: position, length: 0))
        view.window?.makeFirstResponder(textView)
    }

    /// Offset (UTF-16) of the error in the statement that ran. DuckDB prints the line with the error
    /// (shortened with "..." if long) and a caret under the spot; the line number may count the line
    /// QuerySession wraps the statement in, so the line is found by its text.
    static func errorOffset(_ message: String, in statement: String) -> Int? {
        let lines = message.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("LINE ") }), index + 1 < lines.count,
              let colon = lines[index].range(of: ": "),
              let number = Int(lines[index].dropFirst(5).prefix { $0.isNumber }),
              let caret = lines[index + 1].firstIndex(of: "^") else { return nil }
        var column = lines[index + 1].distance(from: lines[index + 1].startIndex, to: caret)
            - lines[index].distance(from: lines[index].startIndex, to: colon.upperBound)
        var snippet = String(lines[index][colon.upperBound...])
        if snippet.hasPrefix("...") { snippet.removeFirst(3); column -= 3 }
        if snippet.hasSuffix("...") { snippet.removeLast(3) }
        guard column >= 0 else { return nil }

        let statementLines = statement.components(separatedBy: "\n")
        var starts: [Int] = []
        var start = 0
        for line in statementLines {
            starts.append(start)
            start += line.utf16.count + 1
        }
        for candidate in [number - 1, number - 2, number] where statementLines.indices.contains(candidate) {
            let line = statementLines[candidate]
            let found = snippet.isEmpty ? line.startIndex..<line.startIndex : line.range(of: snippet)
            guard let found else { continue }
            let snippetStart = line.utf16.distance(from: line.utf16.startIndex, to: found.lowerBound)
            return starts[candidate] + snippetStart + String(snippet.prefix(column)).utf16.count
        }
        return nil
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
    func textViewDidChangeSelection(_ notification: Notification) {
        onTextChange?()
        ruler.needsDisplay = true
        completion.selectionChanged()
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?()
        ruler.errorLine = nil
        ruler.updateThickness()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if completion.handle(commandSelector) { return true }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            // Tab: shift a multi-line selection, else jump to the next template placeholder, else indent.
            if self.textView.selectionSpansLines {
                self.textView.indentLines(nil)
            } else if !selectNextPlaceholder() {
                self.textView.insertSoftTab()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if isRunning { stopQuery(nil) } else { completion.show() }
            return true
        default:
            return false
        }
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
