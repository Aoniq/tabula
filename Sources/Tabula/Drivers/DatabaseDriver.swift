import Foundation

struct DBError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorDescription: String? { message }
}

struct ResultColumn: Hashable {
    var name: String
    var typeName: String
}

struct QueryResult: Identifiable {
    let id = UUID()
    var columns: [ResultColumn] = []
    var rows: [[String?]] = []
    var affectedRows: Int?
    var message: String = ""
    var statement: String = ""
    var duration: TimeInterval = 0
    var truncated = false

    var isResultSet: Bool { !columns.isEmpty }

    var summary: String {
        if isResultSet {
            return "\(rows.count) row\(rows.count == 1 ? "" : "s")\(truncated ? " (truncated)" : "")"
        }
        if let a = affectedRows { return "\(a) row\(a == 1 ? "" : "s") affected" }
        return message.isEmpty ? "OK" : message
    }
}

enum ObjectKind: String, Codable, CaseIterable {
    case table, view, materializedView, foreignTable, function, procedure, sequence, trigger

    var label: String {
        switch self {
        case .table: return "Tables"
        case .view: return "Views"
        case .materializedView: return "Materialized Views"
        case .foreignTable: return "Foreign Tables"
        case .function: return "Functions"
        case .procedure: return "Procedures"
        case .sequence: return "Sequences"
        case .trigger: return "Triggers"
        }
    }

    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "eye.square"
        case .foreignTable: return "tablecells.badge.ellipsis"
        case .function: return "function"
        case .procedure: return "gearshape"
        case .sequence: return "number"
        case .trigger: return "bolt"
        }
    }

    /// Objects whose rows can be browsed in a data tab.
    var isBrowsable: Bool { [.table, .view, .materializedView, .foreignTable].contains(self) }
    var isEditableData: Bool { self == .table }
}

struct DBObject: Hashable, Identifiable, Codable {
    var schema: String?
    var name: String
    var kind: ObjectKind
    /// Extra info, e.g. function argument signature.
    var detail: String = ""

    var id: String { "\(kind.rawValue):\(schema ?? ""):\(name):\(detail)" }
    var displayName: String { detail.isEmpty || !(kind == .function || kind == .procedure) ? name : "\(name)(\(detail))" }
}

struct ColumnInfo: Hashable, Identifiable {
    var name: String
    var type: String
    var nullable: Bool
    var defaultValue: String?
    var isPrimaryKey: Bool
    var comment: String = ""
    var extra: String = ""
    var id: String { name }
}

struct IndexInfo: Hashable, Identifiable {
    var name: String
    var columns: [String]
    var unique: Bool
    var primary: Bool
    var definition: String
    var id: String { name }
}

struct ForeignKeyInfo: Hashable, Identifiable {
    var name: String
    var columns: [String]
    var refSchema: String?
    var refTable: String
    var refColumns: [String]
    var onUpdate: String
    var onDelete: String
    var id: String { name }
}

/// Synchronous database driver. All calls happen on the session's serial queue,
/// except `cancel()` which may be called from any thread.
protocol DatabaseDriver: AnyObject {
    var dialect: SQLDialect { get }
    var currentDatabase: String { get }

    func connect() throws
    func close()
    func execute(_ sql: String) throws -> [QueryResult]
    func cancel()

    func listDatabases() throws -> [String]
    func useDatabase(_ name: String) throws
    func listSchemas() throws -> [String]
    func defaultSchema() -> String?
    func listObjects(schema: String?) throws -> [DBObject]
    func columns(of object: DBObject) throws -> [ColumnInfo]
    func indexes(of object: DBObject) throws -> [IndexInfo]
    func foreignKeys(of object: DBObject) throws -> [ForeignKeyInfo]
    func ddl(of object: DBObject) throws -> String
    func serverVersion() -> String

    /// Fetch a page of rows for a browsable object.
    func browse(_ object: DBObject, columns: [String], filters: [FilterRule], sort: [SortKey], limit: Int, offset: Int) throws -> QueryResult
    /// Total row count respecting filters (nil when unknown).
    func count(_ object: DBObject, columns: [String], filters: [FilterRule]) throws -> Int?
}

extension DatabaseDriver {
    func browse(_ object: DBObject, columns: [String], filters: [FilterRule], sort: [SortKey], limit: Int, offset: Int) throws -> QueryResult {
        let sql = dialect.selectSQL(object, columns: columns, filters: filters, sort: sort, limit: limit, offset: offset)
        var r = try execute(sql).last(where: { $0.isResultSet }) ?? QueryResult()
        r.statement = sql
        return r
    }

    func count(_ object: DBObject, columns: [String], filters: [FilterRule]) throws -> Int? {
        try scalar(dialect.countSQL(object, columns: columns, filters: filters)).flatMap { Int($0) }
    }

    /// Run a query and return the first result set's rows.
    func rows(_ sql: String) throws -> [[String?]] {
        try execute(sql).first(where: { $0.isResultSet })?.rows ?? []
    }

    func scalar(_ sql: String) throws -> String? {
        try rows(sql).first?.first ?? nil
    }
}

/// Max rows kept from a single result set to protect memory.
let maxResultRows = 200_000

extension Data {
    var hexString: String {
        "0x" + map { String(format: "%02X", $0) }.joined()
    }
}
