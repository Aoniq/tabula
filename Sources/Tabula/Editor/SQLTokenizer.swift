import Foundation

/// A small, forgiving SQL tokenizer that works in UTF-16 offsets so results map
/// directly onto NSRange / NSTextView ranges.
struct SQLToken {
    enum Kind { case whitespace, comment, string, quotedIdentifier, number, word, symbol, semicolon, parameter }
    let kind: Kind
    let range: NSRange
}

enum SQLTokenizer {
    static func tokenize(_ text: String) -> [SQLToken] {
        let u = Array(text.utf16)
        let n = u.count
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(n / 3)
        var i = 0

        @inline(__always) func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        @inline(__always) func isIdentPart(_ c: UInt16) -> Bool {
            isIdentStart(c) || (c >= 48 && c <= 57) || c == 36
        }
        @inline(__always) func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

        while i < n {
            let c = u[i]
            let start = i
            // whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 {
                while i < n, u[i] == 32 || u[i] == 9 || u[i] == 10 || u[i] == 13 { i += 1 }
                tokens.append(SQLToken(kind: .whitespace, range: NSRange(location: start, length: i - start)))
                continue
            }
            // -- comment or # comment (MySQL)
            if (c == 45 && i + 1 < n && u[i + 1] == 45) || c == 35 {
                while i < n, u[i] != 10 { i += 1 }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }
            // /* block comment */
            if c == 47 && i + 1 < n && u[i + 1] == 42 {
                i += 2
                while i < n && !(u[i] == 42 && i + 1 < n && u[i + 1] == 47) { i += 1 }
                i = min(n, i + 2)
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }
            // strings '...' with '' escape and backslash escapes
            if c == 39 {
                i += 1
                while i < n {
                    if u[i] == 92 { i += 2; continue }
                    if u[i] == 39 {
                        if i + 1 < n && u[i + 1] == 39 { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                i = min(i, n)
                tokens.append(SQLToken(kind: .string, range: NSRange(location: start, length: i - start)))
                continue
            }
            // quoted identifiers "..." and `...`
            if c == 34 || c == 96 {
                let q = c
                i += 1
                while i < n {
                    if u[i] == q {
                        if i + 1 < n && u[i + 1] == q { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                i = min(i, n)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: NSRange(location: start, length: i - start)))
                continue
            }
            // dollar quoting $tag$ ... $tag$  or positional $1
            if c == 36 {
                var j = i + 1
                while j < n && isIdentPart(u[j]) && u[j] != 36 { j += 1 }
                if j < n && u[j] == 36 {
                    let tag = Array(u[i...j])
                    var k = j + 1
                    var found = false
                    while k + tag.count <= n {
                        if u[k] == 36 && Array(u[k..<(k + tag.count)]) == tag {
                            k += tag.count
                            found = true
                            break
                        }
                        k += 1
                    }
                    i = found ? k : n
                    tokens.append(SQLToken(kind: .string, range: NSRange(location: start, length: i - start)))
                    continue
                }
                if i + 1 < n && isDigit(u[i + 1]) {
                    i += 1
                    while i < n && isDigit(u[i]) { i += 1 }
                    tokens.append(SQLToken(kind: .parameter, range: NSRange(location: start, length: i - start)))
                    continue
                }
            }
            // numbers
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(u[i + 1])) {
                while i < n && (isDigit(u[i]) || u[i] == 46) { i += 1 }
                if i < n && (u[i] == 101 || u[i] == 69) { // exponent
                    i += 1
                    if i < n && (u[i] == 43 || u[i] == 45) { i += 1 }
                    while i < n && isDigit(u[i]) { i += 1 }
                }
                tokens.append(SQLToken(kind: .number, range: NSRange(location: start, length: i - start)))
                continue
            }
            // words
            if isIdentStart(c) {
                while i < n && isIdentPart(u[i]) { i += 1 }
                tokens.append(SQLToken(kind: .word, range: NSRange(location: start, length: i - start)))
                continue
            }
            // parameters :name / ?
            if c == 58 && i + 1 < n && isIdentStart(u[i + 1]) && (i == 0 || u[i - 1] != 58) {
                i += 1
                while i < n && isIdentPart(u[i]) { i += 1 }
                tokens.append(SQLToken(kind: .parameter, range: NSRange(location: start, length: i - start)))
                continue
            }
            if c == 59 {
                i += 1
                tokens.append(SQLToken(kind: .semicolon, range: NSRange(location: start, length: 1)))
                continue
            }
            // symbols (handle surrogate pairs gracefully by consuming one unit)
            i += 1
            tokens.append(SQLToken(kind: .symbol, range: NSRange(location: start, length: 1)))
        }
        return tokens
    }

    /// Ranges of individual statements (trimmed of surrounding whitespace / empty statements removed).
    static func statementRanges(_ text: String) -> [NSRange] {
        let tokens = tokenize(text)
        var ranges: [NSRange] = []
        var first: Int?
        var last: Int?
        for t in tokens {
            switch t.kind {
            case .semicolon:
                if let f = first, let l = last { ranges.append(NSRange(location: f, length: l - f)) }
                first = nil; last = nil
            case .whitespace:
                continue
            case .comment:
                // comments alone don't start a statement, but are included when inside one
                if first != nil { last = NSMaxRange(t.range) }
            default:
                if first == nil { first = t.range.location }
                last = NSMaxRange(t.range)
            }
        }
        if let f = first, let l = last { ranges.append(NSRange(location: f, length: l - f)) }
        return ranges
    }

    static func statements(_ text: String) -> [String] {
        let ns = text as NSString
        return statementRanges(text).map { ns.substring(with: $0) }
    }

    /// The statement under (or immediately before) the cursor.
    static func statementRange(at location: Int, in text: String) -> NSRange? {
        let ranges = statementRanges(text)
        if ranges.isEmpty { return nil }
        // statement containing the cursor, including the trailing semicolon position
        for r in ranges where location >= r.location && location <= NSMaxRange(r) + 1 {
            return r
        }
        // otherwise the last statement before the cursor
        return ranges.last(where: { NSMaxRange($0) <= location }) ?? ranges.first
    }

    /// First keyword of a statement (uppercased), skipping comments and parens.
    static func leadingKeywords(_ sql: String, count: Int = 2) -> [String] {
        let ns = sql as NSString
        var out: [String] = []
        for t in tokenize(sql) where t.kind == .word {
            out.append(ns.substring(with: t.range).uppercased())
            if out.count >= count { break }
        }
        return out
    }

    /// Heuristic: does this statement modify data or schema?
    static func isWriteStatement(_ sql: String) -> Bool {
        let ns = sql as NSString
        let words = tokenize(sql).filter { $0.kind == .word }.map { ns.substring(with: $0.range).uppercased() }
        guard let first = words.first else { return false }
        let readOnly: Set<String> = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE", "PRAGMA", "USE", "SET", "BEGIN", "START", "COMMIT", "ROLLBACK", "WITH", "HELP", "CHECKSUM", "ANALYZE"]
        if first == "WITH" {
            let writes: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]
            return words.contains(where: { writes.contains($0) })
        }
        if first == "SELECT" {
            // SELECT ... INTO new_table (Postgres) creates a table
            guard let into = words.firstIndex(of: "INTO") else { return false }
            return into < (words.firstIndex(of: "FROM") ?? Int.max)
        }
        if first == "EXPLAIN" { return words.contains("ANALYZE") && words.contains(where: { ["INSERT", "UPDATE", "DELETE"].contains($0) }) }
        if first == "PRAGMA" { return sql.contains("=") }
        return !readOnly.contains(first)
    }
}
