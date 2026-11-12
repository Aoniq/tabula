import Foundation

/// Text-based ER diagram exports. All functions are pure (graph in, text out), deterministic
/// (tables sorted by id, externals last; relations sorted by child/name) and end with a newline.
///
/// - Mermaid / DBML: here.
/// - PlantUML / Graphviz DOT: `ERDTextExport+Diagrams.swift`.
/// - Markdown data dictionary: `ERDTextExport+Markdown.swift`.
enum ERDTextExport {

    // MARK: - Mermaid

    /// Mermaid `erDiagram` (renders in GitHub, GitLab, Notion, Obsidian, Confluence).
    ///
    /// Sticks to syntax accepted by Mermaid 10–12: entity names are always double-quoted (so spaces,
    /// dots and reserved words are safe), attribute types/names are reduced to the characters Mermaid
    /// accepts, and anything lost in that reduction (the original column name) goes into the comment.
    static func mermaid(_ g: ERDGraph) -> String {
        let p = Prepared(g)
        var out = "erDiagram\n"
        out += "    %% \(oneLine(g.title)) (\(p.familyName)): \(p.summary)\n"
        for t in p.tables {
            let name = mermaidEntity(p, t.id)
            if t.columns.isEmpty {
                out += "    \(name)\n"
                continue
            }
            out += "    \(name) {\n"
            for c in t.columns {
                let (attr, renamed) = mermaidAttributeName(c.name)
                var keys: [String] = []
                if c.isPrimaryKey { keys.append("PK") }
                if c.isForeignKey { keys.append("FK") }
                if c.isUnique && !c.isPrimaryKey { keys.append("UK") }
                var notes: [String] = []
                if renamed { notes.append(c.name) }
                if !c.comment.isEmpty { notes.append(c.comment) }
                var line = "        \(mermaidType(c.type)) \(attr)"
                if !keys.isEmpty { line += " " + keys.joined(separator: ", ") }
                if !notes.isEmpty { line += " \"\(mermaidString(notes.joined(separator: " — ")))\"" }
                out += line + "\n"
            }
            out += "    }\n"
        }
        if !p.relations.isEmpty { out += "\n" }
        for r in p.relations {
            // Written parent-first: left marker = parent side, right marker = child side.
            let parentSide = r.optional ? "|o" : "||"
            let childSide = r.oneToOne ? "o|" : "o{"
            out += "    \(mermaidEntity(p, r.toTable)) \(parentSide)--\(childSide) \(mermaidEntity(p, r.fromTable)) : \"\(mermaidString(relationLabel(r)))\"\n"
        }
        return out
    }

    private static func mermaidEntity(_ p: Prepared, _ id: String) -> String {
        var label = p.label(id)
        if let t = p.byID[id], let k = kindLabel(t.kind) { label += " (\(k))" }
        return "\"\(mermaidString(label))\""
    }

    /// Mermaid strings (entity names, comments, labels) cannot contain double quotes or line breaks, and
    /// `<…>` would be rendered as HTML. Mermaid's own `#name;` entity codes keep them literal; `#` itself is
    /// encoded too so text like "#12;" is not mistaken for an entity.
    static func mermaidString(_ s: String) -> String {
        var out = ""
        for ch in oneLine(s) {
            switch ch {
            case "#": out += "#35;"
            case "\"": out += "#quot;"
            case "<": out += "#lt;"
            case ">": out += "#gt;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Attribute names: `[A-Za-z_][A-Za-z0-9_]*` (also avoids the PK/FK/UK key tokens).
    /// Returns the safe name and whether it differs from the original.
    static func mermaidAttributeName(_ name: String) -> (String, Bool) {
        var s = String(name.unicodeScalars.map { isASCIIWord($0) ? Character($0) : "_" })
        if s.isEmpty { s = "_" }
        if let f = s.unicodeScalars.first, f >= "0" && f <= "9" { s = "_" + s }
        if ["PK", "FK", "UK"].contains(s.uppercased()) { s += "_" }
        return (s, s != name)
    }

    /// Attribute types: start with a letter; letters, digits, `_`, `-`, `()` and `[]` only.
    /// Common long Postgres spellings are shortened (`character varying(255)` → `varchar(255)`).
    static func mermaidType(_ type: String) -> String {
        var t = type.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        if t.isEmpty { return "unknown" }
        let lower = t.lowercased()
        // MySQL enum('a','b') / set(...) — the value list is not useful (nor valid) here.
        if lower.hasPrefix("enum(") { return "enum" }
        if lower.hasPrefix("set(") { return "set" }
        let short: [(String, String)] = [
            ("character varying", "varchar"), ("timestamp without time zone", "timestamp"),
            ("timestamp with time zone", "timestamptz"), ("time without time zone", "time"),
            ("time with time zone", "timetz"), ("bit varying", "varbit"), ("character", "char"),
            ("double precision", "float8"),
        ]
        for (long, s) in short where lower.hasPrefix(long) {
            // keep any modifier / array suffix, e.g. "character varying(32)[]"
            t = s + t.dropFirst(long.count)
            break
        }
        // timestamp(3) with time zone → timestamptz(3)
        t = t.replacingOccurrences(of: #"^timestamp(\(\d+\)) with time zone"#, with: "timestamptz$1", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"^timestamp(\(\d+\)) without time zone"#, with: "timestamp$1", options: [.regularExpression, .caseInsensitive])
        var out = ""
        for u in t.unicodeScalars {
            if isASCIIWord(u) || "-()[]".unicodeScalars.contains(u) { out.unicodeScalars.append(u) }
            else if out.last != "_" { out += "_" }   // spaces, commas, dots, quotes…
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { return "unknown" }
        if let f = out.unicodeScalars.first, !((f >= "a" && f <= "z") || (f >= "A" && f <= "Z")) { out = "t_" + out }
        return out
    }

    // MARK: - DBML

    /// DBML for dbdiagram.io / dbdocs (parses with `@dbml/core`).
    static func dbml(_ g: ERDGraph) -> String {
        let p = Prepared(g)
        var out = "// \(oneLine(g.title)): \(p.summary). Generated by Tabula.\n\n"
        out += "Project \(dbmlIdent(g.title.isEmpty ? "erd" : oneLine(g.title).replacingOccurrences(of: "\"", with: "'"))) {\n  database_type: '\(p.familyName)'\n}\n"
        for t in p.tables {
            // DBML requires at least one column per table.
            guard !t.columns.isEmpty else {
                out += "\n// \(oneLine(t.id)): no columns, omitted\n"
                continue
            }
            var settings: [String] = []
            var notes: [String] = []
            if t.isExternal { notes.append("External table (outside the exported schema); only referenced columns are shown.") }
            else if let k = kindLabel(t.kind) { notes.append(k.prefix(1).uppercased() + k.dropFirst()) }
            let comment = tableComment(t)
            if !comment.isEmpty { notes.append(comment) }
            if t.isExternal || t.kind != .table { settings.append("headercolor: #7F8C8D") }
            if !notes.isEmpty { settings.append("note: \(dbmlString(notes.joined(separator: "\n")))") }
            out += "\nTable \(dbmlTable(t))\(settings.isEmpty ? "" : " [\(settings.joined(separator: ", "))]") {\n"
            let pk = t.columns.filter(\.isPrimaryKey)
            let width = t.columns.map { dbmlIdent($0.name, keyword: true).count }.max() ?? 0
            for c in t.columns {
                var s: [String] = []
                if c.isPrimaryKey && pk.count == 1 { s.append("pk") }
                if c.defaultValue.map(isSequenceDefault) == true { s.append("increment") }
                if !c.nullable && !(c.isPrimaryKey && pk.count == 1) { s.append("not null") }
                if c.isUnique && !c.isPrimaryKey { s.append("unique") }
                if let d = c.defaultValue, let lit = dbmlDefault(d, column: c, family: g.family) { s.append("default: \(lit)") }
                if !c.comment.isEmpty { s.append("note: \(dbmlString(c.comment))") }
                let name = dbmlIdent(c.name, keyword: true)
                let pad = String(repeating: " ", count: max(0, width - name.count))
                out += "  \(name)\(pad) \(dbmlType(c.type))\(s.isEmpty ? "" : " [\(s.joined(separator: ", "))]")\n"
            }
            if pk.count > 1 {
                out += "\n  indexes {\n    (\(pk.map { dbmlIdent($0.name, keyword: true) }.joined(separator: ", "))) [pk]\n  }\n"
            }
            out += "}\n"
        }
        if !p.relations.isEmpty { out += "\n" }
        var usedNames: Set<String> = []
        var seenEndpoints: Set<String> = []
        for r in p.relations {
            guard let child = p.byID[r.fromTable], let parent = p.byID[r.toTable] else { continue }
            let from = "\(dbmlTable(child)).\(dbmlColumns(r.fromColumns))"
            let to = "\(dbmlTable(parent)).\(dbmlColumns(r.toColumns))"
            // DBML rejects two refs between the same endpoints (duplicate FKs exist in the wild).
            guard seenEndpoints.insert("\(from)|\(to)").inserted else { continue }
            // Names are cosmetic; double quotes cannot be escaped by the legacy parser.
            var name = (r.name.isEmpty ? "\(child.name)_\(r.fromColumns.joined(separator: "_"))_fkey" : oneLine(r.name)).replacingOccurrences(of: "\"", with: "'")
            if usedNames.contains(name) { name = "\(child.name)_\(name)" }
            var n = 2
            let base = name
            while usedNames.contains(name) { name = "\(base)_\(n)"; n += 1 }
            usedNames.insert(name)
            var settings: [String] = []
            if let a = dbmlAction(r.onDelete) { settings.append("delete: \(a)") }
            if let a = dbmlAction(r.onUpdate) { settings.append("update: \(a)") }
            // One-to-one: with `-` the right-hand endpoint is the foreign key.
            let body = r.oneToOne ? "\(to) - \(from)" : "\(from) > \(to)"
            out += "Ref \(dbmlIdent(name)): \(body)\(settings.isEmpty ? "" : " [\(settings.joined(separator: ", "))]")\n"
        }
        return out
    }

    private static let dbmlKeywords: Set<String> = [
        "table", "ref", "note", "indexes", "enum", "project", "tablegroup", "tablepartial", "checks", "records", "as",
    ]

    /// Bare identifier when possible, otherwise `"double quoted"`.
    static func dbmlIdent(_ s: String, keyword: Bool = false) -> String {
        if isSimpleIdentifier(s) && !(keyword && dbmlKeywords.contains(s.lowercased())) { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func dbmlTable(_ t: ERDTable) -> String {
        if let s = t.schema, !s.isEmpty { return "\(dbmlIdent(s)).\(dbmlIdent(t.name))" }
        return dbmlIdent(t.name)
    }

    private static func dbmlColumns(_ cols: [String]) -> String {
        cols.count == 1 ? dbmlIdent(cols[0], keyword: true) : "(" + cols.map { dbmlIdent($0, keyword: true) }.joined(separator: ", ") + ")"
    }

    /// `varchar(255)`, `numeric(10,2)`, `text[]` stay bare; anything else (spaces, quotes, enum lists) is quoted.
    static func dbmlType(_ type: String) -> String {
        // Postgres quotes some type names ("char", "MyEnum"); the quotes are not part of the name and the
        // legacy DBML parser cannot escape them.
        let t = type.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "unknown" }
        if t.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\(\s*\d+\s*(,\s*\d+\s*)?\))?(\[\d*\])*$"#, options: .regularExpression) != nil { return t }
        return "\"" + t.replacingOccurrences(of: "\\", with: "\\\\") + "\""
    }

    /// Single-quoted DBML string (`'''` multi-line strings are avoided; newlines are escaped).
    static func dbmlString(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "'\(e)'"
    }

    private static func dbmlAction(_ rule: String) -> String? {
        let r = rule.trimmingCharacters(in: .whitespaces).lowercased()
        switch r {
        case "cascade", "restrict", "set null", "set default": return r
        default: return nil  // "no action" is the default
        }
    }

    private static func dbmlDefault(_ raw: String, column: ERDColumn, family: DatabaseFamily) -> String? {
        switch classifyDefault(raw, type: column.type, family: family) {
        case .none, .sequence: return nil
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return dbmlString(s)
        case .expression(let e): return "`" + oneLine(e).replacingOccurrences(of: "`", with: "'") + "`"
        }
    }

    // MARK: - Shared helpers

    /// Normalized view of a graph: sorted tables (externals last), relations whose both ends exist,
    /// and short unambiguous display labels (bare name in the main schema, `schema.name` elsewhere).
    struct Prepared {
        let graph: ERDGraph
        let tables: [ERDTable]
        let relations: [ERDRelation]
        let byID: [String: ERDTable]
        let labels: [String: String]

        init(_ g: ERDGraph) {
            graph = g
            tables = g.tables.sorted { a, b in
                if a.isExternal != b.isExternal { return !a.isExternal }
                return ERDTextExport.orderKey(a.id) < ERDTextExport.orderKey(b.id)
            }
            var map: [String: ERDTable] = [:]
            for t in tables where map[t.id] == nil { map[t.id] = t }
            byID = map
            relations = g.relations.filter { map[$0.fromTable] != nil && map[$0.toTable] != nil }.sorted { a, b in
                (ERDTextExport.orderKey(a.fromTable), ERDTextExport.orderKey(a.name), a.fromColumns.joined(separator: ","), a.toTable)
                    < (ERDTextExport.orderKey(b.fromTable), ERDTextExport.orderKey(b.name), b.fromColumns.joined(separator: ","), b.toTable)
            }
            // Main schema = most common schema among the loaded (non-external) tables.
            var counts: [String: Int] = [:]
            for t in tables where !t.isExternal { counts[t.schema ?? "", default: 0] += 1 }
            let main = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? ""
            var lbl: [String: String] = [:]
            for t in tables {
                lbl[t.id] = (t.schema ?? "").isEmpty || (t.schema == main && !t.isExternal) ? t.name : t.id
            }
            // Same bare name in two schemas → fall back to the qualified id for those.
            let groups = Dictionary(grouping: tables.map(\.id)) { lbl[$0]! }
            for (_, ids) in groups where ids.count > 1 { for id in ids { lbl[id] = id } }
            labels = lbl
        }

        func label(_ id: String) -> String { labels[id] ?? id }

        var familyName: String {
            switch graph.family {
            case .postgres: return "PostgreSQL"
            case .mysql: return "MySQL"
            case .sqlite: return "SQLite"
            case .redis: return "Redis"
            }
        }

        var summary: String {
            let n = tables.filter { !$0.isExternal }.count
            let e = tables.count - n
            var s = "\(n) \(n == 1 ? "table" : "tables")"
            if e > 0 { s += " (+\(e) external)" }
            return s + ", \(relations.count) \(relations.count == 1 ? "relationship" : "relationships")"
        }
    }

    /// Case-insensitive, locale-independent sort key with an exact tie-break.
    static func orderKey(_ s: String) -> String { s.lowercased() + "\u{0}" + s }

    static func kindLabel(_ k: ObjectKind) -> String? {
        switch k {
        case .view: return "view"
        case .materializedView: return "materialized view"
        case .foreignTable: return "foreign table"
        default: return nil
        }
    }

    /// Table comment without MySQL's placeholder "VIEW" comment on views.
    static func tableComment(_ t: ERDTable) -> String {
        let c = t.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.kind == .view && c == "VIEW" ? "" : c
    }

    static func relationLabel(_ r: ERDRelation) -> String {
        r.name.isEmpty ? r.fromColumns.joined(separator: ", ") : r.name
    }

    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func isASCIIWord(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || u == "_"
    }

    static func isSimpleIdentifier(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, !(f >= "0" && f <= "9") else { return false }
        return s.unicodeScalars.allSatisfy(isASCIIWord)
    }

    // MARK: Default values

    enum DefaultValue: Equatable {
        case none, null, sequence
        case bool(Bool)
        case number(String)
        case string(String)
        case expression(String)
    }

    private static let numericTypePrefixes = [
        "int", "integer", "smallint", "bigint", "tinyint", "mediumint", "serial", "bigserial", "smallserial",
        "decimal", "numeric", "real", "double", "float", "money", "bit", "year", "number",
    ]

    private static func isNumericType(_ type: String) -> Bool {
        let t = type.lowercased()
        return numericTypePrefixes.contains { t == $0 || t.hasPrefix($0 + "(") || t.hasPrefix($0 + " ") || t.hasPrefix($0 + "unsigned") || (t.hasPrefix($0) && t.dropFirst($0.count).allSatisfy(\.isNumber)) }
    }

    static func isSequenceDefault(_ raw: String) -> Bool {
        raw.lowercased().hasPrefix("nextval(")
    }

    /// Interpret a catalog default: Postgres/SQLite report SQL expressions (`'NL'::bpchar`, `now()`, `1`),
    /// MySQL reports raw values (`NL`, `CURRENT_TIMESTAMP`), MariaDB quotes string literals.
    static func classifyDefault(_ raw: String, type: String, family: DatabaseFamily) -> DefaultValue {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty && family != .mysql { return .none }
        if isSequenceDefault(v) { return .sequence }
        let numberPattern = #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#
        if family == .mysql {
            if v.uppercased() == "NULL" { return .null }
            if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {   // MariaDB-style quoted literal
                return .string(String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
            }
            if v.range(of: numberPattern, options: .regularExpression) != nil, isNumericType(type) || type.lowercased().hasPrefix("bool") { return .number(v) }
            let u = v.uppercased()
            if u.hasPrefix("CURRENT_") || u.hasPrefix("LOCALTIME") || u.hasPrefix("NOW(") || v.hasPrefix("(") || v.hasSuffix(")") && v.contains("(") || u.hasPrefix("B'") || u.hasPrefix("X'") {
                return .expression(v)
            }
            return .string(v)
        }
        // Strip one level of wrapping parentheses: ('x'), (-1)
        if v.hasPrefix("("), v.hasSuffix(")"), v.dropFirst().dropLast().range(of: #"^[^()]*$"#, options: .regularExpression) != nil {
            v = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let cast = #"(::[A-Za-z_"][A-Za-z0-9_ ."\[\]()]*)*$"#
        // 'text'::type
        if let r = v.range(of: #"^'((?:[^']|'')*)'"# + cast, options: .regularExpression), r == v.startIndex..<v.endIndex {
            let close = v[v.index(after: v.startIndex)...].firstQuoteEnd()
            return .string(String(v[v.index(after: v.startIndex)..<close]).replacingOccurrences(of: "''", with: "'"))
        }
        // number, possibly cast or parenthesized: 1, -1.5, (-1)::integer, '1'::int handled above
        if let r = v.range(of: #"^\(?[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\)?"# + cast, options: .regularExpression), r == v.startIndex..<v.endIndex {
            let num = v.replacingOccurrences(of: #"::.*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return .number(num)
        }
        let bare = v.replacingOccurrences(of: #"::[A-Za-z_"][A-Za-z0-9_ ."\[\]()]*$"#, with: "", options: .regularExpression).lowercased()
        if bare == "true" { return .bool(true) }
        if bare == "false" { return .bool(false) }
        if bare == "null" { return .null }
        return .expression(v)
    }
}

private extension Substring {
    /// Index of the quote that closes a SQL string literal starting right after an opening `'`.
    func firstQuoteEnd() -> String.Index {
        var i = startIndex
        while i < endIndex {
            if self[i] == "'" {
                let n = index(after: i)
                if n < endIndex && self[n] == "'" { i = index(after: n); continue }
                return i
            }
            i = index(after: i)
        }
        return endIndex
    }
}
