import Foundation

/// `Tabula --selftest` exercises every driver against local test databases
/// (see scripts/test-dbs.sh) and prints a report. Used during development.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ body: () throws -> String) {
            do {
                let detail = try body()
                print("  ✓ \(name)\(detail.isEmpty ? "" : " — " + detail)")
            } catch {
                failures += 1
                print("  ✗ \(name): \(error.localizedDescription)")
            }
        }

        func exercise(_ label: String, _ make: () throws -> DatabaseDriver) {
            print("\n== \(label)")
            var driverOpt: DatabaseDriver?
            check("connect") {
                let d = try make()
                driverOpt = d
                return d.serverVersion().prefix(60).description
            }
            guard let d = driverOpt else { return }
            check("databases") { try d.listDatabases().joined(separator: ", ") }
            check("schemas") { try d.listSchemas().joined(separator: ", ") }
            var objects: [DBObject] = []
            check("objects") {
                objects = try d.listObjects(schema: d.defaultSchema())
                return objects.prefix(12).map { "\($0.kind.rawValue):\($0.displayName)" }.joined(separator: ", ")
            }
            if let t = objects.first(where: { $0.kind == .table }) {
                var cols: [ColumnInfo] = []
                check("columns(\(t.name))") {
                    cols = try d.columns(of: t)
                    return cols.map { "\($0.name) \($0.type)\($0.isPrimaryKey ? " PK" : "")" }.joined(separator: ", ")
                }
                check("indexes") { try d.indexes(of: t).map { "\($0.name)[\($0.columns.joined(separator: ","))]" }.joined(separator: ", ") }
                check("foreign keys") {
                    try objects.filter { $0.kind == .table }.flatMap { try d.foreignKeys(of: $0) }.map { "\($0.columns)->\($0.refTable)\($0.refColumns)" }.joined(separator: ", ")
                }
                check("browse") {
                    let r = try d.browse(t, columns: cols.map(\.name), filters: [], sort: [SortKey(column: cols.first?.name ?? "", ascending: false)], limit: 3, offset: 0)
                    return "\(r.rows.count) rows: \(r.rows.first.map { $0.map { $0 ?? "NULL" }.joined(separator: "|") } ?? "")"
                }
                check("filtered count") {
                    var f = FilterRule(); f.column = ""; f.op = .contains; f.value = "a"
                    return String(try d.count(t, columns: cols.map(\.name), filters: [f]) ?? -1)
                }
                check("ddl") { String(try d.ddl(of: t).prefix(120)).replacingOccurrences(of: "\n", with: " ") }
            }
            if d.dialect.family != .redis {
                check("multi statement") {
                    let rs = try d.execute("SELECT 1 AS a, 'x' AS b; SELECT NULL AS n")
                    return rs.map(\.summary).joined(separator: " / ")
                }
                check("error reporting") {
                    do { _ = try d.execute("SELECT * FROM definitely_missing_table") } catch { return "got error: " + error.localizedDescription.prefix(60) }
                    throw DBError("expected an error")
                }
                check("write + rollback") {
                    let t = "tabula_selftest"
                    _ = try? d.execute("DROP TABLE \(d.dialect.quoteIdent(t))")
                    _ = try d.execute("CREATE TABLE \(d.dialect.quoteIdent(t)) (id INTEGER PRIMARY KEY, name VARCHAR(50))")
                    let obj = DBObject(schema: d.defaultSchema(), name: t, kind: .table)
                    _ = try d.execute(d.dialect.insertSQL(obj, values: [("id", .text("1")), ("name", .text("it's \\ ok"))]))
                    _ = try d.execute(d.dialect.updateSQL(obj, set: [("name", .text("new 'value'"))], keys: [("id", "1")], limitOne: true))
                    let v = try d.scalar("SELECT name FROM \(d.dialect.quoteIdent(t))")
                    _ = try d.execute("DROP TABLE \(d.dialect.quoteIdent(t))")
                    guard v == "new 'value'" else { throw DBError("unexpected value \(v ?? "nil")") }
                    return "round-trip ok"
                }
            } else {
                check("command") { try d.execute("PING\nDBSIZE").map { $0.rows.first?.compactMap { $0 }.joined() ?? "" }.joined(separator: ", ") }
            }
            d.close()
        }

        var pg = ConnectionConfig(); pg.kind = .postgresql; pg.host = "127.0.0.1"; pg.port = 55432; pg.user = "postgres"; pg.database = "shop"; pg.ssl.mode = .disable
        exercise("PostgreSQL") { let d = PostgresDriver(config: pg, password: "secret", host: pg.host, port: pg.port); try d.connect(); return d }

        var my = ConnectionConfig(); my.kind = .mysql; my.host = "127.0.0.1"; my.port = 53306; my.user = "root"; my.database = "shop"
        exercise("MySQL") { let d = MySQLDriver(config: my, password: "secret", host: my.host, port: my.port); try d.connect(); return d }

        let sqlitePath = NSTemporaryDirectory() + "tabula-selftest.sqlite"
        exercise("SQLite") {
            let d = SQLiteDriver(path: sqlitePath); try d.connect()
            _ = try d.execute("CREATE TABLE IF NOT EXISTS customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE); INSERT OR IGNORE INTO customers VALUES (1,'Ada','ada@example.com'),(2,'Alan',NULL); CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE, total REAL); CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id); CREATE VIEW IF NOT EXISTS v_c AS SELECT * FROM customers")
            return d
        }

        var rd = ConnectionConfig(); rd.kind = .redis; rd.host = "127.0.0.1"; rd.port = 56379
        exercise("Redis") {
            let d = RedisDriver(config: rd, password: "", host: rd.host, port: rd.port); try d.connect()
            _ = try d.execute("HSET user:1 name Ada email ada@example.com\nRPUSH queue a b c\nSET greeting \"hello world\"")
            return d
        }

        print("\nSQL tokenizer:")
        check("statement split") {
            let s = SQLTokenizer.statements("SELECT 'a;b'; -- c;\nSELECT $$x;y$$; UPDATE t SET a=1")
            guard s.count == 3 else { throw DBError("got \(s.count): \(s)") }
            return s.joined(separator: " | ")
        }
        check("write detection") {
            let cases: [(String, Bool)] = [("select 1", false), ("UPDATE t SET a=1", true), ("with x as (select 1) delete from t", true), ("SHOW TABLES", false), ("drop table x", true)]
            for (sql, expect) in cases where SQLTokenizer.isWriteStatement(sql) != expect { throw DBError("wrong for \(sql)") }
            return "ok"
        }
        check("formatter") { SQLFormatter.format("select a,b from t join u on t.id=u.tid where a=1 and b='x' order by a", uppercase: true).replacingOccurrences(of: "\n", with: "⏎") }

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
        return failures == 0 ? 0 : 1
    }
}
