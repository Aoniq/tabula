import Foundation

enum SQLKeywords {
    static let keywords: [String] = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST",
        "CHECK", "COLLATE", "COLUMN", "COMMENT", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP", "ELSE", "END", "ESCAPE",
        "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FILTER", "FIRST", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT",
        "GROUP", "HAVING", "IF", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "KEY",
        "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "MATERIALIZED", "NATURAL", "NOT", "NULL", "NULLS", "OFFSET", "ON", "OR",
        "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY", "PROCEDURE", "RECURSIVE", "REFERENCES", "RENAME", "REPLACE",
        "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SCHEMA", "SELECT", "SEQUENCE", "SET", "SHOW", "TABLE",
        "TEMPORARY", "THEN", "TO", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USE", "USING",
        "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "AUTO_INCREMENT", "ENGINE", "CHARSET", "UNSIGNED", "SERIAL",
        "RETURNS", "LANGUAGE", "DECLARE", "IGNORE", "DUPLICATE", "CONFLICT", "DO", "NOTHING", "VACUUM", "PRAGMA", "EXTENSION",
        "OWNER", "ONLY", "OF", "TYPE", "ENUM", "SIMILAR", "LOCK", "SAVEPOINT", "RELEASE", "SHARE", "MODE", "NOWAIT", "SKIP", "LOCKED",
    ]

    static let functions: [String] = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "GREATEST", "LEAST", "LOWER", "UPPER", "LENGTH", "TRIM",
        "LTRIM", "RTRIM", "SUBSTRING", "SUBSTR", "REPLACE", "CONCAT", "CONCAT_WS", "ROUND", "FLOOR", "CEIL", "ABS", "NOW",
        "DATE", "EXTRACT", "DATE_TRUNC", "DATE_FORMAT", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP", "ROW_NUMBER", "RANK",
        "DENSE_RANK", "LAG", "LEAD", "STRING_AGG", "ARRAY_AGG", "GROUP_CONCAT", "JSON_AGG", "JSONB_AGG", "JSON_EXTRACT",
        "JSONB_BUILD_OBJECT", "JSON_BUILD_OBJECT", "JSON_OBJECT", "IFNULL", "IIF", "RANDOM", "RAND", "UUID", "GEN_RANDOM_UUID",
        "POSITION", "SPLIT_PART", "REGEXP_REPLACE", "LEFT", "RIGHT", "MD5", "CURRENT_USER", "VERSION", "UNNEST", "GENERATE_SERIES",
    ]

    static let types: [String] = [
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "REAL", "FLOAT", "DOUBLE", "BOOLEAN", "BOOL",
        "CHAR", "VARCHAR", "TEXT", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "JSON", "JSONB", "UUID", "BLOB",
        "BYTEA", "SERIAL", "BIGSERIAL",
    ]

    static let keywordSet: Set<String> = Set(keywords).union(types)
    static let functionSet: Set<String> = Set(functions)
}

/// Pragmatic SQL beautifier: uppercases keywords and breaks major clauses onto new lines.
enum SQLFormatter {
    private static let newlineBefore: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "VALUES",
        "SET", "RETURNING", "WINDOW", "INSERT", "UPDATE", "DELETE", "ON",
    ]
    private static let joinWords: Set<String> = ["JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER", "LATERAL"]

    static func format(_ sql: String, uppercase: Bool) -> String {
        let statements = SQLTokenizer.statements(sql)
        if statements.count > 1 {
            return statements.map { formatOne($0, uppercase: uppercase) + ";" }.joined(separator: "\n\n")
        }
        let trailingSemicolon = sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";")
        return formatOne(statements.first ?? sql, uppercase: uppercase) + (trailingSemicolon ? ";" : "")
    }

    private static func formatOne(_ sql: String, uppercase: Bool) -> String {
        let ns = sql as NSString
        let tokens = SQLTokenizer.tokenize(sql).filter { $0.kind != .whitespace }
        var out = ""
        var depth = 0
        var clauseIndent: [Int] = [0]
        var prevWord = ""
        var prev: SQLToken?
        var inSelectList = false
        var lineStart = true

        func indent(_ n: Int) -> String { String(repeating: "  ", count: max(0, n)) }
        func newline(_ extra: Int = 0) {
            while out.hasSuffix(" ") { out.removeLast() }
            out += "\n" + indent(depth + extra)
            lineStart = true
        }
        func append(_ s: String, space: Bool) {
            if space && !lineStart && !out.isEmpty && !out.hasSuffix("(") && !out.hasSuffix(" ") && !out.hasSuffix(".") && !out.hasSuffix("::") { out += " " }
            out += s
            lineStart = false
        }

        for (i, t) in tokens.enumerated() {
            var text = ns.substring(with: t.range)
            let upper = text.uppercased()
            switch t.kind {
            case .word:
                let isKeyword = SQLKeywords.keywordSet.contains(upper) || SQLKeywords.functionSet.contains(upper) || joinWords.contains(upper) || ["BY", "AND", "OR"].contains(upper)
                if uppercase && isKeyword && prev.map({ ns.substring(with: $0.range) }) != "." { text = upper }
                let nextIsParen = i + 1 < tokens.count && ns.substring(with: tokens[i + 1].range) == "("
                if newlineBefore.contains(upper) && !(upper == "SET" && prevWord == "UPDATE") && !out.isEmpty && !(upper == "ON" && prevWord == "CONFLICT") {
                    if upper == "SELECT" && prev.map({ ns.substring(with: $0.range) }) == "(" {
                        // subquery start stays on same line
                    } else {
                        newline()
                    }
                }
                if joinWords.contains(upper) && !joinWords.contains(prevWord) && !out.isEmpty { newline() }
                if (upper == "AND" || upper == "OR") && depth == clauseIndent.last ?? 0 && !["BETWEEN"].contains(prevWord) && !out.isEmpty {
                    newline(1)
                }
                append(text, space: true)
                if upper == "SELECT" { inSelectList = true; newline(1) }
                if upper == "FROM" || upper == "WHERE" { inSelectList = false }
                _ = nextIsParen
                prevWord = upper
            case .symbol:
                if text == "(" {
                    let fnCall = prev?.kind == .word || prev?.kind == .quotedIdentifier
                    append(text, space: !fnCall)
                    depth += 1
                } else if text == ")" {
                    depth -= 1
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += ")"
                    lineStart = false
                } else if text == "," {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += ","
                    if inSelectList && depth == 0 { newline(1) } else { out += " " }
                } else if text == "." {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += "."
                } else if text == ":" && i + 1 < tokens.count && ns.substring(with: tokens[i + 1].range) == ":" {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += ":"
                } else if text == ":" && prev.map({ ns.substring(with: $0.range) }) == ":" {
                    out += ":"
                } else {
                    // operators like = < > ! + - * / || combine
                    let prevText = prev.map { ns.substring(with: $0.range) } ?? ""
                    let ops: Set<String> = ["<", ">", "!", "=", "|", "&"]
                    if ops.contains(prevText) && ops.contains(text) && prev.map({ NSMaxRange($0.range) == t.range.location }) == true {
                        out += text
                    } else if text == "*" && (prevText == "." || prevText == "(") {
                        out += text
                    } else {
                        append(text, space: true)
                    }
                }
                prevWord = ""
            case .comment:
                append(text, space: true)
                if text.hasPrefix("--") || text.hasPrefix("#") { newline() }
            default:
                let prevText = prev.map { ns.substring(with: $0.range) } ?? ""
                if prevText == "." { out += text; lineStart = false } else { append(text, space: true) }
                prevWord = ""
            }
            prev = t
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
