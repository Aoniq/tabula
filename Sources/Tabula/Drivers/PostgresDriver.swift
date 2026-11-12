import Foundation
import CLibPQ

final class PostgresDriver: DatabaseDriver {
    let dialect = SQLDialect(family: .postgres)
    private let config: ConnectionConfig
    private let password: String
    private let host: String
    private let port: Int

    private var conn: OpaquePointer?
    private var cancelHandle: OpaquePointer?
    private let cancelLock = NSLock()
    private var typeNames: [UInt32: String] = [:]
    private(set) var currentDatabase: String

    init(config: ConnectionConfig, password: String, host: String, port: Int) {
        self.config = config
        self.password = password
        self.host = host
        self.port = port
        self.currentDatabase = config.database.isEmpty ? (config.kind == .cockroachdb ? "defaultdb" : "postgres") : config.database
    }

    deinit { close() }

    func connect() throws {
        try open(database: currentDatabase)
    }

    private func open(database: String) throws {
        var params: [(String, String)] = [
            ("host", host),
            ("port", String(port)),
            ("dbname", database),
            ("connect_timeout", "10"),
            ("application_name", "Tabula"),
            ("client_encoding", "UTF8"),
            ("sslmode", config.ssl.mode.rawValue),
        ]
        if !config.user.isEmpty { params.append(("user", config.user)) }
        if !password.isEmpty { params.append(("password", password)) }
        if !config.ssl.caCertPath.isEmpty { params.append(("sslrootcert", config.ssl.caCertPath)) }
        if !config.ssl.clientCertPath.isEmpty { params.append(("sslcert", config.ssl.clientCertPath)) }
        if !config.ssl.clientKeyPath.isEmpty { params.append(("sslkey", config.ssl.clientKeyPath)) }

        let keys = params.map { strdup($0.0) }
        let values = params.map { strdup($0.1) }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        var kp: [UnsafePointer<CChar>?] = keys.map { UnsafePointer($0) }
        var vp: [UnsafePointer<CChar>?] = values.map { UnsafePointer($0) }
        kp.append(nil)
        vp.append(nil)

        let c = PQconnectdbParams(kp, vp, 0)
        if PQstatus(c) != CONNECTION_OK {
            let msg = c.map { String(cString: PQerrorMessage($0)) } ?? "Connection failed"
            PQfinish(c)
            throw DBError(msg)
        }
        closeConnectionOnly()
        conn = c
        cancelLock.lock()
        cancelHandle = PQgetCancel(c)
        cancelLock.unlock()
        currentDatabase = database
        loadTypeNames()
        if !config.startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? execute(config.startupSQL)
        }
    }

    private func closeConnectionOnly() {
        cancelLock.lock()
        if let h = cancelHandle { PQfreeCancel(h) }
        cancelHandle = nil
        cancelLock.unlock()
        if let c = conn { PQfinish(c) }
        conn = nil
    }

    func close() { closeConnectionOnly() }

    private func loadTypeNames() {
        guard let rows = try? rows("SELECT oid, typname FROM pg_catalog.pg_type") else { return }
        for r in rows {
            if let o = r[0], let oid = UInt32(o), let name = r[1] { typeNames[oid] = name }
        }
    }

    func cancel() {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard let h = cancelHandle else { return }
        var buf = [CChar](repeating: 0, count: 256)
        _ = PQcancel(h, &buf, 256)
    }

    func serverVersion() -> String {
        (try? scalar("SELECT version()")) ?? "PostgreSQL"
    }

    func execute(_ sql: String) throws -> [QueryResult] {
        guard let conn else { throw DBError("Not connected") }
        if PQstatus(conn) != CONNECTION_OK {
            PQreset(conn)
            if PQstatus(conn) != CONNECTION_OK { throw DBError("Connection lost: " + String(cString: PQerrorMessage(conn))) }
        }
        let start = Date()
        guard PQsendQuery(conn, sql) == 1 else {
            throw DBError(String(cString: PQerrorMessage(conn)))
        }
        var results: [QueryResult] = []
        var error: String?
        while let res = PQgetResult(conn) {
            defer { PQclear(res) }
            let status = PQresultStatus(res)
            if status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE {
                var r = QueryResult()
                let nf = Int(PQnfields(res))
                for i in 0..<nf {
                    let name = String(cString: PQfname(res, Int32(i)))
                    let oid = PQftype(res, Int32(i))
                    r.columns.append(ResultColumn(name: name, typeName: typeNames[oid] ?? "oid:\(oid)"))
                }
                let nt = Int(PQntuples(res))
                let keep = min(nt, maxResultRows)
                r.truncated = nt > keep
                r.rows.reserveCapacity(keep)
                for row in 0..<keep {
                    var vals = [String?]()
                    vals.reserveCapacity(nf)
                    for col in 0..<nf {
                        if PQgetisnull(res, Int32(row), Int32(col)) == 1 {
                            vals.append(nil)
                        } else {
                            vals.append(String(cString: PQgetvalue(res, Int32(row), Int32(col))))
                        }
                    }
                    r.rows.append(vals)
                }
                r.message = String(cString: PQcmdStatus(res))
                r.statement = sql
                r.duration = Date().timeIntervalSince(start)
                results.append(r)
            } else if status == PGRES_COMMAND_OK {
                var r = QueryResult()
                r.message = String(cString: PQcmdStatus(res))
                let tuples = String(cString: PQcmdTuples(res))
                r.affectedRows = Int(tuples)
                r.statement = sql
                r.duration = Date().timeIntervalSince(start)
                results.append(r)
            } else if status == PGRES_EMPTY_QUERY {
                continue
            } else if status == PGRES_COPY_IN || status == PGRES_COPY_OUT {
                error = error ?? "COPY FROM STDIN / TO STDOUT is not supported in the query editor."
                if status == PGRES_COPY_IN { _ = PQputCopyEnd(conn, "not supported") }
            } else {
                let msg = String(cString: PQresultErrorMessage(res))
                if error == nil { error = msg.isEmpty ? String(cString: PQerrorMessage(conn)) : msg }
            }
        }
        if let error { throw DBError(error) }
        return results
    }

    // MARK: Metadata

    func listDatabases() throws -> [String] {
        try rows("SELECT datname FROM pg_catalog.pg_database WHERE NOT datistemplate ORDER BY datname").compactMap { $0[0] }
    }

    func useDatabase(_ name: String) throws {
        guard name != currentDatabase else { return }
        try open(database: name)
    }

    func listSchemas() throws -> [String] {
        try rows("""
            SELECT nspname FROM pg_catalog.pg_namespace
            WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema' AND nspname <> 'crdb_internal'
            ORDER BY nspname = 'public' DESC, nspname
            """).compactMap { $0[0] }
    }

    func defaultSchema() -> String? {
        (try? scalar("SELECT current_schema()")) ?? "public"
    }

    func listObjects(schema: String?) throws -> [DBObject] {
        let s = dialect.literal(schema ?? "public")
        var out: [DBObject] = []
        for r in try rows("""
            SELECT c.relname, c.relkind FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(s) AND c.relkind IN ('r','p','v','m','f','S')
            ORDER BY c.relname
            """) {
            guard let name = r[0], let k = r[1] else { continue }
            let kind: ObjectKind
            switch k {
            case "r", "p": kind = .table
            case "v": kind = .view
            case "m": kind = .materializedView
            case "f": kind = .foreignTable
            default: kind = .sequence
            }
            out.append(DBObject(schema: schema, name: name, kind: kind))
        }
        // functions / procedures (prokind exists in PG 11+; fall back for older servers)
        let fnRows = (try? rows("""
            SELECT p.proname, p.prokind, pg_catalog.pg_get_function_identity_arguments(p.oid)
            FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = \(s) AND p.prokind IN ('f','p') ORDER BY p.proname
            """)) ?? (try? rows("""
            SELECT p.proname, 'f', pg_catalog.pg_get_function_identity_arguments(p.oid)
            FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = \(s) ORDER BY p.proname
            """)) ?? []
        for r in fnRows {
            guard let name = r[0] else { continue }
            out.append(DBObject(schema: schema, name: name, kind: r[1] == "p" ? .procedure : .function, detail: r[2] ?? ""))
        }
        for r in (try? rows("""
            SELECT DISTINCT t.tgname, c.relname FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(s) AND NOT t.tgisinternal ORDER BY t.tgname
            """)) ?? [] {
            guard let name = r[0] else { continue }
            out.append(DBObject(schema: schema, name: name, kind: .trigger, detail: r[1] ?? ""))
        }
        return out
    }

    private func relFilter(_ o: DBObject) -> String {
        "n.nspname = \(dialect.literal(o.schema ?? "public")) AND c.relname = \(dialect.literal(o.name))"
    }

    func columns(of o: DBObject) throws -> [ColumnInfo] {
        try rows("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
              pg_catalog.pg_get_expr(d.adbin, d.adrelid),
              COALESCE((SELECT true FROM pg_catalog.pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey) LIMIT 1), false),
              COALESCE(pg_catalog.col_description(c.oid, a.attnum), ''),
              CASE WHEN a.attidentity IN ('a','d') THEN 'identity' ELSE '' END
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE \(relFilter(o)) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).map {
            ColumnInfo(name: $0[0] ?? "", type: $0[1] ?? "", nullable: $0[2] == "t", defaultValue: $0[3],
                       isPrimaryKey: $0[4] == "t", comment: $0[5] ?? "", extra: $0[6] ?? "")
        }
    }

    func indexes(of o: DBObject) throws -> [IndexInfo] {
        try rows("""
            SELECT i.relname, ix.indisunique, ix.indisprimary, pg_catalog.pg_get_indexdef(ix.indexrelid),
              array_to_string(ARRAY(SELECT pg_catalog.pg_get_indexdef(ix.indexrelid, k + 1, true)
                FROM generate_subscripts(ix.indkey, 1) AS k ORDER BY k), ',')
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class c ON c.oid = ix.indrelid
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE \(relFilter(o)) ORDER BY ix.indisprimary DESC, i.relname
            """).map {
            IndexInfo(name: $0[0] ?? "", columns: ($0[4] ?? "").split(separator: ",").map(String.init),
                      unique: $0[1] == "t", primary: $0[2] == "t", definition: $0[3] ?? "")
        }
    }

    func foreignKeys(of o: DBObject) throws -> [ForeignKeyInfo] {
        func rule(_ c: String?) -> String {
            switch c {
            case "r": return "RESTRICT"
            case "c": return "CASCADE"
            case "n": return "SET NULL"
            case "d": return "SET DEFAULT"
            default: return "NO ACTION"
            }
        }
        return try rows("""
            SELECT con.conname,
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
            WHERE con.contype = 'f' AND \(relFilter(o)) ORDER BY con.conname
            """).map {
            ForeignKeyInfo(name: $0[0] ?? "", columns: ($0[1] ?? "").split(separator: ",").map(String.init),
                           refSchema: $0[2], refTable: $0[3] ?? "", refColumns: ($0[4] ?? "").split(separator: ",").map(String.init),
                           onUpdate: rule($0[5]), onDelete: rule($0[6]))
        }
    }

    func ddl(of o: DBObject) throws -> String {
        let q = dialect.qualified(o)
        switch o.kind {
        case .view:
            let def = try scalar("SELECT pg_catalog.pg_get_viewdef(\(dialect.literal(q))::regclass, true)") ?? ""
            return "CREATE OR REPLACE VIEW \(q) AS\n\(def)"
        case .materializedView:
            let def = try scalar("SELECT pg_catalog.pg_get_viewdef(\(dialect.literal(q))::regclass, true)") ?? ""
            return "CREATE MATERIALIZED VIEW \(q) AS\n\(def)"
        case .function, .procedure:
            return try scalar("""
                SELECT pg_catalog.pg_get_functiondef(p.oid) FROM pg_catalog.pg_proc p
                JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = \(dialect.literal(o.schema ?? "public")) AND p.proname = \(dialect.literal(o.name))
                  AND pg_catalog.pg_get_function_identity_arguments(p.oid) = \(dialect.literal(o.detail))
                LIMIT 1
                """) ?? ""
        case .trigger:
            return try scalar("""
                SELECT pg_catalog.pg_get_triggerdef(t.oid, true) FROM pg_catalog.pg_trigger t
                JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(dialect.literal(o.schema ?? "public")) AND t.tgname = \(dialect.literal(o.name)) LIMIT 1
                """).map { $0 + ";" } ?? ""
        case .sequence:
            let r = try rows("SELECT start_value, increment_by, min_value, max_value, cycle FROM pg_catalog.pg_sequences WHERE schemaname = \(dialect.literal(o.schema ?? "public")) AND sequencename = \(dialect.literal(o.name))").first
            guard let r else { return "CREATE SEQUENCE \(q);" }
            return "CREATE SEQUENCE \(q)\n  START WITH \(r[0] ?? "1")\n  INCREMENT BY \(r[1] ?? "1")\n  MINVALUE \(r[2] ?? "1")\n  MAXVALUE \(r[3] ?? "")\(r[4] == "t" ? "\n  CYCLE" : "");"
        case .table, .foreignTable:
            let cols = try columns(of: o)
            var lines = cols.map { c -> String in
                var l = "  \(dialect.quoteIdent(c.name)) \(c.type)"
                if !c.nullable { l += " NOT NULL" }
                if let d = c.defaultValue { l += " DEFAULT \(d)" }
                return l
            }
            let cons = try rows("""
                SELECT con.conname, pg_catalog.pg_get_constraintdef(con.oid, true)
                FROM pg_catalog.pg_constraint con
                JOIN pg_catalog.pg_class c ON c.oid = con.conrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE \(relFilter(o)) ORDER BY con.contype = 'p' DESC, con.conname
                """)
            for c in cons {
                lines.append("  CONSTRAINT \(dialect.quoteIdent(c[0] ?? "")) \(c[1] ?? "")")
            }
            var out = "CREATE TABLE \(q) (\n" + lines.joined(separator: ",\n") + "\n);"
            let conNames = Set(cons.compactMap { $0[0] })
            for idx in try indexes(of: o) where !idx.primary && !conNames.contains(idx.name) {
                out += "\n" + idx.definition + ";"
            }
            if let comment = try scalar("SELECT obj_description(\(dialect.literal(q))::regclass, 'pg_class')"), !comment.isEmpty {
                out += "\nCOMMENT ON TABLE \(q) IS \(dialect.literal(comment));"
            }
            for c in cols where !c.comment.isEmpty {
                out += "\nCOMMENT ON COLUMN \(q).\(dialect.quoteIdent(c.name)) IS \(dialect.literal(c.comment));"
            }
            return out
        }
    }
}
