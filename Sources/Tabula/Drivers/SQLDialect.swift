import Foundation

/// A value written by the user into a cell.
enum EditValue: Hashable {
    case null
    case text(String)
    case defaultValue

    var displayText: String? {
        switch self {
        case .null: return nil
        case .text(let s): return s
        case .defaultValue: return "DEFAULT"
        }
    }
}

enum FilterOperator: String, CaseIterable, Identifiable, Codable {
    case equals = "="
    case notEquals = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case contains = "Contains"
    case notContains = "Not contains"
    case startsWith = "Starts with"
    case endsWith = "Ends with"
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case inList = "IN"
    case notInList = "NOT IN"
    case between = "BETWEEN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case isEmpty = "Is empty"
    case isNotEmpty = "Is not empty"
    case raw = "Raw SQL"

    var id: String { rawValue }
    var needsValue: Bool { ![.isNull, .isNotNull, .isEmpty, .isNotEmpty].contains(self) }
}

struct FilterRule: Identifiable, Hashable, Codable {
    var id = UUID()
    var enabled = true
    /// Empty string means "any column".
    var column = ""
    var op: FilterOperator = .contains
    var value = ""
    var value2 = ""
}

struct SortKey: Hashable {
    var column: String
    var ascending: Bool
}

struct SQLDialect {
    let family: DatabaseFamily

    // MARK: Quoting

    func quoteIdent(_ s: String) -> String {
        switch family {
        case .mysql: return "`" + s.replacingOccurrences(of: "`", with: "``") + "`"
        default: return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    func literal(_ s: String?) -> String {
        guard let s else { return "NULL" }
        switch family {
        case .mysql:
            var out = "'"
            for ch in s.unicodeScalars {
                switch ch {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                case "\0": out += "\\0"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\u{1A}": out += "\\Z"
                default: out.unicodeScalars.append(ch)
                }
            }
            return out + "'"
        default:
            return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    func literal(_ v: EditValue) -> String {
        switch v {
        case .null: return "NULL"
        case .defaultValue: return "DEFAULT"
        case .text(let s): return literal(s)
        }
    }

    func qualified(_ o: DBObject) -> String {
        if let s = o.schema, !s.isEmpty, family == .postgres { return quoteIdent(s) + "." + quoteIdent(o.name) }
        return quoteIdent(o.name)
    }

    // MARK: Browsing

    func whereClause(_ filters: [FilterRule], columns: [String]) -> String {
        let parts = filters.filter(\.enabled).compactMap { condition($0, columns: columns) }
        return parts.isEmpty ? "" : " WHERE " + parts.joined(separator: " AND ")
    }

    private func textExpr(_ col: String) -> String {
        switch family {
        case .postgres: return "CAST(\(quoteIdent(col)) AS TEXT)"
        case .mysql: return "CAST(\(quoteIdent(col)) AS CHAR)"
        default: return quoteIdent(col)
        }
    }

    private var likeOp: String { family == .postgres ? "ILIKE" : "LIKE" }

    func condition(_ f: FilterRule, columns: [String]) -> String? {
        if f.op == .raw { return f.value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "(\(f.value))" }
        if f.column.isEmpty {
            // any column: OR of contains/equals across all columns
            guard f.op.needsValue, !f.value.isEmpty, !columns.isEmpty else { return nil }
            let parts = columns.compactMap { c -> String? in
                var r = f; r.column = c
                return condition(r, columns: columns)
            }
            return "(" + parts.joined(separator: " OR ") + ")"
        }
        let c = quoteIdent(f.column)
        let v = f.value
        switch f.op {
        case .equals: return "\(c) = \(literal(v))"
        case .notEquals: return "\(c) <> \(literal(v))"
        case .less: return "\(c) < \(literal(v))"
        case .greater: return "\(c) > \(literal(v))"
        case .lessOrEqual: return "\(c) <= \(literal(v))"
        case .greaterOrEqual: return "\(c) >= \(literal(v))"
        case .contains: return "\(textExpr(f.column)) \(likeOp) \(literal("%" + v + "%"))"
        case .notContains: return "\(textExpr(f.column)) NOT \(likeOp) \(literal("%" + v + "%"))"
        case .startsWith: return "\(textExpr(f.column)) \(likeOp) \(literal(v + "%"))"
        case .endsWith: return "\(textExpr(f.column)) \(likeOp) \(literal("%" + v))"
        case .like: return "\(c) LIKE \(literal(v))"
        case .notLike: return "\(c) NOT LIKE \(literal(v))"
        case .inList, .notInList:
            let items = v.split(separator: ",").map { literal($0.trimmingCharacters(in: .whitespaces)) }
            guard !items.isEmpty else { return nil }
            return "\(c) \(f.op == .inList ? "IN" : "NOT IN") (\(items.joined(separator: ", ")))"
        case .between: return "\(c) BETWEEN \(literal(v)) AND \(literal(f.value2))"
        case .isNull: return "\(c) IS NULL"
        case .isNotNull: return "\(c) IS NOT NULL"
        case .isEmpty: return "(\(c) IS NULL OR \(textExpr(f.column)) = '')"
        case .isNotEmpty: return "(\(c) IS NOT NULL AND \(textExpr(f.column)) <> '')"
        case .raw: return nil
        }
    }

    func selectSQL(_ o: DBObject, columns: [String], filters: [FilterRule], sort: [SortKey], limit: Int?, offset: Int) -> String {
        var sql = "SELECT * FROM \(qualified(o))" + whereClause(filters, columns: columns)
        if !sort.isEmpty {
            sql += " ORDER BY " + sort.map { "\(quoteIdent($0.column)) \($0.ascending ? "ASC" : "DESC")" }.joined(separator: ", ")
        }
        if let limit { sql += " LIMIT \(limit)" }
        if offset > 0 { sql += " OFFSET \(offset)" }
        return sql
    }

    func countSQL(_ o: DBObject, columns: [String], filters: [FilterRule]) -> String {
        "SELECT COUNT(*) FROM \(qualified(o))" + whereClause(filters, columns: columns)
    }

    // MARK: Data changes

    func keyCondition(_ keys: [(String, String?)]) -> String {
        keys.map { k in
            k.1 == nil ? "\(quoteIdent(k.0)) IS NULL" : "\(quoteIdent(k.0)) = \(literal(k.1))"
        }.joined(separator: " AND ")
    }

    func updateSQL(_ o: DBObject, set: [(String, EditValue)], keys: [(String, String?)], limitOne: Bool) -> String {
        let assignments = set.map { "\(quoteIdent($0.0)) = \(literal($0.1))" }.joined(separator: ", ")
        var sql = "UPDATE \(qualified(o)) SET \(assignments) WHERE \(keyCondition(keys))"
        if limitOne && family == .mysql { sql += " LIMIT 1" }
        return sql + ";"
    }

    func insertSQL(_ o: DBObject, values: [(String, EditValue)]) -> String {
        let explicit = values.filter { $0.1 != .defaultValue }
        if explicit.isEmpty {
            return family == .mysql ? "INSERT INTO \(qualified(o)) () VALUES ();" : "INSERT INTO \(qualified(o)) DEFAULT VALUES;"
        }
        let cols = explicit.map { quoteIdent($0.0) }.joined(separator: ", ")
        let vals = explicit.map { literal($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(qualified(o)) (\(cols)) VALUES (\(vals));"
    }

    func insertSQL(_ o: DBObject, columns: [String], rows: [[String?]]) -> String {
        guard !rows.isEmpty else { return "" }
        let cols = columns.map { quoteIdent($0) }.joined(separator: ", ")
        let vals = rows.map { "(" + $0.map { literal($0) }.joined(separator: ", ") + ")" }.joined(separator: ",\n  ")
        return "INSERT INTO \(qualified(o)) (\(cols)) VALUES\n  \(vals);"
    }

    func deleteSQL(_ o: DBObject, keys: [(String, String?)], limitOne: Bool) -> String {
        var sql = "DELETE FROM \(qualified(o)) WHERE \(keyCondition(keys))"
        if limitOne && family == .mysql { sql += " LIMIT 1" }
        return sql + ";"
    }

    // MARK: Object operations

    func dropSQL(_ o: DBObject) -> String {
        switch o.kind {
        case .table: return "DROP TABLE \(qualified(o));"
        case .view: return "DROP VIEW \(qualified(o));"
        case .materializedView: return "DROP MATERIALIZED VIEW \(qualified(o));"
        case .foreignTable: return "DROP FOREIGN TABLE \(qualified(o));"
        case .sequence: return "DROP SEQUENCE \(qualified(o));"
        case .function:
            return family == .postgres ? "DROP FUNCTION \(qualified(o))(\(o.detail));" : "DROP FUNCTION \(qualified(o));"
        case .procedure:
            return family == .postgres ? "DROP PROCEDURE \(qualified(o))(\(o.detail));" : "DROP PROCEDURE \(qualified(o));"
        case .trigger:
            return "DROP TRIGGER \(qualified(o));"
        }
    }

    func truncateSQL(_ o: DBObject) -> String {
        family == .sqlite ? "DELETE FROM \(qualified(o));" : "TRUNCATE TABLE \(qualified(o));"
    }

    func renameSQL(_ o: DBObject, to newName: String) -> String {
        switch family {
        case .mysql: return "RENAME TABLE \(qualified(o)) TO \(quoteIdent(newName));"
        default:
            let kw = o.kind == .view ? "VIEW" : (o.kind == .materializedView ? "MATERIALIZED VIEW" : "TABLE")
            return "ALTER \(family == .sqlite ? "TABLE" : kw) \(qualified(o)) RENAME TO \(quoteIdent(newName));"
        }
    }

    // MARK: Server info

    var processListSQL: String? {
        switch family {
        case .postgres:
            return "SELECT pid, usename AS user, datname AS database, client_addr AS host, application_name, state, backend_start, query_start, now() - query_start AS duration, wait_event_type, query FROM pg_stat_activity ORDER BY query_start DESC NULLS LAST"
        case .mysql:
            return "SHOW FULL PROCESSLIST"
        default: return nil
        }
    }

    func killSQL(_ pid: String) -> String? {
        switch family {
        case .postgres: return "SELECT pg_terminate_backend(\(Int(pid) ?? 0))"
        case .mysql: return "KILL \(Int(pid) ?? 0)"
        default: return nil
        }
    }

    var usersSQL: String? {
        switch family {
        case .postgres:
            return "SELECT rolname AS role, rolsuper AS superuser, rolcreaterole AS create_role, rolcreatedb AS create_db, rolcanlogin AS can_login, rolreplication AS replication, rolconnlimit AS conn_limit, rolvaliduntil AS valid_until FROM pg_roles ORDER BY rolname"
        case .mysql:
            return "SELECT User, Host, account_locked, password_expired, Super_priv, Grant_priv, Create_priv, Drop_priv FROM mysql.user ORDER BY User, Host"
        default: return nil
        }
    }

    // MARK: Type suggestions for the structure editor

    var commonTypes: [String] {
        switch family {
        case .postgres:
            return ["integer", "bigint", "smallint", "serial", "bigserial", "numeric", "real", "double precision", "boolean", "text", "varchar(255)", "char(1)", "uuid", "date", "time", "timestamp", "timestamptz", "interval", "json", "jsonb", "bytea", "inet", "text[]", "integer[]"]
        case .mysql:
            return ["int", "bigint", "tinyint", "smallint", "mediumint", "decimal(10,2)", "float", "double", "tinyint(1)", "varchar(255)", "char(1)", "text", "mediumtext", "longtext", "date", "datetime", "timestamp", "time", "year", "json", "blob", "longblob", "enum('a','b')"]
        case .sqlite:
            return ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME"]
        case .redis:
            return []
        }
    }
}
