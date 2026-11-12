import Foundation
import SQLite3


final class SQLiteDriver: DatabaseDriver {
    let dialect = SQLDialect(family: .sqlite)
    private let path: String
    private let startupSQL: String
    private var db: OpaquePointer?
    private(set) var currentDatabase = "main"

    init(path: String, startupSQL: String = "") {
        self.path = (path as NSString).expandingTildeInPath
        self.startupSQL = startupSQL
    }

    deinit { close() }

    func connect() throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close(handle)
            throw DBError(msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        db = handle
        if !startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try? execute(startupSQL) }
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func cancel() {
        if let db { sqlite3_interrupt(db) }
    }

    func serverVersion() -> String { "SQLite " + String(cString: sqlite3_libversion()) }

    func execute(_ sql: String) throws -> [QueryResult] {
        guard let db else { throw DBError("Not connected") }
        var results: [QueryResult] = []
        let cString = Array(sql.utf8CString)
        try cString.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var tail: UnsafePointer<CChar>? = base
            while let current = tail, current.pointee != 0 {
                let start = Date()
                var stmt: OpaquePointer?
                var next: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, current, -1, &stmt, &next)
                if rc != SQLITE_OK {
                    throw DBError(String(cString: sqlite3_errmsg(db)))
                }
                if next == current { break }
                tail = next
                guard let stmt else { continue }
                defer { sqlite3_finalize(stmt) }
                let statementText = sqlite3_sql(stmt).map { String(cString: $0) } ?? ""
                let ncol = Int(sqlite3_column_count(stmt))
                var r = QueryResult()
                r.statement = statementText
                for i in 0..<ncol {
                    let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "?"
                    let decl = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
                    r.columns.append(ResultColumn(name: name, typeName: decl))
                }
                while true {
                    let step = sqlite3_step(stmt)
                    if step == SQLITE_ROW {
                        if r.rows.count >= maxResultRows { r.truncated = true; continue }
                        var vals = [String?]()
                        vals.reserveCapacity(ncol)
                        for i in 0..<ncol {
                            switch sqlite3_column_type(stmt, Int32(i)) {
                            case SQLITE_NULL:
                                vals.append(nil)
                            case SQLITE_BLOB:
                                let len = Int(sqlite3_column_bytes(stmt, Int32(i)))
                                if let p = sqlite3_column_blob(stmt, Int32(i)) {
                                    let data = Data(bytes: p, count: len)
                                    vals.append(String(data: data, encoding: .utf8) ?? data.hexString)
                                } else {
                                    vals.append("")
                                }
                            default:
                                vals.append(sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } ?? "")
                            }
                        }
                        r.rows.append(vals)
                    } else if step == SQLITE_DONE {
                        break
                    } else {
                        throw DBError(String(cString: sqlite3_errmsg(db)))
                    }
                }
                if ncol == 0 {
                    r.affectedRows = Int(sqlite3_changes(db))
                    r.message = "OK"
                }
                r.duration = Date().timeIntervalSince(start)
                results.append(r)
            }
        }
        return results
    }

    // MARK: Metadata

    func listDatabases() throws -> [String] {
        try rows("PRAGMA database_list").compactMap { $0[1] }
    }

    func useDatabase(_ name: String) throws { currentDatabase = name }
    func listSchemas() throws -> [String] { [] }
    func defaultSchema() -> String? { nil }

    private var master: String {
        currentDatabase == "main" ? "sqlite_master" : "\(dialect.quoteIdent(currentDatabase)).sqlite_master"
    }

    func listObjects(schema: String?) throws -> [DBObject] {
        try rows("SELECT name, type, tbl_name FROM \(master) WHERE type IN ('table','view','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name").compactMap { r in
            guard let n = r[0] else { return nil }
            let kind: ObjectKind = r[1] == "view" ? .view : (r[1] == "trigger" ? .trigger : .table)
            return DBObject(schema: nil, name: n, kind: kind, detail: kind == .trigger ? (r[2] ?? "") : "")
        }
    }

    func columns(of o: DBObject) throws -> [ColumnInfo] {
        try rows("PRAGMA table_info(\(dialect.quoteIdent(o.name)))").map {
            ColumnInfo(name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "0", defaultValue: $0[4],
                       isPrimaryKey: ($0[5] ?? "0") != "0")
        }
    }

    func indexes(of o: DBObject) throws -> [IndexInfo] {
        try rows("PRAGMA index_list(\(dialect.quoteIdent(o.name)))").map { r in
            let name = r[1] ?? ""
            let cols = (try? rows("PRAGMA index_info(\(dialect.quoteIdent(name)))").compactMap { $0[2] }) ?? []
            let sql = (try? scalar("SELECT sql FROM \(master) WHERE type = 'index' AND name = \(dialect.literal(name))")) ?? nil
            return IndexInfo(name: name, columns: cols, unique: r[2] == "1", primary: r[3] == "pk",
                             definition: sql ?? "(auto) \(r[3] == "pk" ? "PRIMARY KEY" : "UNIQUE") (\(cols.joined(separator: ", ")))")
        }
    }

    func foreignKeys(of o: DBObject) throws -> [ForeignKeyInfo] {
        var grouped: [String: ForeignKeyInfo] = [:]
        var order: [String] = []
        for r in try rows("PRAGMA foreign_key_list(\(dialect.quoteIdent(o.name)))") {
            let id = r[0] ?? "0"
            if grouped[id] == nil {
                order.append(id)
                grouped[id] = ForeignKeyInfo(name: "fk_\(o.name)_\(id)", columns: [], refSchema: nil, refTable: r[2] ?? "",
                                             refColumns: [], onUpdate: r[5] ?? "", onDelete: r[6] ?? "")
            }
            grouped[id]?.columns.append(r[3] ?? "")
            grouped[id]?.refColumns.append(r[4] ?? "")
        }
        return order.compactMap { grouped[$0] }
    }

    func ddl(of o: DBObject) throws -> String {
        var out = (try scalar("SELECT sql FROM \(master) WHERE name = \(dialect.literal(o.name))") ?? "") + ";"
        if o.kind == .table {
            for r in try rows("SELECT sql FROM \(master) WHERE tbl_name = \(dialect.literal(o.name)) AND type IN ('index','trigger') AND sql IS NOT NULL") {
                if let s = r[0] { out += "\n" + s + ";" }
            }
        }
        return out
    }
}
