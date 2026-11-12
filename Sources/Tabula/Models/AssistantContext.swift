import Foundation

/// Builds the schema context sent to Claude. Only metadata (names, types, keys) — never row data.
enum AssistantContext {
    static let maxDetailedTables = 30
    static let maxDetailChars = 12_000
    static let maxObjectListChars = 8_000
    static let maxEditorSQLChars = 12_000
    /// Schemas with at most this many tables/views get all their column definitions (within the char cap).
    static let smallSchemaTables = 30

    struct Snapshot {
        var engine: String
        var family: DatabaseFamily
        var version: String
        var database: String
        var schema: String?
        var safeMode: SafeMode
        var objects: [DBObject]
        var detailed: [(object: DBObject, columns: [ColumnInfo])]
    }

    // MARK: System prompt

    static func systemPrompt(_ s: Snapshot) -> String {
        var p = """
        You are the SQL assistant built into Tabula, a native macOS database client. You help the user write, explain, \
        fix and optimize queries for the database they are connected to.

        """
        p += "\nGuidelines:\n"
        p += "- " + dialectRule(s) + "\n"
        p += "- Only use tables and columns that exist in the schema below. If something you need is missing or ambiguous, say so (or ask) instead of inventing names. The user can mention @table_name to show you a table's columns.\n"
        if s.family == .redis {
            p += "- Put every runnable command in a ```redis fenced code block (one command per line). Tabula shows Copy / Insert / Run buttons on these blocks.\n"
        } else {
            p += "- Put every runnable statement in a ```sql fenced code block, terminated with a semicolon. Tabula shows Copy / Insert / Run buttons on these blocks, so keep each block self-contained and free of placeholders where possible. Use separate blocks for alternatives.\n"
        }
        p += "- Prefer read-only queries. If a statement modifies data or schema, say so explicitly before the block, and wrap multi-statement changes in a transaction where the engine supports it.\n"
        switch s.safeMode {
        case .readOnly: p += "- This connection is in read-only safe mode: Tabula blocks writes, so offer read-only alternatives.\n"
        case .confirmWrites: p += "- Tabula asks the user to confirm before running statements that write.\n"
        case .off: break
        }
        p += "- You cannot see row data or query results; don't claim to know specific values. Suggest a query that would reveal them instead.\n"
        p += "- Be concise: short Markdown prose (bullets, `inline code`, **bold**), no long preambles. The chat panel is narrow, so avoid wide tables and keep SQL lines reasonably short.\n"
        p += "- Context from the editor (current query, its last error, the table being viewed) may be attached to user messages inside <editor> tags.\n"

        p += "\n<connection>\n"
        p += "Engine: \(s.engine)\n"
        if !s.version.isEmpty { p += "Server version: \(String(s.version.prefix(160)))\n" }
        if !s.database.isEmpty { p += "Database: \(s.database)\n" }
        if let schema = s.schema, !schema.isEmpty { p += "Current schema: \(schema)\n" }
        p += "</connection>\n"

        p += "\n<objects>\n" + objectList(s.objects) + "</objects>\n"

        if !s.detailed.isEmpty {
            p += "\n<table_definitions>\n"
            p += s.detailed.map { tableDefinition($0.object, $0.columns) }.joined(separator: "\n")
            p += "</table_definitions>\n"
        }
        return p
    }

    static func dialectRule(_ s: Snapshot) -> String {
        switch s.family {
        case .postgres:
            let compat = s.engine == "PostgreSQL" ? "" : " (PostgreSQL-compatible; respect \(s.engine)'s limitations)"
            return "Write SQL for \(s.engine)\(compat). Quote identifiers with double quotes only when needed."
        case .mysql:
            return "Write SQL in the \(s.engine) dialect. Quote identifiers with backticks only when needed; use LIMIT for paging."
        case .sqlite:
            return "Write SQL in the SQLite dialect (no RIGHT/FULL JOIN on old versions, limited ALTER TABLE, dynamic typing)."
        case .redis:
            return "This is a Redis server: answer with Redis commands, not SQL."
        }
    }

    static func objectList(_ objects: [DBObject]) -> String {
        var out = ""
        let groups: [(ObjectKind, Int)] = [(.table, 2000), (.view, 2000), (.materializedView, 500), (.foreignTable, 500),
                                           (.function, 150), (.procedure, 100), (.sequence, 0), (.trigger, 0)]
        for (kind, limit) in groups {
            let names = objects.filter { $0.kind == kind }.map(\.displayName)
            guard !names.isEmpty else { continue }
            var line = "\(kind.label) (\(names.count))"
            if limit > 0 {
                let shown = names.prefix(limit)
                line += ": " + shown.joined(separator: ", ")
                if names.count > shown.count { line += ", … (\(names.count - shown.count) more)" }
            }
            out += line + "\n"
        }
        if out.isEmpty { return "(no objects loaded)\n" }
        if out.count > maxObjectListChars {
            out = String(out.prefix(maxObjectListChars)) + " … (truncated)\n"
        }
        return out
    }

    static func tableDefinition(_ o: DBObject, _ cols: [ColumnInfo]) -> String {
        let kind: String
        switch o.kind {
        case .view: kind = "view"
        case .materializedView: kind = "materialized view"
        case .foreignTable: kind = "foreign table"
        default: kind = "table"
        }
        let name = [o.schema, o.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
        var s = "\(kind) \(name)"
        let pk = cols.filter(\.isPrimaryKey).map(\.name)
        if !pk.isEmpty { s += " — primary key (\(pk.joined(separator: ", ")))" }
        s += "\n"
        if cols.isEmpty { s += "  (columns unknown)\n" }
        for c in cols {
            var line = "  \(c.name) \(c.type)"
            if c.isPrimaryKey { line += " PK" }
            if !c.nullable { line += " NOT NULL" }
            if let d = c.defaultValue, !d.isEmpty { line += " DEFAULT \(d.prefix(60))" }
            if !c.extra.isEmpty { line += " \(c.extra.prefix(40))" }
            if !c.comment.isEmpty { line += " -- \(c.comment.replacingOccurrences(of: "\n", with: " ").prefix(80))" }
            s += line + "\n"
        }
        return s
    }

    // MARK: Picking relevant tables

    static func identifiers(in text: String) -> Set<String> {
        var out = Set<String>()
        var cur = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                cur.append(ch)
            } else {
                if !cur.isEmpty { out.insert(cur); cur = "" }
            }
        }
        if !cur.isEmpty { out.insert(cur) }
        return out
    }

    /// `@name` / `@schema.name` mentions.
    static func mentions(in text: String) -> [String] {
        var out: [String] = []
        var i = text.startIndex
        while let at = text[i...].firstIndex(of: "@") {
            let start = text.index(after: at)
            let end = text[start...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$") } ?? text.endIndex
            var name = String(text[start..<end])
            while name.hasSuffix(".") { name.removeLast() }
            if !name.isEmpty { out.append(name) }
            i = end
            if i == text.endIndex { break }
        }
        return out
    }

    static func matches(_ o: DBObject, _ ids: Set<String>, fuzzy: Bool) -> Bool {
        let n = o.name.lowercased()
        if ids.contains(n) { return true }
        guard fuzzy, n.count >= 4 else { return false }
        if n.hasSuffix("s") && ids.contains(String(n.dropLast())) { return true }
        if n.hasSuffix("es") && ids.contains(String(n.dropLast(2))) { return true }
        if ids.contains(n + "s") || ids.contains(n + "es") { return true }
        return false
    }

    /// Orders candidate tables: explicit mentions, the open table, tables in the editor SQL,
    /// tables named in the newest message, then older conversation; small schemas get the rest too.
    static func relevantTables(objects: [DBObject], mentions: [String], pinned: DBObject?, sql: String?,
                               texts newestFirst: [String]) -> [DBObject] {
        let candidates = objects.filter(\.kind.isBrowsable)
        var out: [DBObject] = []
        func add(_ o: DBObject) { if !out.contains(o) { out.append(o) } }

        for m in mentions {
            let last = m.split(separator: ".").last.map(String.init) ?? m
            if let o = candidates.first(where: { $0.name.caseInsensitiveCompare(last) == .orderedSame }) { add(o) }
        }
        if let pinned, candidates.contains(pinned) { add(pinned) }
        if let sql, !sql.isEmpty {
            let ids = identifiers(in: sql)
            candidates.filter { matches($0, ids, fuzzy: false) }.forEach(add)
        }
        for t in newestFirst {
            let ids = identifiers(in: t)
            candidates.filter { matches($0, ids, fuzzy: true) }.forEach(add)
        }
        if candidates.count <= smallSchemaTables {
            candidates.filter { $0.kind == .table }.forEach(add)
            candidates.forEach(add)
        }
        return out
    }

    // MARK: Live workspace

    /// Gather the system prompt for a workspace. `texts` are conversation texts, newest first.
    @MainActor
    static func systemPrompt(ws: WorkspaceState, texts newestFirst: [String]) async -> String {
        let allText = newestFirst.joined(separator: "\n")
        let sql = ws.selectedQueryTab?.text ?? ws.selectedTableTab?.lastQuery
        let ordered = relevantTables(objects: ws.objects, mentions: mentions(in: allText),
                                     pinned: ws.selectedTableTab?.object, sql: sql, texts: newestFirst)
        var detailed: [(DBObject, [ColumnInfo])] = []
        var used = 0
        if ws.isConnected && ws.family != .redis {
            for o in ordered.prefix(maxDetailedTables) {
                let cols = await ws.columns(for: o)
                let size = tableDefinition(o, cols).count
                if used + size > maxDetailChars && !detailed.isEmpty { break }
                detailed.append((o, cols))
                used += size
            }
        }
        let snap = Snapshot(engine: ws.config.kind.displayName, family: ws.family, version: ws.serverVersion,
                            database: ws.currentDatabase, schema: ws.currentSchema, safeMode: ws.config.safeMode,
                            objects: ws.objects, detailed: detailed.map { (object: $0.0, columns: $0.1) })
        var prompt = systemPrompt(snap)
        if prompt.count > maxObjectListChars + maxDetailChars + 6_000 {
            prompt = String(prompt.prefix(maxObjectListChars + maxDetailChars + 6_000)) + "\n…(truncated)\n"
        }
        return prompt
    }

    struct EditorAttachment: Equatable {
        var label: String      // shown on the user bubble
        var text: String       // sent to the API
        var signature: String  // to avoid re-sending unchanged context
        var hasQuery: Bool
        var hasError: Bool
    }

    /// The editor state worth attaching to a user turn: current query (or selection), its last error, the open table.
    @MainActor
    static func editorAttachment(ws: WorkspaceState) -> EditorAttachment? {
        if let q = ws.selectedQueryTab {
            let sql = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty || q.error != nil else { return nil }
            var t = "<editor tab=\"\(q.title)\">\n"
            if !sql.isEmpty {
                t += "Current query:\n```sql\n\(clip(sql, maxEditorSQLChars))\n```\n"
            }
            if let sel = q.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty, sel != sql {
                t += "Selected part:\n```sql\n\(clip(sel, 4_000))\n```\n"
            }
            if let e = q.error { t += "Last error when running it:\n\(clip(e, 2_000))\n" }
            t += "</editor>"
            return EditorAttachment(label: q.title + (q.error != nil ? " + error" : ""), text: t,
                                    signature: t, hasQuery: !sql.isEmpty, hasError: q.error != nil)
        }
        if let tt = ws.selectedTableTab {
            let name = [tt.object.schema, tt.object.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
            var t = "<editor>\nThe user is viewing \(tt.object.kind == .table ? "table" : "view") \(name)"
            if !tt.appliedFilters.isEmpty { t += " with filters applied" }
            t += ".\n"
            if !tt.lastQuery.isEmpty { t += "Query used to load it:\n```sql\n\(clip(tt.lastQuery, 4_000))\n```\n" }
            if let e = tt.error { t += "Last error:\n\(clip(e, 2_000))\n" }
            t += "</editor>"
            return EditorAttachment(label: tt.object.name + (tt.error != nil ? " + error" : ""), text: t, signature: t,
                                    hasQuery: !tt.lastQuery.isEmpty, hasError: tt.error != nil)
        }
        return nil
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n…(truncated)"
    }
}
