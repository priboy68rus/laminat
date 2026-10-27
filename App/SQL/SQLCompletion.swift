import AppKit

/// One suggestion in the completion list.
struct CompletionItem {
    enum Kind: Int {
        case column, table, schema, function, keyword

        var badge: String { ["C", "T", "W", "F", "K"][rawValue] }
        var color: NSColor { [.systemTeal, .systemOrange, .systemGreen, .systemPurple, .systemGray][rawValue] }
    }

    let kind: Kind
    /// Shown and matched against the typed prefix.
    let name: String
    /// What is inserted (quoted if needed; `(` `)` for functions).
    let insert: String
    /// Type, table or signature, shown dimmed on the right.
    let detail: String
}

/// Completion as you type (docs/IDEAS.md → SQL-редактор): tables after `from` / `join`, columns after
/// `t1.` or `sales.`, otherwise the columns of the statement's tables, DuckDB functions and keywords.
final class SQLCompletion {
    private let textView: SQLTextView
    private let popup = CompletionPopup()
    /// Opened with ⎋ / ⌃Space: stays open with an empty prefix.
    private var explicit = false
    private var replaceRange = NSRange(location: 0, length: 0)

    var isVisible: Bool { popup.isVisible }

    init(textView: SQLTextView) {
        self.textView = textView
        popup.onAccept = { [weak self] item in self?.accept(item) }
    }

    /// After typing: letters, digits, `_` and `.` keep the list going; anything else closes it.
    func typed(_ text: String) {
        let continues = text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." }
        if continues { update() } else { hide() }
    }

    func show() {
        explicit = true
        update()
    }

    func hide() {
        explicit = false
        popup.hide()
    }

    /// The cursor moved: refresh the list if it is open.
    func selectionChanged() {
        if isVisible { update() }
    }

    /// Popup keys. Returns true if the command was handled.
    func handle(_ command: Selector) -> Bool {
        guard isVisible else { return false }
        switch command {
        case #selector(NSResponder.moveUp(_:)): popup.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): popup.moveSelection(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): popup.moveSelection(by: -8)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): popup.moveSelection(by: 8)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard let item = popup.selectedItem else { return false }
            accept(item)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func update() {
        guard textView.selectedRange().length == 0, let context = context() else { hide(); return }
        let items = suggestions(for: context)
        // Nothing to offer, or a keyword / the only match is already typed out: don't swallow Return.
        let typedOut = items.first?.name.caseInsensitiveCompare(context.prefix) == .orderedSame
            && (items.count == 1 || items.first?.kind == .keyword)
        if items.isEmpty || (!explicit && ((context.prefix.isEmpty && context.qualifier == nil) || typedOut)) {
            popup.hide()
            if items.isEmpty { explicit = false }
            return
        }
        replaceRange = context.replaceRange
        guard let window = textView.window else { return }
        var caret = textView.firstRect(forCharacterRange: NSRange(location: context.replaceRange.location, length: 0), actualRange: nil)
        if caret.height == 0 { caret.size.height = 16 }
        popup.show(items, under: caret, in: window, preselect: !context.afterName || explicit)
    }

    private func accept(_ item: CompletionItem) {
        let range = replaceRange
        let text = item.insert
        guard NSMaxRange(range) <= (textView.string as NSString).length else { hide(); return }
        // As typing, so Undo leaves the cursor instead of selecting the word.
        textView.insertText(text, replacementRange: range)
        // A function puts the cursor between its brackets.
        let end = range.location + text.utf16.count - (item.kind == .function ? 1 : 0)
        textView.setSelectedRange(NSRange(location: end, length: 0))
        hide()
        if item.kind == .schema { show() }  // `sales.` → its sheets
    }

    // MARK: Context

    struct Context {
        let replaceRange: NSRange
        let prefix: String
        /// The name before a `.`: a table, alias or workbook.
        let qualifier: String?
        let wantsTables: Bool
        /// Right after a name, where an alias usually goes (`from orders o`, `count(*) n`): only keywords,
        /// none preselected, so Return still makes a new line.
        let afterName: Bool
        /// Tables of the statement by every name they go by (alias, name, `t1`).
        let referenced: [String: Catalog.TableEntry]
        let referencedInOrder: [Catalog.TableEntry]
    }

    private func context() -> Context? {
        let cursor = textView.selectedRange().location
        let tokens = textView.tokens
        if tokens.contains(where: { $0.contains(cursor: cursor) }) { return nil }
        if tokens.contains(where: { $0.kind == .number && $0.range.location < cursor && cursor <= NSMaxRange($0.range) }) { return nil }

        var replaceRange = NSRange(location: cursor, length: 0)
        var prefix = ""
        if let word = tokens.first(where: { $0.kind == .word && $0.range.location < cursor && cursor <= NSMaxRange($0.range) }) {
            replaceRange = NSRange(location: word.range.location, length: cursor - word.range.location)
            prefix = (textView.string as NSString).substring(with: replaceRange)
        }

        // The statement around the cursor, without comments.
        let code = tokens.filter { $0.kind != .comment }
        let before = code.filter { NSMaxRange($0.range) <= replaceRange.location }
        let statementStart = before.lastIndex { $0.isSymbol(";") }.map { before[$0].range.location + 1 } ?? 0
        let statementEnd = code.first { $0.isSymbol(";") && $0.range.location >= cursor }?.range.location ?? Int.max
        let statement = code.filter { $0.range.location >= statementStart && $0.range.location < statementEnd }
        let prior = before.filter { $0.range.location >= statementStart }

        var qualifier: String?
        if let dot = prior.last, dot.isSymbol("."), NSMaxRange(dot.range) == replaceRange.location, prior.count >= 2 {
            let name = prior[prior.count - 2]
            if name.kind == .word || name.kind == .quotedIdentifier, NSMaxRange(name.range) == dot.range.location {
                qualifier = Self.unquote(name)
            }
        }

        var wantsTables = false
        if qualifier == nil, let last = prior.last {
            let tableKeywords: Set = ["from", "join", "describe", "summarize", "table", "into"]
            if last.kind == .word, tableKeywords.contains(last.lowercased) {
                wantsTables = true
            } else if last.isSymbol(",") {
                let clause = prior.last { $0.kind == .word && Self.clauseWords.contains($0.lowercased) }
                wantsTables = clause?.lowercased == "from"
            }
        }

        var afterName = false
        if qualifier == nil, !wantsTables, let last = prior.last {
            if last.kind == .word, last.lowercased == "as" { return nil }
            let isName = (last.kind == .word && !SQLHighlighter.keywordSet.contains(last.text.uppercased()))
                || last.kind == .quotedIdentifier || last.isSymbol(")")
            afterName = isName && NSMaxRange(last.range) < replaceRange.location
        }

        let (byName, inOrder) = referencedTables(in: statement)
        return Context(replaceRange: replaceRange, prefix: prefix, qualifier: qualifier, wantsTables: wantsTables,
                       afterName: afterName, referenced: byName, referencedInOrder: inOrder)
    }

    private static let clauseWords: Set = ["select", "from", "where", "group", "order", "having", "limit", "on", "join",
                                           "qualify", "window", "using", "set", "values"]

    private static func unquote(_ token: SQLToken) -> String {
        guard token.kind == .quotedIdentifier else { return token.text }
        var text = token.text.dropFirst()
        if token.closed { text = text.dropLast() }
        return text.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// Tables after `from` / `join` (and commas in `from`), with their aliases.
    private func referencedTables(in statement: [SQLToken]) -> ([String: Catalog.TableEntry], [Catalog.TableEntry]) {
        var byName: [String: Catalog.TableEntry] = [:]
        var inOrder: [Catalog.TableEntry] = []
        var i = 0
        var inFrom = false
        while i < statement.count {
            let token = statement[i]
            let word = token.kind == .word ? token.lowercased : ""
            if Self.clauseWords.contains(word) && word != "join" { inFrom = word == "from" }
            let startsReference = word == "from" || word == "join" || (inFrom && token.isSymbol(","))
            i += 1
            guard startsReference, i < statement.count else { continue }

            // name or schema.name
            var parts: [String] = []
            while i < statement.count, statement[i].kind == .word || statement[i].kind == .quotedIdentifier {
                parts.append(Self.unquote(statement[i]))
                i += 1
                if i < statement.count, statement[i].isSymbol(".") { i += 1 } else { break }
            }
            guard !parts.isEmpty, let entry = Self.resolve(parts) else { continue }
            if !inOrder.contains(where: { $0.alias == entry.alias }) { inOrder.append(entry) }
            for name in [entry.alias, entry.table, entry.name] { byName[name.lowercased()] = entry }
            // Optional `as` and an alias that isn't a keyword.
            if i < statement.count, statement[i].kind == .word, statement[i].lowercased == "as" { i += 1 }
            if i < statement.count, statement[i].kind == .word || statement[i].kind == .quotedIdentifier,
               !SQLHighlighter.keywordSet.contains(statement[i].text.uppercased()) {
                byName[Self.unquote(statement[i]).lowercased()] = entry
                i += 1
            }
        }
        return (byName, inOrder)
    }

    /// A table by its SQL name: `t1`, `orders`, `sales.Orders`.
    private static func resolve(_ parts: [String]) -> Catalog.TableEntry? {
        let tables = Catalog.shared.tables
        if parts.count >= 2 {
            let schema = parts[parts.count - 2].lowercased(), table = parts[parts.count - 1].lowercased()
            return tables.first { $0.schema?.lowercased() == schema && $0.table.lowercased() == table }
        }
        let name = parts[0].lowercased()
        return tables.first { $0.alias.lowercased() == name }
            ?? tables.first { $0.schema == nil && $0.table.lowercased() == name }
    }

    // MARK: Suggestions

    private func suggestions(for context: Context) -> [CompletionItem] {
        let tables = Catalog.shared.tables
        var items: [CompletionItem] = []

        func columns(of entry: Catalog.TableEntry, showTable: Bool) -> [CompletionItem] {
            entry.columns.map {
                CompletionItem(kind: .column, name: $0.name, insert: Catalog.sqlName($0.name),
                               detail: showTable ? "\($0.type.lowercased()) · \(entry.name)" : $0.type.lowercased())
            }
        }

        func tableItems() -> [CompletionItem] {
            var result: [CompletionItem] = []
            var schemas: [String] = []
            for entry in tables {
                let rows = "\(entry.alias) · \(entry.rowCount.formatted()) rows"
                if let schema = entry.schema {
                    if !schemas.contains(schema) {
                        schemas.append(schema)
                        let sheets = tables.filter { $0.schema == schema }.count
                        result.append(CompletionItem(kind: .schema, name: schema, insert: Catalog.sqlName(schema) + ".",
                                                     detail: "workbook · \(sheets) sheets"))
                    }
                }
                result.append(CompletionItem(kind: .table, name: entry.name, insert: entry.sqlName, detail: rows))
            }
            for entry in tables {
                result.append(CompletionItem(kind: .table, name: entry.alias, insert: entry.alias, detail: entry.name))
            }
            return result
        }

        if let qualifier = context.qualifier?.lowercased() {
            let sheets = tables.filter { $0.schema?.lowercased() == qualifier }
            if !sheets.isEmpty {
                items = sheets.map { CompletionItem(kind: .table, name: $0.table, insert: Catalog.sqlName($0.table),
                                                    detail: "\($0.alias) · \($0.rowCount.formatted()) rows") }
            } else if let entry = context.referenced[qualifier] ?? Self.resolve([qualifier]) {
                items = columns(of: entry, showTable: false)
            }
        } else if context.wantsTables {
            items = tableItems()
        } else if context.afterName {
            items = SQLHighlighter.keywords.map {
                CompletionItem(kind: .keyword, name: $0.lowercased(), insert: $0.lowercased(), detail: "")
            }
        } else {
            let source = context.referencedInOrder.isEmpty ? tables : context.referencedInOrder
            items = source.flatMap { columns(of: $0, showTable: source.count > 1) }
            let uppercase = !context.prefix.isEmpty && context.prefix == context.prefix.uppercased()
                && context.prefix.contains { $0.isLetter }
            items += Self.functions
            items += SQLHighlighter.keywords.map {
                let word = uppercase ? $0 : $0.lowercased()
                return CompletionItem(kind: .keyword, name: word, insert: word, detail: "")
            }
            items += tableItems()
        }
        return Self.rank(items, prefix: context.prefix)
    }

    /// Prefix matches first, then matches at a word part (`id` → `user_id`), then anywhere (2+ letters).
    /// Within a group the original order is kept: columns in table order, then functions, keywords, tables.
    private static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        let prefix = prefix.lowercased()
        var seen = Set<String>()
        var scored: [(score: Int, index: Int, item: CompletionItem)] = []
        for (index, item) in items.enumerated() {
            let name = item.name.lowercased()
            let score: Int
            if !prefix.isEmpty, name == prefix {
                score = -1
            } else if prefix.isEmpty || name.hasPrefix(prefix) {
                score = 0
            } else if name.split(separator: "_").dropFirst().contains(where: { $0.hasPrefix(prefix) }) {
                score = 1
            } else if prefix.count >= 2, name.contains(prefix) {
                score = 2
            } else {
                continue
            }
            guard seen.insert("\(item.kind.rawValue)|\(item.insert)").inserted else { continue }
            scored.append((score, index, item))
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.prefix(200).map(\.item)
    }

    /// DuckDB's functions with the shortest signature of each, read once from `duckdb_functions()`.
    private static let functions: [CompletionItem] = {
        let sql = """
            select
                function_name,
                function_type,
                array_to_string(parameters, ', '),
                coalesce(return_type, '')
            from
                duckdb_functions()
            where 1=1
                and function_type in ('scalar', 'aggregate', 'macro', 'table', 'table_macro')
                and regexp_matches(function_name, '^[a-z][a-z0-9_]*$')
            order by
                function_name,
                len(parameters)
            """
        guard let rows = try? Connection(Catalog.shared.database).query(sql).readStrings() else { return [] }
        var items: [CompletionItem] = []
        var last = ""
        for row in rows {
            guard let name = row[0], name != last else { continue }
            last = name
            let type = row[1] ?? ""
            let returns = (row[3] ?? "").isEmpty ? "" : " → \(row[3]!.lowercased())"
            let kind = type == "aggregate" ? "aggregate " : type.hasPrefix("table") ? "table " : ""
            items.append(CompletionItem(kind: .function, name: name, insert: name + "()",
                                        detail: "\(kind)(\(row[2] ?? ""))\(returns)"))
        }
        return items
    }()
}

// MARK: - Popup

/// The completion list: a borderless child panel under the cursor. It never takes focus; the editor
/// forwards ↑ ↓ Return Tab ⎋ to it.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 20
    private static let width: CGFloat = 480

    private let panel: NSPanel
    private let table = PopupTableView()
    private var items: [CompletionItem] = []
    var onAccept: ((CompletionItem) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var selectedItem: CompletionItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    /// Shows `items` under `caret` (screen coordinates), or above it if there's no room below.
    func show(_ items: [CompletionItem], under caret: NSRect, in window: NSWindow, preselect: Bool) {
        self.items = items
        table.reloadData()
        if preselect {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        table.scrollRowToVisible(0)

        let height = CGFloat(min(items.count, 10)) * Self.rowHeight + 8
        var frame = NSRect(x: caret.minX - 28, y: caret.minY - height - 2, width: Self.width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = caret.maxY + 2 }
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = table.selectedRow < 0 && delta > 0 ? -1 : table.selectedRow
        let row = min(max(current + delta, 0), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        onAccept?(items[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.show(items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }
}

/// Clicks land without making the panel key, so the editor keeps focus.
private final class PopupTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel is never key; keep the selection in the accent colour anyway.
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")

    private let badge = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var kindColor = NSColor.systemGray

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [badge, name, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 15),
            badge.heightAnchor.constraint(equalToConstant: 15),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: CompletionItem) {
        badge.stringValue = item.kind.badge
        kindColor = item.kind.color
        name.stringValue = item.name
        detail.stringValue = item.detail
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        badge.textColor = .white
        badge.layer?.backgroundColor = kindColor.cgColor
        name.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}
