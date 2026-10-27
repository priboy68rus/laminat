import AppKit

/// The SQL editor's text view. Editing follows VS Code (see docs/IDEAS.md → SQL-редактор): soft tabs,
/// auto-indent, paired brackets and quotes, line commands (⌘/, ⌥↑ / ⌥↓, ⇧⌘K…), highlighting of the
/// matching bracket and of other occurrences of the word under the cursor.
///
/// Dropping data files from Finder hands them to `onDropFiles` (which adds them as tables, possibly
/// loading in the background) and inserts the table names it reports back at the drop point.
final class SQLTextView: NSTextView, NSTextStorageDelegate {
    static let indentUnit = "    "

    var onDropFiles: ((_ urls: [URL], _ insertNames: @escaping (String) -> Void) -> Void)?
    /// The user typed `text` (not a paste or undo); completion follows typing.
    var onTyped: ((_ text: String) -> Void)?
    /// ⎋, F5, ⌃Space: show completions.
    var onComplete: (() -> Void)?
    /// A click or losing focus: hide completions.
    var onDismissCompletion: (() -> Void)?

    static func makeScrollable() -> (NSScrollView, SQLTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        // TextKit 1: the line number ruler and the highlights work with the layout manager.
        let textView = SQLTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.delegate = textView
        scroll.documentView = textView
        return (scroll, textView)
    }

    // MARK: Tokens

    private var cachedTokens: [SQLToken]?

    /// Tokens of the whole text, cached until the next edit.
    var tokens: [SQLToken] {
        if let cachedTokens { return cachedTokens }
        let tokens = SQLLexer.tokens(string)
        cachedTokens = tokens
        return tokens
    }

    /// True if the cursor position is inside a string or a comment.
    func isInStringOrComment(_ position: Int) -> Bool {
        tokens.contains { $0.contains(cursor: position) }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        cachedTokens = nil
        SQLHighlighter.apply(to: textStorage, editedRange: editedRange)
        // The layout manager hasn't caught up with the edit yet; redo the marks afterwards.
        DispatchQueue.main.async { [weak self] in
            self?.errorRange = nil
            self?.updateMarks()
        }
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = (string as? String) ?? (string as? NSAttributedString)?.string,
              replacementRange.location == NSNotFound, !hasMarkedText() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if !insertPaired(text) {
            if text == ")" || text == "]" { reindentLine(closing: text) }
            super.insertText(text, replacementRange: replacementRange)
            if text == " " { reindentLine(closing: nil, justTyped: true) }
        }
        onTyped?(text)
    }

    /// Brackets and quotes come in pairs: typing an opening one inserts both (or wraps the selection),
    /// typing the closing one in front of an existing one just steps over it.
    private func insertPaired(_ text: String) -> Bool {
        let pairs = ["(": ")", "[": "]", "'": "'", "\"": "\""]
        let ns = string as NSString
        let selection = selectedRange()
        let next = NSMaxRange(selection) < ns.length ? ns.character(at: NSMaxRange(selection)) : 0
        let previous = selection.location > 0 ? ns.character(at: selection.location - 1) : 0
        let isQuote = text == "'" || text == "\""

        if let close = pairs[text], selection.length > 0 {
            let selected = ns.substring(with: selection)
            typeText(selection, with: text + selected + close,
                    select: NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        guard selection.length == 0, text.utf16.count == 1 else { return false }
        // A closing quote only steps over the one that ends the string the cursor is in.
        if pairs.values.contains(text), next == text.utf16.first, !isQuote || isInStringOrComment(selection.location) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }
        guard let close = pairs[text], !isInStringOrComment(selection.location) else { return false }
        let nextAllows = next == 0 || " \t\n),];".utf16.contains(next)
        let previousAllows = !isQuote || (!isWordCharacter(previous) && previous != text.utf16.first)
        guard nextAllows, previousAllows else { return false }
        super.insertText(text + close, replacementRange: NSRange(location: NSNotFound, length: 0))
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        return true
    }

    private func isWordCharacter(_ c: unichar) -> Bool {
        c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127
    }

    /// Return keeps the line's indent and adds a level after a clause keyword, `join`, `case` or `(`;
    /// between `(` and `)` it puts the closing bracket on its own line.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        reindentLine(closing: nil)
        let ns = string as NSString
        let selection = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let newIndent = indent + (Self.opensBlock(trimmed) ? Self.indentUnit : "")
        let next = NSMaxRange(selection) < ns.length ? ns.character(at: NSMaxRange(selection)) : 0

        if trimmed.hasSuffix("("), next == 41 {  // ")"
            let text = "\n" + newIndent + "\n" + indent
            typeText(selection, with: text, select: NSRange(location: selection.location + 1 + newIndent.utf16.count, length: 0))
            return
        }
        // A line of only spaces doesn't keep them.
        var range = selection
        if trimmed.isEmpty, !before.isEmpty {
            range = NSRange(location: lineStart, length: NSMaxRange(selection) - lineStart)
        }
        let text = "\n" + newIndent
        typeText(range, with: text, select: NSRange(location: range.location + text.utf16.count, length: 0))
    }

    private static let clauseKeywords: Set<String> = [
        "select", "from", "where", "having", "qualify", "window", "with", "group", "order", "limit", "offset",
        "union", "except", "intersect", "values",
    ]
    private static let joinWords: Set<String> = [
        "join", "inner", "left", "right", "full", "outer", "cross", "semi", "anti", "asof", "natural", "positional",
    ]

    /// Whether the line (trimmed) is followed by an indented block.
    static func opensBlock(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasSuffix("(") { return true }
        let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        guard let first = words.first else { return false }
        if ["select", "from", "where", "having", "qualify", "window", "with"].contains(first) { return true }
        if ["group", "order", "partition"].contains(first), words.count > 1, words[1] == "by" { return true }
        if joinWords.contains(first), words.contains("join") { return true }
        return words.last == "case"
    }

    /// Moves a line that starts with a clause keyword (`from`, `where`…), `end` or a closing bracket back
    /// to the indent of the clause, `case` or bracket it belongs to. `closing` is the bracket being typed
    /// on an otherwise empty line; nil checks the line's first word (`justTyped`: only right after typing
    /// it, so a line indented by hand later stays put).
    private func reindentLine(closing: String?, justTyped: Bool = false) {
        let ns = string as NSString
        let cursor = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let rest = before.dropFirst(indent.count)
        guard !isInStringOrComment(cursor) else { return }

        let target: String?
        if let closing {
            guard rest.isEmpty else { return }
            target = bracketIndent(before: lineStart, closing: closing)
        } else {
            let word = rest.prefix { $0.isLetter }.lowercased()
            guard !word.isEmpty, rest.count == word.count || rest.dropFirst(word.count).first?.isLetter == false else { return }
            if justTyped, rest != word + " " { return }
            if word == "end" {
                target = caseIndent(before: lineStart)
            } else if Self.clauseKeywords.contains(word), word != "select", word != "with" {
                target = clauseIndent(before: lineStart)
            } else {
                return
            }
        }
        guard let target, target != indent else { return }
        let delta = target.utf16.count - indent.utf16.count
        typeText(NSRange(location: lineStart, length: indent.utf16.count), with: target,
                select: NSRange(location: cursor + delta, length: 0))
    }

    /// Code tokens of the current statement before `position`.
    private func statementTokens(before position: Int) -> ArraySlice<SQLToken> {
        let all = tokens.filter { $0.kind != .comment && $0.range.location < position }
        let start = all.lastIndex { $0.isSymbol(";") }.map { $0 + 1 } ?? 0
        return all[start...]
    }

    private func indent(ofLineAt position: Int) -> String {
        let ns = string as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: position, length: 0)))
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private func isFirstOnLine(_ token: SQLToken) -> Bool {
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: token.range.location, length: 0)).location
        return ns.substring(with: NSRange(location: lineStart, length: token.range.location - lineStart))
            .allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Indent of the clause a new clause keyword belongs with: the last clause keyword that starts a line
    /// at the same bracket depth, else one level in from the open bracket.
    private func clauseIndent(before position: Int) -> String? {
        var open: [SQLToken] = []
        var clauses: [(depth: Int, token: SQLToken)] = []
        for token in statementTokens(before: position) {
            if token.isSymbol("(") { open.append(token) }
            if token.isSymbol(")") {
                clauses.removeAll { $0.depth == open.count }
                _ = open.popLast()
            }
            if token.kind == .word, Self.clauseKeywords.contains(token.lowercased), isFirstOnLine(token) {
                clauses.append((open.count, token))
            }
        }
        if let clause = clauses.last(where: { $0.depth == open.count }) {
            return indent(ofLineAt: clause.token.range.location)
        }
        return open.last.map { indent(ofLineAt: $0.range.location) + Self.indentUnit } ?? (open.isEmpty ? "" : nil)
    }

    private func caseIndent(before position: Int) -> String? {
        var depth = 0
        for token in statementTokens(before: position).reversed() where token.kind == .word {
            switch token.lowercased {
            case "end": depth += 1
            case "case":
                if depth == 0 { return indent(ofLineAt: token.range.location) }
                depth -= 1
            default: break
            }
        }
        return nil
    }

    private func bracketIndent(before position: Int, closing: String) -> String? {
        let opening = closing == ")" ? "(" : "["
        var depth = 0
        for token in statementTokens(before: position).reversed() where token.kind == .symbol {
            if token.text == closing { depth += 1 }
            if token.text == opening {
                if depth == 0 { return indent(ofLineAt: token.range.location) }
                depth -= 1
            }
        }
        return nil
    }

    /// Backspace removes both brackets of an empty pair, and in the indent goes back to the previous
    /// tab stop.
    override func deleteBackward(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0, !hasMarkedText() else { super.deleteBackward(sender); return }
        let cursor = selection.location
        let previous = ns.character(at: cursor - 1)
        let next = cursor < ns.length ? ns.character(at: cursor) : 0
        let pairs: [unichar: unichar] = [40: 41, 91: 93, 39: 39, 34: 34]
        if pairs[previous] == next, next != 0, !(previous == 39 && isInStringOrComment(cursor - 1)) {
            typeText(NSRange(location: cursor - 1, length: 2), with: "", select: NSRange(location: cursor - 1, length: 0))
            return
        }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let column = cursor - lineStart
        if column > 0, ns.substring(with: NSRange(location: lineStart, length: column)).allSatisfy({ $0 == " " }) {
            let unit = Self.indentUnit.utf16.count
            let remove = column % unit == 0 ? unit : column % unit
            typeText(NSRange(location: cursor - remove, length: remove), with: "",
                    select: NSRange(location: cursor - remove, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    /// Tab without a multi-line selection: spaces up to the next tab stop.
    func insertSoftTab() {
        let ns = string as NSString
        let selection = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let unit = Self.indentUnit.utf16.count
        let spaces = String(repeating: " ", count: unit - (selection.location - lineStart) % unit)
        typeText(selection, with: spaces, select: NSRange(location: selection.location + spaces.utf16.count, length: 0))
    }

    var selectionSpansLines: Bool {
        (string as NSString).substring(with: selectedRange()).contains("\n")
    }

    // MARK: Line commands

    /// Full lines touched by the selection; a selection that ends at the start of a line leaves it out.
    private func selectedLineRange() -> NSRange {
        let ns = string as NSString
        var selection = selectedRange()
        if selection.length > 0, ns.character(at: NSMaxRange(selection) - 1) == 10 { selection.length -= 1 }
        return ns.lineRange(for: selection)
    }

    /// An edit made while typing (auto-indent, pairs, Return…) goes through the normal typing path, so
    /// Undo treats it like typed text and leaves just the cursor, not a selection.
    private func typeText(_ range: NSRange, with text: String, select: NSRange) {
        super.insertText(text, replacementRange: range)
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    /// A command's edit (⌘/, ⌥↑…) as its own undo step. Undo and Redo leave just the cursor where it was
    /// (the end of the selection before / after the command) instead of selecting the changed text.
    private func replace(_ range: NSRange, with text: String, select: NSRange, actionName: String) {
        guard isEditable else { return }
        // Registered before the text change, so Undo runs it after the text is restored.
        restoreCursor(NSMaxRange(selectedRange()), next: NSMaxRange(select))
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        undoManager?.setActionName(actionName)
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    private func restoreCursor(_ location: Int, next: Int) {
        undoManager?.registerUndo(withTarget: self) { textView in
            textView.restoreCursor(next, next: location)
            let place = { [weak textView] in
                guard let textView else { return }
                let cursor = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
                if textView.selectedRange() != cursor { textView.setSelectedRange(cursor) }
                textView.scrollRangeToVisible(cursor)
            }
            place()
            // In case the text system sets its own selection after this step.
            DispatchQueue.main.async(execute: place)
        }
    }

    /// Rewrites the selected lines in one undoable step. The cursor stays on its line; a selection grows
    /// to cover the whole changed lines.
    private func transformLines(_ actionName: String, _ transform: ([String]) -> [String]) {
        let ns = string as NSString
        let block = selectedLineRange()
        var text = ns.substring(with: block)
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { text.removeLast() }
        let lines = text.components(separatedBy: "\n")
        var result = transform(lines).joined(separator: "\n")
        let resultLength = result.utf16.count
        if trailingNewline { result += "\n" }

        let selection = selectedRange()
        let newSelection: NSRange
        if selection.length == 0, lines.count == 1 {
            let delta = resultLength - text.utf16.count
            let location = min(max(selection.location + delta, block.location), block.location + resultLength)
            newSelection = NSRange(location: location, length: 0)
        } else {
            newSelection = NSRange(location: block.location, length: resultLength)
        }
        replace(block, with: result, select: newSelection, actionName: actionName)
    }

    private static func leadingWhitespace(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// ⌘/: comments out the lines with `-- `, or removes the comment if every line has one.
    @objc func toggleComment(_ sender: Any?) {
        transformLines("Toggle Comment") { lines in
            let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if code.isEmpty { return lines.map { $0 + "-- " } }
            let commented = code.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            if commented {
                return lines.map { line in
                    guard let range = line.range(of: "--") else { return line }
                    var result = line
                    let after = range.upperBound
                    result.removeSubrange(range.lowerBound..<(after < line.endIndex && line[after] == " " ? line.index(after: after) : after))
                    return result
                }
            }
            let column = code.map(Self.leadingWhitespace).min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let index = line.index(line.startIndex, offsetBy: column)
                return line[..<index] + "-- " + line[index...]
            }
        }
    }

    /// Tab on a multi-line selection, ⌘].
    @objc func indentLines(_ sender: Any?) {
        transformLines("Indent") { lines in lines.map { $0.isEmpty ? $0 : Self.indentUnit + $0 } }
    }

    /// ⇧Tab, ⌘[.
    @objc func outdentLines(_ sender: Any?) {
        transformLines("Outdent") { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(Self.indentUnit.count, line.prefix { $0 == " " }.count)))
            }
        }
    }

    override func insertBacktab(_ sender: Any?) {
        outdentLines(sender)
    }

    /// ⌥↑ / ⌥↓.
    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let ns = string as NSString
        let block = selectedLineRange()
        let selection = selectedRange()
        var blockText = ns.substring(with: block)
        if up {
            guard block.location > 0 else { return }
            let previous = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var previousText = ns.substring(with: previous)
            if !blockText.hasSuffix("\n") { blockText += "\n"; previousText.removeLast() }
            replace(NSUnionRange(previous, block), with: blockText + previousText,
                    select: NSRange(location: selection.location - previous.length, length: selection.length),
                    actionName: "Move Line Up")
        } else {
            guard NSMaxRange(block) < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; blockText.removeLast() }
            replace(NSUnionRange(block, next), with: nextText + blockText,
                    select: NSRange(location: selection.location + nextText.utf16.count, length: selection.length),
                    actionName: "Move Line Down")
        }
    }

    /// ⇧⌥↑ / ⇧⌥↓: duplicate the lines; the cursor goes with the copy below (or stays on the copy above).
    @objc func copyLineUp(_ sender: Any?) { copyLines(up: true) }
    @objc func copyLineDown(_ sender: Any?) { copyLines(up: false) }

    private func copyLines(up: Bool) {
        let ns = string as NSString
        let block = selectedLineRange()
        let selection = selectedRange()
        var blockText = ns.substring(with: block)
        var copy = blockText
        if !blockText.hasSuffix("\n") {
            // Last line without a newline: the copy below needs one in between.
            if up { copy += "\n" } else { blockText += "\n" }
        }
        let text = up ? copy + ns.substring(with: block) : blockText + copy
        let shift = up ? 0 : blockText.utf16.count
        replace(block, with: text, select: NSRange(location: selection.location + shift, length: selection.length),
                actionName: up ? "Copy Line Up" : "Copy Line Down")
    }

    /// ⇧⌘K.
    @objc func deleteLine(_ sender: Any?) {
        let ns = string as NSString
        var block = selectedLineRange()
        let lastLine = NSMaxRange(block) == ns.length && !ns.substring(with: block).hasSuffix("\n")
        if lastLine, block.location > 0 { block = NSRange(location: block.location - 1, length: block.length + 1) }
        let cursor = selectedRange().location
        let column = cursor - ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        replace(block, with: "", select: NSRange(location: block.location, length: 0), actionName: "Delete Line")
        // Keep the column on the line that took its place.
        let remaining = string as NSString
        let line = remaining.lineRange(for: NSRange(location: block.location, length: 0))
        let lineLength = remaining.substring(with: line).trimmingCharacters(in: .newlines).utf16.count
        setSelectedRange(NSRange(location: line.location + min(column, lineLength), length: 0))
    }

    /// ⇧⌥F: formats the selected lines, or the whole text (SQLFormatter). The cursor stays at the same
    /// character: only whitespace changes.
    @objc func formatSQL(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let range = selection.length > 0 ? selectedLineRange() : NSRange(location: 0, length: ns.length)
        let original = ns.substring(with: range)
        let indent = selection.length > 0 ? String(original.prefix { $0 == " " || $0 == "\t" }) : ""
        guard let formatted = SQLFormatter.format(original, indent: indent) else { NSSound.beep(); return }
        guard formatted != original else { return }

        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        let cursor = min(max(selection.location, range.location), NSMaxRange(range))
        let charactersBefore = ns.substring(with: NSRange(location: range.location, length: cursor - range.location))
            .utf16.filter { !isSpace($0) }.count
        var offset = 0
        var seen = 0
        for c in formatted.utf16 {
            if seen == charactersBefore { break }
            if !isSpace(c) { seen += 1 }
            offset += 1
        }
        let select = selection.length > 0
            ? NSRange(location: range.location, length: formatted.utf16.count - (formatted.hasSuffix("\n") ? 1 : 0))
            : NSRange(location: range.location + offset, length: 0)
        replace(range, with: formatted, select: select, actionName: "Format SQL")
    }

    @objc func showCompletions(_ sender: Any?) {
        onComplete?()
    }

    override func complete(_ sender: Any?) {
        onComplete?()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleComment(_:)), #selector(indentLines(_:)), #selector(outdentLines(_:)),
             #selector(moveLineUp(_:)), #selector(moveLineDown(_:)), #selector(copyLineUp(_:)),
             #selector(copyLineDown(_:)), #selector(deleteLine(_:)), #selector(showCompletions(_:)),
             #selector(formatSQL(_:)):
            return isEditable
        default:
            return super.validateMenuItem(item)
        }
    }

    // MARK: Marks

    /// A query error to underline (cleared by the next edit).
    var errorRange: NSRange? {
        didSet {
            guard let layoutManager else { return }
            let full = NSRange(location: 0, length: (string as NSString).length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            if let errorRange, NSMaxRange(errorRange) <= full.length {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.systemRed,
                ], forCharacterRange: errorRange)
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateMarks() }
    }

    /// Highlights the bracket matching the one next to the cursor, and other occurrences of the word under
    /// the cursor (or of the selected word).
    private func updateMarks() {
        guard let layoutManager else { return }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let selection = selectedRange()
        guard NSMaxRange(selection) <= full.length else { return }

        if let word = wordForOccurrences(selection) {
            let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let matches = regex.matches(in: string, range: full)
                if matches.count > 1 {
                    for match in matches {
                        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.textColor.withAlphaComponent(0.12),
                                                            forCharacterRange: match.range)
                    }
                }
            }
        }

        if selection.length == 0 {
            let candidates = [selection.location - 1, selection.location].filter { $0 >= 0 && $0 < full.length }
            for position in candidates where "()[]".utf16.contains(ns.character(at: position)) {
                guard let match = SQLLexer.matchingBracket(at: position, tokens: tokens) else { continue }
                for location in [position, match] {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.25),
                                                        forCharacterRange: NSRange(location: location, length: 1))
                }
                break
            }
        }
    }

    /// The identifier under the cursor or exactly selected, if it's worth highlighting (not a keyword).
    private func wordForOccurrences(_ selection: NSRange) -> String? {
        let token: SQLToken?
        if selection.length > 0 {
            token = tokens.first { $0.range == selection }
        } else {
            token = tokens.first { $0.range.location <= selection.location && selection.location <= NSMaxRange($0.range) && $0.kind == .word }
        }
        guard let token, token.kind == .word, token.range.length >= 2,
              !SQLHighlighter.keywordSet.contains(token.text.uppercased()) else { return nil }
        return token.text
    }

    /// ⇧⌥F by key position, so it works in any keyboard layout (the menu matches the character, which is
    /// not "f" in e.g. the Russian layout).
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if event.keyCode == 3, modifiers == [.option, .shift] {  // kVK_ANSI_F
            formatSQL(nil)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Completion dismissal

    override func mouseDown(with event: NSEvent) {
        onDismissCompletion?()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        onDismissCompletion?()
        return super.resignFirstResponder()
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TablesSidebar.dataFileURLs(from: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)  // moves the insertion point under the mouse
        return TablesSidebar.dataFileURLs(from: sender.draggingPasteboard).isEmpty ? operation : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = TablesSidebar.dataFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        guard let onDropFiles else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        window?.makeFirstResponder(self)
        onDropFiles(urls) { [weak self] text in
            guard let self else { return }
            let location = min(index, (string as NSString).length)
            let range = NSRange(location: location, length: 0)
            if shouldChangeText(in: range, replacementString: text) {
                replaceCharacters(in: range, with: text)
                didChangeText()
                setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
            }
        }
        return true
    }
}
