import Foundation

/// Format SQL (⇧⌥F) in the house style of the user's example.sql: lowercase keywords; every clause keyword
/// on its own line with its contents indented by four spaces, one item per line, commas at the end;
/// `where` keeps its first condition on its line and puts each `and` / `or` on the next; joins one per
/// line with `on` one level deeper; a long `case` gets one `when` per line; subqueries and `in (…)` lists
/// open a block that closes with `)` back at the line's indent.
///
/// Only whitespace and the case of keywords change, never the tokens; `format` returns nil if that check
/// fails, so a formatter bug can't corrupt a query. Statements other than queries are left as they are.
enum SQLFormatter {
    static func format(_ text: String, indent baseIndent: String = "") -> String? {
        let source = text as NSString
        let tokens = SQLLexer.tokens(text)
        guard !tokens.isEmpty else { return text }
        let writer = Writer(source: source)

        var start = 0
        while start < tokens.count {
            var end = start
            while end < tokens.count, !tokens[end].isSymbol(";") { end += 1 }
            var statement = Array(tokens[start..<end])
            // A comment right after the previous `;` on the same line stays there.
            while let comment = statement.first, comment.kind == .comment, writer.followsOnSameLine(comment) {
                writer.write(comment)
                statement.removeFirst()
            }
            if !statement.isEmpty {
                if !writer.isEmpty { writer.blankLine() }
                Formatter(tokens: statement, writer: writer).formatStatement()
            }
            if end < tokens.count { writer.semicolon(tokens[end]) }
            start = end + 1
        }

        var result = writer.lines(indent: baseIndent).joined(separator: "\n")
        if text.hasSuffix("\n") { result += "\n" }
        func squeezed(_ string: String) -> String { string.filter { !$0.isWhitespace }.lowercased() }
        return squeezed(result) == squeezed(text) ? result : nil
    }
}

// MARK: - Writer

/// Builds the output line by line and decides the spacing between tokens on a line.
private final class Writer {
    private let source: NSString
    private var finished: [(indent: Int, text: String, endsWithLineComment: Bool)] = []
    private var current = ""
    private(set) var indent = 0
    private var previous: SQLToken?

    init(source: NSString) { self.source = source }

    var isEmpty: Bool { finished.isEmpty && current.isEmpty }
    var lineIsEmpty: Bool { current.isEmpty }

    func lines(indent base: String) -> [String] {
        flush()
        return finished.map { $0.text.isEmpty ? "" : base + String(repeating: SQLTextView.indentUnit, count: $0.indent) + $0.text }
    }

    /// Starts a new line at `indent` (an empty current line just changes its indent).
    func newline(_ indent: Int) {
        flush()
        self.indent = indent
    }

    func blankLine() {
        flush()
        finished.append((0, "", false))
    }

    private func flush(lineComment: Bool = false) {
        guard !current.isEmpty else { return }
        finished.append((indent, current, lineComment))
        current = ""
    }

    func followsOnSameLine(_ token: SQLToken) -> Bool {
        guard let previous else { return false }
        return !hasNewline(from: previous, to: token)
    }

    private func hasNewline(from a: SQLToken, to b: SQLToken) -> Bool {
        let start = NSMaxRange(a.range)
        guard b.range.location > start else { return false }
        return source.substring(with: NSRange(location: start, length: b.range.location - start)).contains("\n")
    }

    func write(_ token: SQLToken) {
        if token.kind == .comment { comment(token); return }
        let text = Self.display(token)
        if !current.isEmpty, let previous, Self.needsSpace(previous, token, source: source) { current += " " }
        current += text
        previous = token
    }

    /// A comment on its own line in the source keeps its own line; one after code stays after it.
    private func comment(_ token: SQLToken) {
        let isLine = token.text.hasPrefix("--")
        let ownLine = previous == nil || hasNewline(from: previous!, to: token)
        defer { previous = token }
        if ownLine {
            flush()
            current = token.text
            flush(lineComment: isLine)
        } else if current.isEmpty, let last = finished.indices.last, !finished[last].text.isEmpty, !finished[last].endsWithLineComment {
            finished[last].text += " " + token.text
            finished[last].endsWithLineComment = isLine
        } else {
            current += (current.isEmpty ? "" : " ") + token.text
            if isLine { flush(lineComment: true) }
        }
    }

    func semicolon(_ token: SQLToken) {
        defer { previous = token }
        if !current.isEmpty { current += ";"; return }
        if let last = finished.indices.last, !finished[last].text.isEmpty, !finished[last].endsWithLineComment {
            finished[last].text += ";"
        } else {
            finished.append((0, ";", false))
        }
    }

    static func display(_ token: SQLToken) -> String {
        token.kind == .word && SQLHighlighter.keywordSet.contains(token.text.uppercased()) ? token.text.lowercased() : token.text
    }

    /// Keywords written with a space before an opening bracket (`in (`, `over (`); other words are
    /// functions (`count(`).
    private static let spaceBeforeBracket: Set = [
        "in", "as", "over", "filter", "exists", "and", "or", "not", "on", "using", "from", "join", "values",
        "then", "else", "when", "select", "where", "window", "exclude", "replace", "by", "all", "any", "is",
    ]

    /// Spacing on a line: none inside brackets or before `,` `)` `;`, one after `,`, otherwise as in the
    /// source (so `1=1` and `a = 1` both stay as written; line breaks become one space).
    static func needsSpace(_ previous: SQLToken, _ token: SQLToken, source: NSString) -> Bool {
        if token.isSymbol(",") || token.isSymbol(")") || token.isSymbol(";") { return false }
        if previous.isSymbol("(") { return false }
        if previous.isSymbol(",") { return true }
        if token.isSymbol("("), previous.kind == .word, spaceBeforeBracket.contains(previous.lowercased) { return true }
        if previous.kind == .word, token.kind == .word { return true }
        return NSMaxRange(previous.range) < token.range.location
    }
}

// MARK: - Formatter

private struct Formatter {
    let tokens: [SQLToken]
    let writer: Writer
    /// Index of the matching bracket for every `(`.
    private let match: [Int: Int]

    init(tokens: [SQLToken], writer: Writer) {
        self.tokens = tokens
        self.writer = writer
        var match: [Int: Int] = [:]
        var open: [Int] = []
        for (index, token) in tokens.enumerated() {
            if token.isSymbol("(") { open.append(index) }
            if token.isSymbol(")"), let start = open.popLast() { match[start] = index }
        }
        self.match = match
    }

    private func word(_ index: Int) -> String? {
        tokens.indices.contains(index) && tokens[index].kind == .word ? tokens[index].lowercased : nil
    }

    /// The next code (non-comment) token index at or after `index`.
    private func code(from index: Int, before end: Int) -> Int? {
        var i = index
        while i < end, tokens[i].kind == .comment { i += 1 }
        return i < end ? i : nil
    }

    /// Indexes in `lo..<hi` at bracket depth 0 (bracket contents are skipped).
    private func topLevel(_ lo: Int, _ hi: Int) -> [Int] {
        var result: [Int] = []
        var i = lo
        while i < hi {
            result.append(i)
            if tokens[i].isSymbol("("), let close = match[i], close < hi { i = close }
            i += 1
        }
        return result
    }

    // MARK: Statements and clauses

    func formatStatement() {
        guard let first = code(from: 0, before: tokens.count) else {
            tokens.forEach(writer.write)
            return
        }
        let starts: Set = ["select", "with", "from", "values"]
        if starts.contains(word(first) ?? "") || tokens[first].isSymbol("(") {
            formatQuery(0, tokens.count, indent: 0)
        } else {
            // Not a query (describe, pivot, pragma…): keep the source lines.
            writer.newline(0)
            tokens.forEach(writer.write)
        }
    }

    /// Length of the clause keyword(s) at `index`, or nil if no clause starts there.
    private func clauseHeader(at index: Int) -> Int? {
        guard let w = word(index) else { return nil }
        switch w {
        case "select":
            var length = 1
            if word(index + 1) == "distinct" {
                length = 2
                if word(index + 2) == "on", tokens.indices.contains(index + 3), tokens[index + 3].isSymbol("("),
                   let close = match[index + 3] { length = close - index + 1 }
            } else if word(index + 1) == "all" {
                length = 2
            }
            return length
        case "from":
            // `is [not] distinct from` is an operator.
            return word(index - 1) == "distinct" ? nil : 1
        case "where", "having", "qualify", "window", "limit", "offset", "with", "values", "returning":
            return w == "with" && word(index + 1) == "recursive" ? 2 : 1
        case "group", "order":
            return word(index + 1) == "by" ? 2 : nil
        case "using":
            return word(index + 1) == "sample" ? 2 : nil
        case "union", "except", "intersect":
            var length = 1
            if ["all", "distinct"].contains(word(index + 1) ?? "") { length += 1 }
            if word(index + length) == "by", word(index + length + 1) == "name" { length += 2 }
            return length
        default:
            return nil
        }
    }

    func formatQuery(_ lo: Int, _ hi: Int, indent: Int) {
        var clauses: [(start: Int, header: Int)] = []
        for i in topLevel(lo, hi) {
            if let header = clauseHeader(at: i) { clauses.append((i, header)) }
        }
        // Anything before the first clause (comments, a bracketed query).
        let firstClause = clauses.first?.start ?? hi
        if lo < firstClause {
            writer.newline(indent)
            formatExpression(lo, firstClause, breakConditions: nil)
        }
        for (n, clause) in clauses.enumerated() {
            let end = n + 1 < clauses.count ? clauses[n + 1].start : hi
            let bodyStart = clause.start + clause.header
            writer.newline(indent)
            for i in clause.start..<bodyStart { writer.write(tokens[i]) }

            switch word(clause.start) ?? "" {
            case "where":
                formatExpression(bodyStart, end, breakConditions: indent + 1)
            case "having", "qualify":
                writer.newline(indent + 1)
                formatExpression(bodyStart, end, breakConditions: indent + 1)
            case "from":
                formatFrom(bodyStart, end, indent: indent + 1)
            case "limit", "offset", "using":
                formatExpression(bodyStart, end, breakConditions: nil)
            case "union", "except", "intersect":
                if bodyStart < end {
                    writer.newline(indent)
                    formatExpression(bodyStart, end, breakConditions: nil)
                }
            default:  // select, group by, order by, window, with, values, returning
                formatList(bodyStart, end, indent: indent + 1)
            }
        }
    }

    /// Comma-separated items, one per line.
    private func formatList(_ lo: Int, _ hi: Int, indent: Int) {
        var itemStart = lo
        for i in topLevel(lo, hi) + [hi] where i == hi || tokens[i].isSymbol(",") {
            if itemStart < i || i < hi {
                writer.newline(indent)
                formatExpression(itemStart, i, breakConditions: nil)
                if i < hi { writer.write(tokens[i]) }
            }
            itemStart = i + 1
        }
    }

    private static let joinWords: Set = [
        "join", "inner", "left", "right", "full", "outer", "cross", "semi", "anti", "asof", "natural", "positional",
    ]

    /// `from` items: one table per line, each join on its own line, `on` and its conditions one level deeper.
    private func formatFrom(_ lo: Int, _ hi: Int, indent: Int) {
        let level = topLevel(lo, hi)
        writer.newline(indent)
        var i = lo
        var segmentStart = lo
        func flushSegment(_ end: Int) {
            if segmentStart < end { formatExpression(segmentStart, end, breakConditions: nil) }
        }
        for index in level {
            guard index >= i else { continue }
            let token = tokens[index]
            if token.isSymbol(",") {
                flushSegment(index)
                writer.write(token)
                writer.newline(indent)
                segmentStart = index + 1
            } else if let w = word(index), Self.joinWords.contains(w), startsJoin(at: index, before: hi), index > lo {
                flushSegment(index)
                writer.newline(indent)
                segmentStart = index
                // Skip the rest of the join phrase.
                i = index
                while let w = word(i), Self.joinWords.contains(w), i < hi { i += 1 }
            } else if word(index) == "on" {
                flushSegment(index)
                writer.newline(indent + 1)
                writer.write(token)
                // Conditions up to the next join or comma.
                let end = level.first { $0 > index && (tokens[$0].isSymbol(",") || (word($0).map { Self.joinWords.contains($0) } ?? false) && startsJoin(at: $0, before: hi)) } ?? hi
                formatExpression(index + 1, end, breakConditions: indent + 1)
                segmentStart = end
                i = end
            }
        }
        flushSegment(hi)
    }

    private func startsJoin(at index: Int, before hi: Int) -> Bool {
        var i = index
        while i < hi, let w = word(i), Self.joinWords.contains(w) {
            if w == "join" { return true }
            i += 1
        }
        return false
    }

    // MARK: Expressions

    /// Writes tokens on the current line, laying out brackets and `case`. With `breakConditions`, each
    /// top-level `and` / `or` (not the one of `between … and`) starts a line at that indent. `inBracket`:
    /// inside function arguments and the like, where a short `case` stays on the line.
    private func formatExpression(_ lo: Int, _ hi: Int, breakConditions: Int?, inBracket: Bool = false) {
        var i = lo
        var pendingBetween = 0
        while i < hi {
            let token = tokens[i]
            if let w = word(i) {
                if w == "between" { pendingBetween += 1 }
                if let breakIndent = breakConditions, w == "and" || w == "or", !writer.lineIsEmpty {
                    if w == "and", pendingBetween > 0 {
                        pendingBetween -= 1
                    } else {
                        writer.newline(breakIndent)
                    }
                }
                if w == "case", let end = caseEnd(i, hi) {
                    let lineIndent = writer.indent
                    let multiline = formatCase(i, end, inBracket: inBracket)
                    i = end + 1
                    // `end` then the alias one level in, as in example.sql.
                    if multiline, word(i) == "as" { writer.newline(lineIndent + 1) }
                    continue
                }
            }
            if token.isSymbol("("), let close = match[i], close < hi {
                formatBracket(i, close, inBracket: inBracket)
                i = close + 1
                continue
            }
            writer.write(token)
            i += 1
        }
    }

    private func flat(_ lo: Int, _ hi: Int) -> String {
        var text = ""
        var previous: SQLToken?
        for token in tokens[lo..<hi] {
            if let previous, Writer.needsSpace(previous, token, source: "" as NSString) || token.kind == .comment { text += " " }
            text += Writer.display(token)
            previous = token
        }
        return text
    }

    private func containsComment(_ lo: Int, _ hi: Int) -> Bool {
        tokens[lo..<hi].contains { $0.kind == .comment }
    }

    private func formatBracket(_ open: Int, _ close: Int, inBracket: Bool) {
        let lineIndent = writer.indent
        let inner = (open + 1, close)
        let first = code(from: open + 1, before: close)
        let isQuery = first.map { ["select", "with", "from", "values"].contains(word($0) ?? "") } ?? false

        if isQuery {
            writer.write(tokens[open])
            let nested = tokens[(open + 1)..<close].contains { $0.isSymbol("(") } || tokens[(open + 1)..<close].contains { $0.kind == .word && $0.lowercased == "join" }
            if flat(inner.0, inner.1).count <= 50, !nested, !containsComment(inner.0, inner.1) {
                writer.newline(lineIndent + 1)
                for i in inner.0..<inner.1 { writer.write(tokens[i]) }
            } else {
                formatQuery(inner.0, inner.1, indent: lineIndent + 1)
            }
            writer.newline(lineIndent)
            writer.write(tokens[close])
            return
        }

        let commas = topLevel(inner.0, inner.1).filter { tokens[$0].isSymbol(",") }.count
        let isList = word(open - 1) == "in" && (commas >= 2 || flat(open, close + 1).count > 60) && commas > 0
        if isList || (containsComment(inner.0, inner.1) && commas > 0) {
            writer.write(tokens[open])
            formatList(inner.0, inner.1, indent: lineIndent + 1)
            writer.newline(lineIndent)
            writer.write(tokens[close])
            return
        }

        // Function arguments, window specs, grouping: stay on the line.
        writer.write(tokens[open])
        formatExpression(inner.0, inner.1, breakConditions: nil, inBracket: true)
        writer.write(tokens[close])
    }

    /// Index of the `end` closing the `case` at `start`.
    private func caseEnd(_ start: Int, _ hi: Int) -> Int? {
        var depth = 0
        for i in topLevel(start, hi) {
            switch word(i) {
            case "case": depth += 1
            case "end":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    /// `when` / `else` go one per line and `end` comes back to the line's indent; a short `case` inside
    /// brackets stays on the line. Returns true if it was broken into lines.
    private func formatCase(_ start: Int, _ end: Int, inBracket: Bool) -> Bool {
        let whens = topLevel(start + 1, end).filter { word($0) == "when" }.count
        if inBracket, flat(start, end + 1).count <= 50, whens <= 1, !containsComment(start, end) {
            writer.write(tokens[start])
            formatExpression(start + 1, end, breakConditions: nil, inBracket: true)
            writer.write(tokens[end])
            return false
        }
        let lineIndent = writer.indent
        var branchStarts: [Int] = []
        var depth = 0
        for i in topLevel(start + 1, end) {
            switch word(i) {
            case "case": depth += 1
            case "end": depth -= 1
            case "when", "else" where depth == 0: branchStarts.append(i)
            default: break
            }
        }
        writer.write(tokens[start])
        // `case x when …`: the operand stays on the `case` line.
        if let firstBranch = branchStarts.first, start + 1 < firstBranch {
            formatExpression(start + 1, firstBranch, breakConditions: nil)
        }
        for (n, branch) in branchStarts.enumerated() {
            let branchEnd = n + 1 < branchStarts.count ? branchStarts[n + 1] : end
            writer.newline(lineIndent + 1)
            formatExpression(branch, branchEnd, breakConditions: nil)
        }
        writer.newline(lineIndent)
        writer.write(tokens[end])
        return true
    }
}
