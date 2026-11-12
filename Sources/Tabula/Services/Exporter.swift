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
            let objs: [[String: Any]] = rows.map { r in
                var o: [String: Any] = [:]
                for (i, c) in columns.enumerated() where i < r.count { o[c] = jsonValue(r[i]) }
                return o
            }
            let data = (try? JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "[]"
        case .sqlInsert:
            let obj = table ?? DBObject(schema: nil, name: "table_name", kind: .table)
            return rows.map { dialect.insertSQL(obj, columns: columns, rows: [$0]) }.joined(separator: "\n")
        case .markdown:
            func esc(_ s: String?) -> String { (s ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            var lines = ["| " + columns.map { esc($0) }.joined(separator: " | ") + " |",
                         "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|"]
            for r in rows { lines.append("| " + r.map { esc($0) }.joined(separator: " | ") + " |") }
            return lines.joined(separator: "\n")
        }
    }

    static func renderHTML(columns: [String], rows: [[String?]], title: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(esc(title))</title><style>body{font:13px -apple-system,sans-serif}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:3px 6px;text-align:left}th{background:#f0f0f0}.n{color:#999}</style></head><body><table><tr>"
        html += columns.map { "<th>\(esc($0))</th>" }.joined() + "</tr>\n"
        for r in rows {
            html += "<tr>" + r.map { $0.map { "<td>\(esc($0))</td>" } ?? "<td class=n>NULL</td>" }.joined() + "</tr>\n"
        }
        return html + "</table></body></html>"
    }

    static func write(columns: [String], rows: [[String?]], format: ExportFormat, table: DBObject?, dialect: SQLDialect, to url: URL) throws {
        let text: String
        if let f = format.copyFormat {
            text = render(columns: columns, rows: rows, format: f, table: table, dialect: dialect, includeHeader: true)
        } else {
            text = renderHTML(columns: columns, rows: rows, title: table?.name ?? "Export")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Ask for a destination and write. Returns the URL written, if any.
    @MainActor
    static func saveWithPanel(columns: [String], rows: [[String?]], format: ExportFormat, table: DBObject?, dialect: SQLDialect, suggestedName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        if let t = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try write(columns: columns, rows: rows, format: format, table: table, dialect: dialect, to: url)
        return url
    }
}

enum CSVParser {
    /// RFC 4180-ish parser supporting quoted fields, embedded newlines and custom delimiters.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
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
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == delimiter {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
    }
}
