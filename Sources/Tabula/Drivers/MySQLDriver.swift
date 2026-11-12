import Foundation
import CMariaDB

final class MySQLDriver: DatabaseDriver {
    let dialect = SQLDialect(family: .mysql)
    private let config: ConnectionConfig
    private let password: String
    private let host: String
    private let port: Int
    private var mysql: UnsafeMutablePointer<MYSQL>?
    private var threadID: UInt = 0
    private(set) var currentDatabase: String

    private static let multiStatements: UInt = 65536   // CLIENT_MULTI_STATEMENTS
    private static let multiResults: UInt = 131072     // CLIENT_MULTI_RESULTS

    init(config: ConnectionConfig, password: String, host: String, port: Int) {
        self.config = config
        self.password = password
        self.host = host == "localhost" ? "127.0.0.1" : host
        self.port = port
        self.currentDatabase = config.database
    }

    deinit { close() }

    /// Directory holding MariaDB auth plugins (caching_sha2_password etc).
    static var pluginDir: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mariadb-plugins").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "/opt/homebrew/opt/mariadb-connector-c/lib/mariadb/plugin"
    }

    private func makeConnection(database: String?) throws -> UnsafeMutablePointer<MYSQL> {
        guard let m = mysql_init(nil) else { throw DBError("Out of memory") }
        _ = mysql_options(m, MYSQL_PLUGIN_DIR, MySQLDriver.pluginDir)
        var timeout: UInt32 = 10
        _ = mysql_options(m, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        var reconnect: Int8 = 0
        _ = mysql_options(m, MYSQL_OPT_RECONNECT, &reconnect)
        _ = mysql_options(m, MYSQL_SET_CHARSET_NAME, "utf8mb4")

        let ssl = config.ssl
        var verify: Int8 = (ssl.mode == .verifyCA || ssl.mode == .verifyFull) ? 1 : 0
        _ = mysql_options(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        if ssl.mode == .require || verify == 1 {
            var enforce: Int8 = 1
            _ = mysql_options(m, MYSQL_OPT_SSL_ENFORCE, &enforce)
        }
        if ssl.mode != .disable {
            func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
            if opt(ssl.caCertPath) != nil || opt(ssl.clientCertPath) != nil || opt(ssl.clientKeyPath) != nil {
                _ = mysql_ssl_set(m, opt(ssl.clientKeyPath), opt(ssl.clientCertPath), opt(ssl.caCertPath), nil, nil)
            }
        } else {
            // MariaDB Connector/C 3.4 tries TLS by default; honour "disabled".
            var off: Int8 = 0
            _ = mysql_options(m, MYSQL_OPT_SSL_ENFORCE, &off)
        }

        let db = (database?.isEmpty ?? true) ? nil : database
        if mysql_real_connect(m, host, config.user, password, db, UInt32(port), nil,
                              MySQLDriver.multiStatements | MySQLDriver.multiResults) == nil {
            let msg = String(cString: mysql_error(m))
            mysql_close(m)
            throw DBError(msg)
        }
        return m
    }

    func connect() throws {
        let m = try makeConnection(database: currentDatabase)
        close()
        mysql = m
        threadID = mysql_thread_id(m)
        if currentDatabase.isEmpty { currentDatabase = (try? scalar("SELECT DATABASE()")) ?? "" }
        if !config.startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? execute(config.startupSQL)
        }
    }

    func close() {
        if let m = mysql { mysql_close(m) }
        mysql = nil
    }

    func cancel() {
        guard threadID != 0, let m = try? makeConnection(database: nil) else { return }
        let sql = "KILL QUERY \(threadID)"
        _ = mysql_real_query(m, sql, UInt(sql.utf8.count))
        mysql_close(m)
    }

    func serverVersion() -> String {
        guard let m = mysql else { return "MySQL" }
        return String(cString: mysql_get_server_info(m))
    }

    private static func typeName(_ t: UInt32, binary: Bool) -> String {
        switch t {
        case 0, 246: return "decimal"
        case 1: return "tinyint"
        case 2: return "smallint"
        case 3: return "int"
        case 4: return "float"
        case 5: return "double"
        case 6: return "null"
        case 7: return "timestamp"
        case 8: return "bigint"
        case 9: return "mediumint"
        case 10, 14: return "date"
        case 11: return "time"
        case 12: return "datetime"
        case 13: return "year"
        case 15, 253: return binary ? "varbinary" : "varchar"
        case 16: return "bit"
        case 245: return "json"
        case 247: return "enum"
        case 248: return "set"
        case 249, 250, 251, 252: return binary ? "blob" : "text"
        case 254: return binary ? "binary" : "char"
        case 255: return "geometry"
        default: return "type:\(t)"
        }
    }

    func execute(_ sql: String) throws -> [QueryResult] {
        guard let m = mysql else { throw DBError("Not connected") }
        let start = Date()
        if mysql_real_query(m, sql, UInt(sql.utf8.count)) != 0 {
            let errno = mysql_errno(m)
            // 2006: server has gone away, 2013: lost connection — reconnect once
            if errno == 2006 || errno == 2013 {
                try connect()
                return try execute(sql)
            }
            throw DBError(String(cString: mysql_error(m)))
        }
        var results: [QueryResult] = []
        while true {
            if let res = mysql_store_result(m) {
                var r = QueryResult()
                let nf = Int(mysql_num_fields(res))
                var binary = [Bool](repeating: false, count: nf)
                if let fields = mysql_fetch_fields(res) {
                    for i in 0..<nf {
                        let f = fields[i]
                        binary[i] = f.charsetnr == 63
                        r.columns.append(ResultColumn(name: String(cString: f.name),
                                                      typeName: MySQLDriver.typeName(f.type.rawValue, binary: binary[i])))
                    }
                }
                var count = 0
                while let row = mysql_fetch_row(res) {
                    count += 1
                    if count > maxResultRows { r.truncated = true; continue }
                    guard let lengths = mysql_fetch_lengths(res) else { break }
                    var vals = [String?]()
                    vals.reserveCapacity(nf)
                    for i in 0..<nf {
                        if let p = row[i] {
                            let len = Int(lengths[i])
                            let data = Data(bytes: p, count: len)
                            if let s = String(data: data, encoding: .utf8) {
                                vals.append(s)
                            } else {
                                vals.append(data.hexString)
                            }
                        } else {
                            vals.append(nil)
                        }
                    }
                    r.rows.append(vals)
                }
                mysql_free_result(res)
                r.statement = sql
                r.duration = Date().timeIntervalSince(start)
                results.append(r)
            } else if mysql_field_count(m) == 0 {
                var r = QueryResult()
                let affected = mysql_affected_rows(m)
                r.affectedRows = affected == UInt64.max ? nil : Int(affected)
                if let info = mysql_info(m) { r.message = String(cString: info) }
                r.statement = sql
                r.duration = Date().timeIntervalSince(start)
                results.append(r)
            } else {
                throw DBError(String(cString: mysql_error(m)))
            }
            let next = mysql_next_result(m)
            if next > 0 { throw DBError(String(cString: mysql_error(m))) }
            if next != 0 { break }
        }
        return results
    }

    // MARK: Metadata

    func listDatabases() throws -> [String] {
        try rows("SHOW DATABASES").compactMap { $0[0] }
    }

    func useDatabase(_ name: String) throws {
        guard let m = mysql else { throw DBError("Not connected") }
        if mysql_select_db(m, name) != 0 { throw DBError(String(cString: mysql_error(m))) }
        currentDatabase = name
    }

    func listSchemas() throws -> [String] { [] }
    func defaultSchema() -> String? { nil }

    private var dbLit: String { currentDatabase.isEmpty ? "DATABASE()" : dialect.literal(currentDatabase) }

    func listObjects(schema: String?) throws -> [DBObject] {
        guard !currentDatabase.isEmpty else { return [] }
        var out: [DBObject] = []
        for r in try rows("SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(dbLit) ORDER BY TABLE_NAME") {
            guard let n = r[0] else { continue }
            out.append(DBObject(schema: nil, name: n, kind: r[1] == "VIEW" ? .view : .table))
        }
        for r in (try? rows("SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(dbLit) ORDER BY ROUTINE_NAME")) ?? [] {
            guard let n = r[0] else { continue }
            out.append(DBObject(schema: nil, name: n, kind: r[1] == "PROCEDURE" ? .procedure : .function))
        }
        for r in (try? rows("SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(dbLit) ORDER BY TRIGGER_NAME")) ?? [] {
            guard let n = r[0] else { continue }
            out.append(DBObject(schema: nil, name: n, kind: .trigger, detail: r[1] ?? ""))
        }
        return out
    }

    func columns(of o: DBObject) throws -> [ColumnInfo] {
        try rows("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA, COLUMN_COMMENT
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(dbLit) AND TABLE_NAME = \(dialect.literal(o.name))
            ORDER BY ORDINAL_POSITION
            """).map {
            ColumnInfo(name: $0[0] ?? "", type: $0[1] ?? "", nullable: $0[2] == "YES", defaultValue: $0[3],
                       isPrimaryKey: $0[4] == "PRI", comment: $0[6] ?? "", extra: $0[5] ?? "")
        }
    }

    func indexes(of o: DBObject) throws -> [IndexInfo] {
        try rows("""
            SELECT INDEX_NAME, MIN(NON_UNIQUE), GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), MIN(INDEX_TYPE)
            FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(dbLit) AND TABLE_NAME = \(dialect.literal(o.name))
            GROUP BY INDEX_NAME ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
            """).map {
            let name = $0[0] ?? ""
            let cols = ($0[2] ?? "").split(separator: ",").map(String.init)
            let unique = $0[1] == "0"
            let def = name == "PRIMARY"
                ? "PRIMARY KEY (\(cols.map(dialect.quoteIdent).joined(separator: ", ")))"
                : "\(unique ? "UNIQUE " : "")INDEX \(dialect.quoteIdent(name)) USING \($0[3] ?? "BTREE") (\(cols.map(dialect.quoteIdent).joined(separator: ", ")))"
            return IndexInfo(name: name, columns: cols, unique: unique, primary: name == "PRIMARY", definition: def)
        }
    }

    func foreignKeys(of o: DBObject) throws -> [ForeignKeyInfo] {
        try rows("""
            SELECT k.CONSTRAINT_NAME, GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
              k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
              GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
              MIN(r.UPDATE_RULE), MIN(r.DELETE_RULE)
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
            WHERE k.TABLE_SCHEMA = \(dbLit) AND k.TABLE_NAME = \(dialect.literal(o.name)) AND k.REFERENCED_TABLE_NAME IS NOT NULL
            GROUP BY k.CONSTRAINT_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME
            ORDER BY k.CONSTRAINT_NAME
            """).map {
            ForeignKeyInfo(name: $0[0] ?? "", columns: ($0[1] ?? "").split(separator: ",").map(String.init),
                           refSchema: $0[2], refTable: $0[3] ?? "", refColumns: ($0[4] ?? "").split(separator: ",").map(String.init),
                           onUpdate: $0[5] ?? "", onDelete: $0[6] ?? "")
        }
    }

    func ddl(of o: DBObject) throws -> String {
        let q = dialect.quoteIdent(o.name)
        switch o.kind {
        case .view:
            return (try rows("SHOW CREATE VIEW \(q)").first?[1] ?? "") + ";"
        case .procedure:
            return (try rows("SHOW CREATE PROCEDURE \(q)").first?[2] ?? "") + ";"
        case .function:
            return (try rows("SHOW CREATE FUNCTION \(q)").first?[2] ?? "") + ";"
        case .trigger:
            return (try rows("SHOW CREATE TRIGGER \(q)").first?[2] ?? "") + ";"
        default:
            return (try rows("SHOW CREATE TABLE \(q)").first?[1] ?? "") + ";"
        }
    }
}
