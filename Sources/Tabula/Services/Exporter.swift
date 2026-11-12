import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV", tsv = "TSV", json = "JSON", sql = "SQL INSERT", markdown = "Markdown", html = "HTML"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .sql: return "sql"
        case .markdown: return "md"
        case .html: return "html"
        }
    }
    var copyFormat: CopyFormat? {
        switch self {
        case .csv: return .csv
        case .tsv: return .tsv
        case .json: return .json
        case .sql: return .sqlInsert
        case .markdown: return .markdown
        case .html: return nil
        }
    }
    /// Whether a header row is optional for this format.
    var supportsHeaderToggle: Bool { self == .csv || self == .tsv }
}

enum Exporter {
    static func csvField(_ s: String?, delimiter: Character = ",") -> String {
        guard let s else { return "" }
        if s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func jsonValue(_ s: String?) -> Any {
        guard let s else { return NSNull() }
        return s
    }

    /// JSON string literal (RFC 8259 escaping).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// JSON value for a cell, emitting bare numbers / booleans when the column type says so.
    static func jsonLiteral(_ s: String?, typeName: String) -> String {
        guard let s else { return "null" }
        let t = typeName.lowercased()
        if t == "bool" || t == "boolean" {
            switch s.lowercased() {
            case "t", "true", "1": return "true"
            case "f", "false", "0": return "false"
            default: break
            }
        }
        let numeric = ["int", "serial", "numeric", "decimal", "float", "double", "real", "number"]
        if numeric.contains(where: { t.contains($0) }), isJSONNumber(s) { return s }
        return jsonString(s)
    }

    private static func isJSONNumber(_ s: String) -> Bool {
        // -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
        let b = Array(s.utf8)
        var i = 0
        func digits() -> Int { let st = i; while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }; return i - st }
        if i < b.count, b[i] == 45 { i += 1 }
        guard i < b.count else { return false }
        if b[i] == 48 { i += 1 } else if digits() == 0 { return false }
        if i < b.count, b[i] == 46 { i += 1; if digits() == 0 { return false } }
        if i < b.count, b[i] == 101 || b[i] == 69 {
            i += 1
            if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }
            if digits() == 0 { return false }
        }
        return i == b.count
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func markdownCell(_ s: String?) -> String {
        (s ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func render(columns: [String], rows: [[String?]], format: CopyFormat, table: DBObject?, dialect: SQLDialect, includeHeader: Bool = true, nullText: String = "") -> String {
        switch format {
        case .tsv:
            var lines: [String] = []
            if includeHeader { lines.append(columns.joined(separator: "\t")) }
            for r in rows {
                lines.append(r.map { ($0 ?? nullText).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        case .csv:
            var lines: [String] = []
            if includeHeader { lines.append(columns.map { csvField($0) }.joined(separator: ",")) }
            for r in rows { lines.append(r.map { csvField($0) }.joined(separator: ",")) }
            return lines.joined(separator: "\n")
        case .json:
            let objs = rows.map { r in
                "  {" + columns.enumerated().map { i, c in
                    jsonString(c) + ": " + (i < r.count ? (r[i].map(jsonString) ?? "null") : "null")
                }.joined(separator: ", ") + "}"
            }
            return objs.isEmpty ? "[]" : "[\n" + objs.joined(separator: ",\n") + "\n]"
        case .sqlInsert:
            let obj = table ?? DBObject(schema: nil, name: "table_name", kind: .table)
            return rows.map { dialect.insertSQL(obj, columns: columns, rows: [$0]) }.joined(separator: "\n")
        case .markdown:
            var lines = ["| " + columns.map { markdownCell($0) }.joined(separator: " | ") + " |",
                         "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|"]
            for r in rows { lines.append("| " + r.map { markdownCell($0) }.joined(separator: " | ") + " |") }
            return lines.joined(separator: "\n")
        }
    }

    static func renderHTML(columns: [String], rows: [[String?]], title: String) -> String {
        var out = ""
        let w = ExportWriter.TextSink { out += $0 }
        let writer = ExportWriter(sink: w, format: .html, columns: columns, title: title, dialect: SQLDialect(family: .postgres))
        try? writer.write(rows)
        try? writer.finish()
        return out
    }

    static func write(columns: [String], rows: [[String?]], format: ExportFormat, table: DBObject?, dialect: SQLDialect, to url: URL, includeHeader: Bool = true, columnTypes: [String] = []) throws {
        let writer = try ExportWriter(url: url, format: format, columns: columns, columnTypes: columnTypes, table: table, dialect: dialect, includeHeader: includeHeader)
        do {
            try writer.write(rows)
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Ask for a destination and write. Returns the URL written, if any.
    @MainActor
    static func saveWithPanel(columns: [String], rows: [[String?]], format: ExportFormat, table: DBObject?, dialect: SQLDialect, suggestedName: String) throws -> URL? {
        guard let url = askDestination(format: format, suggestedName: suggestedName) else { return nil }
        try write(columns: columns, rows: rows, format: format, table: table, dialect: dialect, to: url)
        return url
    }

    @MainActor
    static func askDestination(format: ExportFormat, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        if let t = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}

/// Incremental writer for every export format: header, any number of row batches, footer.
/// Not thread-safe; use from one thread at a time (it is fine to hop between queues sequentially).
final class ExportWriter {
    /// Destination abstraction so the writer can target files and in-memory strings.
    struct TextSink {
        let write: (String) throws -> Void
        init(_ write: @escaping (String) throws -> Void) { self.write = write }
    }

    let format: ExportFormat
    let columns: [String]
    let columnTypes: [String]
    let table: DBObject
    let dialect: SQLDialect
    let includeHeader: Bool
    let title: String
    /// Rows per INSERT statement for the SQL format.
    var sqlBatchSize = 100
    private(set) var rowCount = 0

    private let sink: TextSink
    private var handle: FileHandle?
    private var fileURL: URL?
    private var buffer = ""
    private var started = false
    private var finished = false

    init(sink: TextSink, format: ExportFormat, columns: [String], columnTypes: [String] = [], table: DBObject? = nil, title: String? = nil, dialect: SQLDialect, includeHeader: Bool = true) {
        self.sink = sink
        self.format = format
        self.columns = columns
        self.columnTypes = columnTypes
        self.table = table ?? DBObject(schema: nil, name: "table_name", kind: .table)
        self.title = title ?? table?.name ?? "Export"
        self.dialect = dialect
        self.includeHeader = includeHeader
    }

    convenience init(url: URL, format: ExportFormat, columns: [String], columnTypes: [String] = [], table: DBObject?, dialect: SQLDialect, includeHeader: Bool = true) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DBError("Could not create \(url.path)")
        }
        let h = try FileHandle(forWritingTo: url)
        self.init(sink: TextSink { s in try h.write(contentsOf: Data(s.utf8)) }, format: format, columns: columns, columnTypes: columnTypes, table: table, dialect: dialect, includeHeader: includeHeader)
        handle = h
        fileURL = url
    }

    private func emit(_ s: String) throws {
        buffer += s
        if buffer.utf8.count >= 1 << 20 { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try sink.write(buffer)
        buffer = ""
    }

    private func start() throws {
        guard !started else { return }
        started = true
        switch format {
        case .csv:
            if includeHeader { try emit(columns.map { Exporter.csvField($0) }.joined(separator: ",") + "\n") }
        case .tsv:
            if includeHeader { try emit(columns.map(tsvField).joined(separator: "\t") + "\n") }
        case .json:
            try emit("[")
        case .sql:
            break
        case .markdown:
            try emit("| " + columns.map { Exporter.markdownCell($0) }.joined(separator: " | ") + " |\n")
            try emit("|" + columns.map { _ in " --- " }.joined(separator: "|") + "|\n")
        case .html:
            try emit("""
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(Exporter.htmlEscape(title))</title>
            <style>body{font:13px -apple-system,BlinkMacSystemFont,sans-serif;margin:16px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:3px 6px;text-align:left;vertical-align:top;white-space:pre-wrap}th{background:#f0f0f0;position:sticky;top:0}.n{color:#999;font-style:italic}@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}td,th{border-color:#444}th{background:#2a2a2a}}</style>
            </head><body>
            <table>
            <thead><tr>
            """)
            try emit(columns.map { "<th>\(Exporter.htmlEscape($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n")
        }
    }

    private func tsvField(_ s: String?) -> String {
        guard let s else { return "" }
        return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    func write(_ rows: [[String?]]) throws {
        try start()
        switch format {
        case .csv:
            for r in rows { try emit(r.map { Exporter.csvField($0) }.joined(separator: ",") + "\n") }
        case .tsv:
            for r in rows { try emit(r.map(tsvField).joined(separator: "\t") + "\n") }
        case .json:
            for (n, r) in rows.enumerated() {
                var obj = (rowCount + n == 0 ? "\n  {" : ",\n  {")
                for (i, c) in columns.enumerated() {
                    if i > 0 { obj += ", " }
                    let v = i < r.count ? r[i] : nil
                    obj += Exporter.jsonString(c) + ": " + Exporter.jsonLiteral(v, typeName: i < columnTypes.count ? columnTypes[i] : "")
                }
                try emit(obj + "}")
            }
        case .sql:
            var i = 0
            while i < rows.count {
                let chunk = Array(rows[i..<min(rows.count, i + sqlBatchSize)])
                try emit(dialect.insertSQL(table, columns: columns, rows: chunk) + "\n")
                i += sqlBatchSize
            }
        case .markdown:
            for r in rows { try emit("| " + r.map { Exporter.markdownCell($0) }.joined(separator: " | ") + " |\n") }
        case .html:
            for r in rows {
                try emit("<tr>" + r.map { $0.map { "<td>\(Exporter.htmlEscape($0))</td>" } ?? "<td class=\"n\">NULL</td>" }.joined() + "</tr>\n")
            }
        }
        rowCount += rows.count
    }

    func finish() throws {
        guard !finished else { return }
        try start()
        finished = true
        switch format {
        case .json: try emit(rowCount == 0 ? "]\n" : "\n]\n")
        case .html: try emit("</tbody>\n</table>\n</body></html>\n")
        default: break
        }
        try flush()
        try handle?.close()
        handle = nil
    }

    /// Close and delete a partially written file.
    func abort() {
        finished = true
        try? handle?.close()
        handle = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}

enum CSVParser {
    /// RFC 4180-ish parser supporting quoted fields, embedded newlines and custom delimiters.
    static func parse(_ text: String, delimiter: Character = ",", maxRows: Int = .max) -> [[String]] {
        if let d = delimiter.asciiValue, d != 34, d != 10, d != 13 {
            return parse(data: Data(text.utf8), delimiter: d, maxRows: maxRows)
        }
        return parseCharacters(text, delimiter: delimiter, maxRows: maxRows)
    }

    /// Fast byte-level parser for UTF-8 data with a single-byte (ASCII) delimiter.
    /// Multi-byte UTF-8 sequences never contain ASCII bytes, so splitting on bytes is safe.
    static func parse(data: Data, delimiter: UInt8, maxRows: Int = .max) -> [[String]] {
        data.withUnsafeBytes { raw -> [[String]] in
            let b = raw.bindMemory(to: UInt8.self)
            var rows: [[String]] = []
            var row: [String] = []
            var field: [UInt8] = []
            field.reserveCapacity(64)
            var inQuotes = false
            var fieldStarted = false   // any byte (or quote) seen for the current field
            var i = 0
            let n = b.count
            if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }   // UTF-8 BOM

            func endField() {
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                fieldStarted = false
            }
            func endRow() {
                endField()
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            }

            while i < n {
                let c = b[i]
                if inQuotes {
                    if c == 34 {
                        if i + 1 < n, b[i + 1] == 34 { field.append(34); i += 2; continue }
                        inQuotes = false
                    } else {
                        field.append(c)
                    }
                    i += 1
                    continue
                }
                if c == 34 && !fieldStarted {
                    inQuotes = true
                    fieldStarted = true
                } else if c == delimiter {
                    endField()
                } else if c == 10 || c == 13 {
                    if c == 13, i + 1 < n, b[i + 1] == 10 { i += 1 }
                    endRow()
                    if rows.count >= maxRows { return rows }
                } else {
                    field.append(c)
                    fieldStarted = true
                }
                i += 1
            }
            if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
            return rows.count > maxRows ? Array(rows.prefix(maxRows)) : rows
        }
    }

    private static func parseCharacters(_ text: String, delimiter: Character, maxRows: Int) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if ch == delimiter {
                row.append(field); field = ""; fieldStarted = false
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); field = ""; fieldStarted = false
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
                if rows.count >= maxRows { return rows }
            } else {
                field.append(ch)
                fieldStarted = true
            }
        }
        if fieldStarted || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows
    }

    /// Picks the delimiter that splits the first lines most consistently (quotes are respected).
    static func guessDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        let lines = Array(text.prefix(64 * 1024).split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).prefix(20))
        guard !lines.isEmpty else { return "," }
        func count(_ line: Substring, _ d: Character) -> Int {
            var inQ = false, n = 0
            for ch in line {
                if ch == "\"" { inQ.toggle() } else if ch == d && !inQ { n += 1 }
            }
            return n
        }
        var best: Character = ","
        var bestScore = 0
        for d in candidates {
            let counts = lines.map { count($0, d) }
            guard let first = counts.first, first > 0 else { continue }
            // Prefer delimiters whose per-line count is stable; weight by frequency.
            let consistent = counts.filter { $0 == first }.count
            let score = consistent * 1000 + first
            if score > bestScore { bestScore = score; best = d }
        }
        return best
    }
}

/// Fetches all rows of a browsable object (respecting filters and sort) in fixed-size pages.
/// Each `fetch` is meant to be executed in its own `ws.run` so other work can interleave.
struct TableExportQuery {
    var object: DBObject
    var columns: [String]
    var filters: [FilterRule]
    var sort: [SortKey]
    var batchSize = 5000

    /// Adds a primary-key ordering when no sort is set, so OFFSET paging is deterministic.
    mutating func stabilize(primaryKey: [String]) {
        if sort.isEmpty && !primaryKey.isEmpty {
            sort = primaryKey.map { SortKey(column: $0, ascending: true) }
        }
    }

    func fetch(_ d: DatabaseDriver, offset: Int) throws -> QueryResult {
        // Redis keys are fetched in one go (the driver pages locally anyway).
        let limit = d.dialect.family == .redis ? Int.max : batchSize
        return try d.browse(object, columns: columns, filters: filters, sort: sort, limit: limit, offset: offset)
    }

    func isLastBatch(_ fetched: Int, family: DatabaseFamily) -> Bool {
        family == .redis || fetched < batchSize
    }

    /// Synchronous convenience: stream every batch into a writer. Returns the number of rows written.
    @discardableResult
    func exportAll(_ d: DatabaseDriver, to writer: ExportWriter, isCancelled: () -> Bool = { false }) throws -> Int {
        var offset = 0
        while !isCancelled() {
            let r = try fetch(d, offset: offset)
            try writer.write(r.rows)
            offset += r.rows.count
            if isLastBatch(r.rows.count, family: d.dialect.family) { break }
        }
        return offset
    }
}
