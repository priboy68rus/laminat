import Foundation

/// A token of SQL text. Ranges are UTF-16 offsets (NSString), like everything in the text system.
struct SQLToken {
    enum Kind { case word, quotedIdentifier, string, number, comment, symbol }

    let kind: Kind
    let range: NSRange
    /// False for a string, quoted identifier or block comment that runs to the end of the text.
    let closed: Bool
    let text: String

    var lowercased: String { text.lowercased() }
    func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }

    /// True if `position` (a cursor) is inside this string or comment, so typing there is not code.
    func contains(cursor position: Int) -> Bool {
        let end = NSMaxRange(range)
        switch kind {
        case .comment where text.hasPrefix("--"): return position > range.location && position <= end
        case .string, .quotedIdentifier, .comment:
            return position > range.location && (position < end || (position == end && !closed))
        default: return false
        }
    }
}

/// A small SQL tokenizer for the editor: enough to tell code from strings and comments, split the text
/// into statements at `;`, match brackets and find the context for completion.
enum SQLLexer {
    static func tokens(_ string: String) -> [SQLToken] {
        let text = string as NSString
        let count = text.length
        var chars = [unichar](repeating: 0, count: count)
        text.getCharacters(&chars, range: NSRange(location: 0, length: count))

        func isWordStart(_ c: unichar) -> Bool { c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }
        func isWord(_ c: unichar) -> Bool { isWordStart(c) || (c >= 48 && c <= 57) }

        var tokens: [SQLToken] = []
        var i = 0
        while i < count {
            let c = chars[i]
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            let start = i
            var kind = SQLToken.Kind.symbol
            var closed = true
            if c == 45, i + 1 < count, chars[i + 1] == 45 {  // -- comment
                while i < count, chars[i] != 10 { i += 1 }
                kind = .comment
            } else if c == 47, i + 1 < count, chars[i + 1] == 42 {  // /* comment */
                i += 2
                while i < count, !(chars[i] == 42 && i + 1 < count && chars[i + 1] == 47) { i += 1 }
                closed = i < count
                i = min(count, i + 2)
                kind = .comment
            } else if c == 39 || c == 34 {  // 'string' or "identifier", doubled quote escapes
                i += 1
                closed = false
                while i < count {
                    if chars[i] == c {
                        if i + 1 < count, chars[i + 1] == c { i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                kind = c == 39 ? .string : .quotedIdentifier
            } else if isWordStart(c) {
                while i < count, isWord(chars[i]) { i += 1 }
                kind = .word
            } else if c >= 48, c <= 57 {
                while i < count, isWord(chars[i]) || chars[i] == 46 { i += 1 }
                kind = .number
            } else {
                i += 1
            }
            let range = NSRange(location: start, length: i - start)
            tokens.append(SQLToken(kind: kind, range: range, closed: closed, text: text.substring(with: range)))
        }
        return tokens
    }

    /// Statements of the text, split at `;` outside strings and comments. `range` runs from the end of
    /// the previous statement up to and including its `;`; `code` is the part without surrounding
    /// whitespace, comments and the `;` (nil for a statement that is only comments).
    struct Statement {
        let range: NSRange
        let code: NSRange?
    }

    static func statements(_ tokens: [SQLToken], length: Int) -> [Statement] {
        var statements: [Statement] = []
        var start = 0
        var first: NSRange?
        var last: NSRange?
        for token in tokens {
            if token.isSymbol(";") {
                let end = NSMaxRange(token.range)
                statements.append(Statement(range: NSRange(location: start, length: end - start), code: span(first, last)))
                start = end
                first = nil
                last = nil
            } else if token.kind != .comment {
                if first == nil { first = token.range }
                last = token.range
            }
        }
        statements.append(Statement(range: NSRange(location: start, length: length - start), code: span(first, last)))
        return statements
    }

    /// The statement to run for a cursor: the one the cursor is in, else the closest one before it.
    static func statement(at position: Int, tokens: [SQLToken], length: Int) -> NSRange? {
        let all = statements(tokens, length: length)
        guard let index = all.firstIndex(where: { position <= NSMaxRange($0.range) }) else { return nil }
        if let code = all[index].code { return code }
        return all[..<index].last(where: { $0.code != nil })?.code ?? all[index...].first(where: { $0.code != nil })?.code
    }

    private static func span(_ first: NSRange?, _ last: NSRange?) -> NSRange? {
        guard let first, let last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// The bracket matching the one at `position` (an opening or closing bracket token), skipping
    /// brackets in strings and comments.
    static func matchingBracket(at position: Int, tokens: [SQLToken]) -> Int? {
        guard let index = tokens.firstIndex(where: { $0.kind == .symbol && $0.range.location == position }) else { return nil }
        let pairs: [String: String] = ["(": ")", "[": "]", "{": "}"]
        let open = tokens[index].text
        if let close = pairs[open] {
            var depth = 0
            for token in tokens[(index + 1)...] where token.kind == .symbol {
                if token.text == open { depth += 1 }
                if token.text == close { if depth == 0 { return token.range.location }; depth -= 1 }
            }
        } else if let open = pairs.first(where: { $0.value == tokens[index].text })?.key {
            let close = tokens[index].text
            var depth = 0
            for token in tokens[..<index].reversed() where token.kind == .symbol {
                if token.text == close { depth += 1 }
                if token.text == open { if depth == 0 { return token.range.location }; depth -= 1 }
            }
        }
        return nil
    }
}
