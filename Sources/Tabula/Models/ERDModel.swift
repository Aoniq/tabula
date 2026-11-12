import Foundation

// MARK: - Graph model (pure data; shared by the canvas, image and text exporters)

struct ERDColumn: Hashable, Codable {
    var name: String
    var type: String
    var isPrimaryKey = false
    var isForeignKey = false
    var isUnique = false
    var nullable = true
    var defaultValue: String?
    var comment = ""
}

struct ERDTable: Identifiable, Hashable, Codable {
    var schema: String?
    var name: String
    var kind: ObjectKind = .table
    var columns: [ERDColumn] = []
    var comment = ""
    /// Referenced from this schema but living elsewhere (only referenced columns are known).
    var isExternal = false

    /// Stable identifier: "schema.name" (or just "name" when there is no schema).
    var id: String { ERDTable.makeID(schema: schema, name: name) }
    var displayName: String { isExternal ? id : name }

    static func makeID(schema: String?, name: String) -> String {
        if let schema, !schema.isEmpty { return "\(schema).\(name)" }
        return name
    }
}

struct ERDRelation: Identifiable, Hashable, Codable {
    var name: String
    /// Child (referencing) table id and columns.
    var fromTable: String
    var fromColumns: [String]
    /// Parent (referenced) table id and columns.
    var toTable: String
    var toColumns: [String]
    var onDelete = ""
    var onUpdate = ""
    /// Any FK column nullable → the child may exist without a parent (0..1 on the parent side).
    var optional = false
    /// FK columns are themselves unique/PK → one-to-one instead of one-to-many.
    var oneToOne = false

    var id: String { "\(fromTable)|\(name)|\(fromColumns.joined(separator: ","))" }
}

struct ERDGraph: Codable {
    var title: String
    var family: DatabaseFamily
    var tables: [ERDTable]
    var relations: [ERDRelation]

    func table(_ id: String) -> ERDTable? { tables.first { $0.id == id } }

    /// Tables directly connected to `id` (both directions), including itself.
    func neighborhood(of id: String) -> Set<String> {
        var s: Set<String> = [id]
        for r in relations {
            if r.fromTable == id { s.insert(r.toTable) }
            if r.toTable == id { s.insert(r.fromTable) }
        }
        return s
    }

    /// Subgraph containing only the given tables and the relations between them.
    func subgraph(_ ids: Set<String>) -> ERDGraph {
        ERDGraph(title: title, family: family,
                 tables: tables.filter { ids.contains($0.id) },
                 relations: relations.filter { ids.contains($0.fromTable) && ids.contains($0.toTable) })
    }
}

// MARK: - Loading

enum ERDLoader {
    /// Load tables, columns and foreign keys of the workspace's current schema/database.
    @MainActor
    static func load(_ ws: WorkspaceState, includeViews: Bool = true) async throws -> ERDGraph {
        let family = ws.family
        let title = family == .postgres ? "\(ws.currentDatabase).\(ws.currentSchema ?? "public")" : (ws.currentDatabase.isEmpty ? ws.config.displayName : ws.currentDatabase)
        switch family {
        case .postgres:
            let schema = ws.currentSchema ?? "public"
            return try await ws.run { d in try loadPostgres(d, schema: schema, title: title, includeViews: includeViews) }
        case .mysql:
            let db = ws.currentDatabase
            return try await ws.run { d in try loadMySQL(d, database: db, title: title, includeViews: includeViews) }
        case .sqlite:
            let objects = ws.objects.filter { $0.kind == .table || (includeViews && $0.kind == .view) }
            return try await ws.run { d in try loadGeneric(d, objects: objects, title: title, family: family) }
        case .redis:
            throw DBError("ER diagrams are not available for Redis.")
        }
    }

    private static func finish(_ tablesByID: [String: ERDTable], order: [String], relations: [ERDRelation], title: String, family: DatabaseFamily) -> ERDGraph {
        var tables = tablesByID
        var ord = order
        var rels: [ERDRelation] = []
        for var r in relations {
            // Placeholder for tables referenced outside the loaded scope.
            if tables[r.toTable] == nil {
                let parts = r.toTable.split(separator: ".", maxSplits: 1).map(String.init)
                var ext = ERDTable(schema: parts.count == 2 ? parts[0] : nil, name: parts.last ?? r.toTable)
                ext.isExternal = true
                ext.columns = r.toColumns.map { ERDColumn(name: $0, type: "", isPrimaryKey: true, nullable: false) }
                tables[r.toTable] = ext
                ord.append(r.toTable)
            }
            guard var child = tables[r.fromTable] else { continue }
            var anyNullable = false
            for c in r.fromColumns {
                if let i = child.columns.firstIndex(where: { $0.name == c }) {
                    child.columns[i].isForeignKey = true
                    if child.columns[i].nullable { anyNullable = true }
                }
            }
            tables[r.fromTable] = child
            r.optional = anyNullable
            // one-to-one when the FK columns are exactly the PK, or a single unique column
            let pk = child.columns.filter(\.isPrimaryKey).map(\.name)
            let single = r.fromColumns.count == 1 ? child.columns.first { $0.name == r.fromColumns[0] } : nil
            r.oneToOne = (!pk.isEmpty && Set(pk) == Set(r.fromColumns)) || (single?.isUnique ?? false)
            rels.append(r)
        }
        return ERDGraph(title: title, family: family, tables: ord.compactMap { tables[$0] }, relations: rels)
    }

    private static func splitList(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map(String.init)
    }

    static func loadPostgres(_ d: DatabaseDriver, schema: String, title: String, includeViews: Bool) throws -> ERDGraph {
        let s = d.dialect.literal(schema)
        let kinds = includeViews ? "('r','p','v','m','f')" : "('r','p','f')"
        var tables: [String: ERDTable] = [:]
        var order: [String] = []
        for r in try d.rows("""
            SELECT c.relname, c.relkind, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
              pg_catalog.pg_get_expr(ad.adbin, ad.adrelid), COALESCE(pg_catalog.col_description(c.oid, a.attnum), ''),
              COALESCE(pg_catalog.obj_description(c.oid, 'pg_class'), '')
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
            WHERE n.nspname = \(s) AND c.relkind IN \(kinds) AND NOT c.relispartition
            ORDER BY c.relname, a.attnum
            """) {
            guard let tname = r[0], let col = r[2] else { continue }
            let id = ERDTable.makeID(schema: schema, name: tname)
            if tables[id] == nil {
                let kind: ObjectKind
                switch r[1] {
                case "v": kind = .view
                case "m": kind = .materializedView
                case "f": kind = .foreignTable
                default: kind = .table
                }
                tables[id] = ERDTable(schema: schema, name: tname, kind: kind, comment: r[7] ?? "")
                order.append(id)
            }
            tables[id]?.columns.append(ERDColumn(name: col, type: r[3] ?? "", nullable: r[4] == "t", defaultValue: r[5], comment: r[6] ?? ""))
        }
        // primary keys and single-column unique constraints
        for r in try d.rows("""
            SELECT c.relname, con.contype,
              (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                 JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum)
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(s) AND con.contype IN ('p','u')
            """) {
            guard let tname = r[0] else { continue }
            let id = ERDTable.makeID(schema: schema, name: tname)
            let cols = splitList(r[2])
            guard var t = tables[id] else { continue }
            for (i, c) in t.columns.enumerated() where cols.contains(c.name) {
                if r[1] == "p" { t.columns[i].isPrimaryKey = true }
                if r[1] == "u" && cols.count == 1 { t.columns[i].isUnique = true }
            }
            tables[id] = t
        }
        func rule(_ c: String?) -> String {
            switch c {
            case "r": return "RESTRICT"
            case "c": return "CASCADE"
            case "n": return "SET NULL"
            case "d": return "SET DEFAULT"
            default: return "NO ACTION"
            }
        }
        var relations: [ERDRelation] = []
        for r in try d.rows("""
            SELECT con.conname, c.relname,
              (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                 JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum),
              fn.nspname, ft.relname,
              (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                 JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum),
              con.confupdtype, con.confdeltype
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class ft ON ft.oid = con.confrelid
            JOIN pg_catalog.pg_namespace fn ON fn.oid = ft.relnamespace
            WHERE con.contype = 'f' AND n.nspname = \(s) AND NOT c.relispartition
            ORDER BY c.relname, con.conname
            """) {
            guard let name = r[0], let child = r[1], let parent = r[4] else { continue }
            relations.append(ERDRelation(name: name, fromTable: ERDTable.makeID(schema: schema, name: child), fromColumns: splitList(r[2]),
                                         toTable: ERDTable.makeID(schema: r[3], name: parent), toColumns: splitList(r[5]),
                                         onDelete: rule(r[7]), onUpdate: rule(r[6])))
        }
        return finish(tables, order: order, relations: relations, title: title, family: .postgres)
    }

    static func loadMySQL(_ d: DatabaseDriver, database: String, title: String, includeViews: Bool) throws -> ERDGraph {
        let db = database.isEmpty ? "DATABASE()" : d.dialect.literal(database)
        var tables: [String: ERDTable] = [:]
        var order: [String] = []
        for r in try d.rows("""
            SELECT c.TABLE_NAME, t.TABLE_TYPE, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT, c.COLUMN_KEY,
              c.COLUMN_COMMENT, t.TABLE_COMMENT
            FROM information_schema.COLUMNS c
            JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
            WHERE c.TABLE_SCHEMA = \(db)
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
            """) {
            guard let tname = r[0], let col = r[2] else { continue }
            let isView = r[1] == "VIEW"
            if isView && !includeViews { continue }
            if tables[tname] == nil {
                tables[tname] = ERDTable(schema: nil, name: tname, kind: isView ? .view : .table, comment: r[8] ?? "")
                order.append(tname)
            }
            tables[tname]?.columns.append(ERDColumn(name: col, type: r[3] ?? "", isPrimaryKey: r[6] == "PRI", isUnique: r[6] == "UNI",
                                                    nullable: r[4] == "YES", defaultValue: r[5], comment: r[7] ?? ""))
        }
        var relations: [ERDRelation] = []
        for r in try d.rows("""
            SELECT k.CONSTRAINT_NAME, k.TABLE_NAME, GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
              k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
              GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
              MIN(rc.UPDATE_RULE), MIN(rc.DELETE_RULE)
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
              ON rc.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND rc.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND rc.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = \(db) AND k.REFERENCED_TABLE_NAME IS NOT NULL
            GROUP BY k.CONSTRAINT_NAME, k.TABLE_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME
            ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME
            """) {
            guard let name = r[0], let child = r[1], let parent = r[4] else { continue }
            let sameDB = r[3] == nil || r[3] == database || database.isEmpty
            relations.append(ERDRelation(name: name, fromTable: child, fromColumns: splitList(r[2]),
                                         toTable: sameDB ? parent : ERDTable.makeID(schema: r[3], name: parent), toColumns: splitList(r[5]),
                                         onDelete: r[7] ?? "", onUpdate: r[6] ?? ""))
        }
        return finish(tables, order: order, relations: relations, title: title, family: .mysql)
    }

    /// Per-object fallback using the driver's metadata API (SQLite, small schemas).
    static func loadGeneric(_ d: DatabaseDriver, objects: [DBObject], title: String, family: DatabaseFamily) throws -> ERDGraph {
        var tables: [String: ERDTable] = [:]
        var order: [String] = []
        var relations: [ERDRelation] = []
        for o in objects {
            let id = ERDTable.makeID(schema: o.schema, name: o.name)
            let cols = try d.columns(of: o)
            let uniques = Set(((try? d.indexes(of: o)) ?? []).filter { $0.unique && !$0.primary && $0.columns.count == 1 }.compactMap(\.columns.first))
            tables[id] = ERDTable(schema: o.schema, name: o.name, kind: o.kind, columns: cols.map {
                ERDColumn(name: $0.name, type: $0.type, isPrimaryKey: $0.isPrimaryKey, isUnique: uniques.contains($0.name),
                          nullable: $0.nullable && !$0.isPrimaryKey, defaultValue: $0.defaultValue, comment: $0.comment)
            })
            order.append(id)
            if o.kind == .table {
                for fk in (try? d.foreignKeys(of: o)) ?? [] {
                    relations.append(ERDRelation(name: fk.name, fromTable: id, fromColumns: fk.columns,
                                                 toTable: ERDTable.makeID(schema: fk.refSchema ?? o.schema, name: fk.refTable),
                                                 toColumns: fk.refColumns, onDelete: fk.onDelete, onUpdate: fk.onUpdate))
                }
            }
        }
        return finish(tables, order: order, relations: relations, title: title, family: family)
    }
}
