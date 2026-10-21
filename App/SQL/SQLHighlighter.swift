import AppKit

/// Regex-based SQL highlighting: keywords, numbers, strings, quoted identifiers, comments.
/// Re-applied to the whole text on every edit, which is instant for query-sized text.
enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let keywords: [String] = """
        SELECT FROM WHERE GROUP BY ORDER HAVING LIMIT OFFSET AS AND OR NOT IN IS NULL LIKE ILIKE BETWEEN \
        CASE WHEN THEN ELSE END JOIN LEFT RIGHT FULL INNER OUTER CROSS SEMI ANTI ON USING UNION ALL \
        EXCEPT INTERSECT DISTINCT WITH ASC DESC NULLS FIRST LAST CAST TRUE FALSE OVER PARTITION ROWS \
        RANGE QUALIFY SAMPLE USING DESCRIBE SUMMARIZE SHOW EXPLAIN ANALYZE VALUES EXCLUDE REPLACE \
        COLUMNS FILTER WINDOW RECURSIVE LATERAL TRY_CAST INTERVAL DATE TIMESTAMP
        """.split(separator: " ").map(String.init)

    private static let keywordRegex = try! NSRegularExpression(
        pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b")
    private static let identifierRegex = try! NSRegularExpression(pattern: "\"(?:[^\"]|\"\")*\"")
    private static let stringRegex = try! NSRegularExpression(pattern: "'(?:[^']|'')*'?")
    private static let commentRegex = try! NSRegularExpression(
        pattern: "--[^\\n]*|/\\*[\\s\\S]*?(\\*/|$)")
    private static let placeholderRegex = try! NSRegularExpression(pattern: "⟨[^⟩]*⟩")

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        // Later rules win: a keyword inside a string or comment is coloured as the string / comment.
        let rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
            (keywordRegex, [.foregroundColor: NSColor.systemPurple]),
            (numberRegex, [.foregroundColor: NSColor.systemBlue]),
            (identifierRegex, [.foregroundColor: NSColor.systemTeal]),
            (stringRegex, [.foregroundColor: NSColor.systemRed]),
            (placeholderRegex, [.foregroundColor: NSColor.secondaryLabelColor,
                                .backgroundColor: NSColor.quaternaryLabelColor]),
            (commentRegex, [.foregroundColor: NSColor.secondaryLabelColor]),
        ]
        for (regex, attributes) in rules {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                if let range = match?.range { storage.addAttributes(attributes, range: range) }
            }
        }
        storage.endEditing()
    }
}

/// Built-in query templates (SPEC §1.5). `{t}` is replaced with the table name; `⟨…⟩` placeholders are
/// visited with Tab. House style: lowercase keywords, each clause keyword on its own line, its contents
/// indented by four spaces, `where 1=1` followed by one `and …` per line.
struct SQLTemplate {
    let title: String
    let sql: String

    static let all: [SQLTemplate] = [
        SQLTemplate(title: "First rows", sql: """
            select
                *
            from
                {t}
            limit 100
            """),
        SQLTemplate(title: "Row count", sql: """
            select
                count(*) as rows
            from
                {t}
            """),
        SQLTemplate(title: "Top values of a column", sql: """
            select
                ⟨column⟩,
                count(*) as n
            from
                {t}
            group by
                1
            order by
                n desc
            limit 50
            """),
        SQLTemplate(title: "Duplicates by key", sql: """
            select
                ⟨key⟩,
                count(*) as n
            from
                {t}
            group by
                1
            having
                count(*) > 1
            order by
                n desc
            """),
        SQLTemplate(title: "Nulls in a column", sql: """
            select
                count(*) filter (where ⟨column⟩ is null) as nulls,
                count(*) as rows
            from
                {t}
            """),
        SQLTemplate(title: "Rows per day", sql: """
            select
                date_trunc('day', ⟨timestamp_column⟩) as day,
                count(*) as n
            from
                {t}
            group by
                1
            order by
                1
            """),
        SQLTemplate(title: "Random sample", sql: """
            select
                *
            from
                {t}
            using sample 1000 rows
            """),
        SQLTemplate(title: "Column summary", sql: "summarize {t}"),
        SQLTemplate(title: "Schema", sql: "describe {t}"),
    ]
}
