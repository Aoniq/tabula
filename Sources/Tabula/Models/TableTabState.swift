import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class TableTabState {
    enum Mode: String { case data, structure }

    weak var workspace: WorkspaceState?
    let object: DBObject
    var mode: Mode

    // Structure
    var columns: [ColumnInfo] = []
    var indexes: [IndexInfo] = []
    var foreignKeys: [ForeignKeyInfo] = []
    var structure: StructureDraft?
    var structureLoaded = false

    // Data
    var resultColumns: [ResultColumn] = []
    var rows: [[String?]] = []
    var page = 0
    var pageSize = Settings.pageSize
    var totalCount: Int?
    var countingRows = false
    var sort: [SortKey] = []
    var filters: [FilterRule] = []
    var appliedFilters: [FilterRule] = []
    var showFilters = false
    var loading = false
    var error: String?
    var lastQuery = ""
    var lastDuration: TimeInterval = 0
    var dataLoaded = false

    // Pending changes
    var edits: [Int: [Int: EditValue]] = [:]
    var inserted: [[EditValue]] = []
    var deleted: Set<Int> = []

    var selection = IndexSet()
    var gridVersion = 0
    var dataGeneration = 0
    var scrollToRow: Int?

    init(workspace: WorkspaceState, object: DBObject, mode: Mode) {
        self.workspace = workspace
        self.object = object
        self.mode = mode
    }

    var dialect: SQLDialect { workspace?.dialect ?? SQLDialect(family: .postgres) }

    var hasDataChanges: Bool { !edits.isEmpty || !inserted.isEmpty || !deleted.isEmpty }
    var hasChanges: Bool { hasDataChanges || (structure?.hasChanges ?? false) }
    var changeCount: Int { edits.count + inserted.count + deleted.count + (structure?.changeCount ?? 0) }

    var canEditData: Bool {
        guard let ws = workspace else { return false }
        return object.kind.isEditableData && ws.family != .redis && ws.config.safeMode != .readOnly
    }

    var canEditStructure: Bool {
        guard let ws = workspace else { return false }
        return object.kind == .table && ws.family != .redis && ws.config.safeMode != .readOnly
    }

    var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
    var displayRowCount: Int { rows.count + inserted.count }
    var pageCount: Int? { totalCount.map { max(1, Int(ceil(Double($0) / Double(pageSize)))) } }

    // MARK: Loading

    func initialLoad() async {
        await loadColumns()
        if let ws = workspace, ws.family != .redis, object.kind == .table {
            let o = object
            foreignKeys = (try? await ws.run { try $0.foreignKeys(of: o) }) ?? []
        }
        if mode == .data { await reload() } else { await loadStructure() }
    }

    func switchMode(_ m: Mode) {
        mode = m
        Task {
            if m == .structure && !structureLoaded { await loadStructure() }
            if m == .data && !dataLoaded { await reload() }
        }
    }

    func loadColumns() async {
        guard let ws = workspace else { return }
        let o = object
        do {
            columns = try await ws.run { try $0.columns(of: o) }
            ws.setCachedColumns(columns, for: o)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reload(recount: Bool = true) async {
        guard let ws = workspace else { return }
        loading = true
        error = nil
        let o = object, f = appliedFilters, s = sort, limit = pageSize, offset = page * pageSize
        let colNames = columns.map(\.name)
        let start = Date()
        do {
            let r = try await ws.run { try $0.browse(o, columns: colNames, filters: f, sort: s, limit: limit, offset: offset) }
            resultColumns = r.columns
            rows = r.rows
            lastQuery = r.statement
            lastDuration = Date().timeIntervalSince(start)
            edits.removeAll(); inserted.removeAll(); deleted.removeAll()
            selection = []
            dataLoaded = true
            gridVersion += 1
            dataGeneration += 1
            if recount { await recountRows() }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func recountRows() async {
        guard let ws = workspace else { return }
        let o = object, f = appliedFilters, colNames = columns.map(\.name)
        // A full page smaller than the page size on page 0 tells us the count without a query.
        if page == 0 && rows.count < pageSize {
            totalCount = rows.count
            return
        }
        countingRows = true
        totalCount = try? await ws.run { try $0.count(o, columns: colNames, filters: f) }
        countingRows = false
    }

    func loadStructure() async {
        guard let ws = workspace else { return }
        let o = object
        do {
            async let cols = ws.run { try $0.columns(of: o) }
            async let idx = ws.run { try $0.indexes(of: o) }
            async let fks = ws.run { try $0.foreignKeys(of: o) }
            columns = try await cols
            indexes = (try? await idx) ?? []
            foreignKeys = (try? await fks) ?? []
            structure = StructureDraft(columns: columns, indexes: indexes, foreignKeys: foreignKeys)
            structureLoaded = true
            ws.setCachedColumns(columns, for: o)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Paging / sorting / filtering

    func goToPage(_ p: Int) {
        guard !hasDataChanges || confirmDiscard() else { return }
        page = max(0, p)
        if let c = pageCount { page = min(page, c - 1) }
        Task { await reload(recount: false) }
    }

    func toggleSort(column: String) {
        guard !hasDataChanges || confirmDiscard() else { return }
        if let first = sort.first, first.column == column {
            sort = first.ascending ? [SortKey(column: column, ascending: false)] : []
        } else {
            sort = [SortKey(column: column, ascending: true)]
        }
        page = 0
        Task { await reload(recount: false) }
    }

    func applyFilters() {
        guard !hasDataChanges || confirmDiscard() else { return }
        appliedFilters = filters
        page = 0
        Task { await reload() }
    }

    func clearFilters() {
        filters = []
        appliedFilters = []
        page = 0
        Task { await reload() }
    }

    func addFilter(column: String = "", op: FilterOperator = .contains, value: String = "") {
        filters.append(FilterRule(column: column, op: op, value: value))
        showFilters = true
    }

    func quickFilter(column: String, value: String?) {
        filters = [FilterRule(column: column, op: value == nil ? .isNull : .equals, value: value ?? "")]
        showFilters = true
        applyFilters()
    }

    private func confirmDiscard() -> Bool {
        let a = NSAlert()
        a.messageText = "Discard uncommitted changes?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Cell access

    func columnIndex(_ name: String) -> Int? { resultColumns.firstIndex { $0.name == name } }

    func value(row: Int, column: Int) -> String? {
        if row >= rows.count {
            let i = row - rows.count
            guard i < inserted.count, column < inserted[i].count else { return nil }
            return inserted[i][column].displayText
        }
        if let e = edits[row]?[column] { return e.displayText }
        guard column < rows[row].count else { return nil }
        return rows[row][column]
    }

    func isEdited(row: Int, column: Int) -> Bool {
        if row >= rows.count {
            let i = row - rows.count
            return i < inserted.count && column < inserted[i].count && inserted[i][column] != .defaultValue
        }
        return edits[row]?[column] != nil
    }

    func isDefaultPlaceholder(row: Int, column: Int) -> Bool {
        guard row >= rows.count else { return edits[row]?[column] == .defaultValue }
        let i = row - rows.count
        return i < inserted.count && column < inserted[i].count && inserted[i][column] == .defaultValue
    }

    func rowState(_ row: Int) -> GridRowState {
        if row >= rows.count { return .inserted }
        if deleted.contains(row) { return .deleted }
        return edits[row] == nil ? .normal : .edited
    }

    // MARK: Editing

    func setValue(_ v: EditValue, row: Int, column: Int) {
        guard canEditData else { return }
        if row >= rows.count {
            let i = row - rows.count
            guard i < inserted.count else { return }
            inserted[i][column] = v
        } else {
            let original = rows[row][column]
            let same: Bool = {
                switch v {
                case .null: return original == nil
                case .text(let s): return original == s
                case .defaultValue: return false
                }
            }()
            if same {
                edits[row]?[column] = nil
                if edits[row]?.isEmpty == true { edits[row] = nil }
            } else {
                edits[row, default: [:]][column] = v
            }
        }
        gridVersion += 1
    }

    func addRow() {
        guard canEditData, !resultColumns.isEmpty else { return }
        inserted.append(Array(repeating: .defaultValue, count: resultColumns.count))
        let newRow = rows.count + inserted.count - 1
        selection = IndexSet(integer: newRow)
        scrollToRow = newRow
        gridVersion += 1
    }

    func duplicateRows(_ rowsToCopy: IndexSet) {
        guard canEditData else { return }
        let pk = Set(primaryKey)
        for r in rowsToCopy {
            let values: [EditValue] = resultColumns.enumerated().map { (i, c) in
                if pk.contains(c.name) || columns.first(where: { $0.name == c.name })?.extra.lowercased().contains("auto_increment") == true { return .defaultValue }
                return value(row: r, column: i).map { .text($0) } ?? .null
            }
            inserted.append(values)
        }
        let newRow = rows.count + inserted.count - 1
        selection = IndexSet(integer: newRow)
        scrollToRow = newRow
        gridVersion += 1
    }

    func deleteRows(_ set: IndexSet) {
        guard canEditData else { return }
        var insertedToRemove: [Int] = []
        for r in set {
            if r >= rows.count { insertedToRemove.append(r - rows.count) }
            else if deleted.contains(r) { deleted.remove(r) }
            else { deleted.insert(r) }
        }
        for i in insertedToRemove.sorted(by: >) where i < inserted.count { inserted.remove(at: i) }
        gridVersion += 1
    }

    func discardChanges() {
        edits.removeAll(); inserted.removeAll(); deleted.removeAll()
        structure?.reset()
        gridVersion += 1
    }

    // MARK: SQL generation

    func dataChangeStatements() -> [String] {
        let d = dialect
        let names = resultColumns.map(\.name)
        let pk = primaryKey.filter { names.contains($0) }
        let keyCols = pk.isEmpty ? names : pk
        let limitOne = pk.isEmpty
        func keys(_ row: Int) -> [(String, String?)] {
            keyCols.compactMap { k in columnIndex(k).map { (k, rows[row][$0]) } }
        }
        var out: [String] = []
        for r in deleted.sorted() {
            out.append(d.deleteSQL(object, keys: keys(r), limitOne: limitOne))
        }
        for r in edits.keys.sorted() where !deleted.contains(r) {
            let set = edits[r]!.sorted { $0.key < $1.key }.map { (names[$0.key], $0.value) }
            out.append(d.updateSQL(object, set: set, keys: keys(r), limitOne: limitOne))
        }
        for ins in inserted {
            out.append(d.insertSQL(object, values: Array(zip(names, ins))))
        }
        return out
    }

    func allChangeStatements() throws -> [String] {
        var out = dataChangeStatements()
        if let s = structure, s.hasChanges {
            out += try s.statements(table: object, dialect: dialect)
        }
        return out
    }

    func previewChanges() {
        guard let ws = workspace else { return }
        do {
            let stmts = try allChangeStatements()
            guard !stmts.isEmpty else { ws.showToast("No pending changes"); return }
            ws.review = .init(title: "Review changes to \(object.name)", statements: stmts) { [weak self] in
                Task { await self?.commit(skipApproval: true) }
            }
        } catch {
            ws.showToast(error.localizedDescription, error: true)
        }
    }

    func commit(skipApproval: Bool = false) async {
        guard let ws = workspace else { return }
        let stmts: [String]
        do { stmts = try allChangeStatements() } catch {
            ws.showToast(error.localizedDescription, error: true)
            return
        }
        guard !stmts.isEmpty else { return }
        if !skipApproval && !ws.approveWrites(stmts) { return }
        let structural = structure?.hasChanges ?? false
        do {
            try await ws.executeTransaction(stmts)
            ws.showToast("Committed \(stmts.count) change\(stmts.count == 1 ? "" : "s")")
            if structural {
                await loadStructure()
                await loadColumns()
                dataLoaded = false
                if mode == .data { await reload() }
            } else {
                await reload(recount: !inserted.isEmpty || !deleted.isEmpty)
            }
        } catch {
            ws.showToast("Commit failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Navigation

    /// Foreign key that starts at this column (single-column FKs only).
    func foreignKey(for column: String) -> ForeignKeyInfo? {
        foreignKeys.first { $0.columns == [column] }
    }

    func followForeignKey(column: String, value: String?) {
        guard let ws = workspace, let value, let fk = foreignKey(for: column),
              let target = ws.objects.first(where: { $0.name == fk.refTable && $0.kind == .table }) ?? Optional(DBObject(schema: fk.refSchema, name: fk.refTable, kind: .table))
        else { return }
        ws.openTable(target)
        if case .table(let t) = ws.selectedTab?.content {
            t.filters = [FilterRule(column: fk.refColumns.first ?? "id", op: .equals, value: value)]
            t.appliedFilters = t.filters
            t.showFilters = true
            Task { await t.reload() }
        }
    }
}

enum GridRowState { case normal, edited, inserted, deleted }

// MARK: - Structure editing

struct ColumnDraft: Identifiable, Hashable {
    let id = UUID()
    var original: ColumnInfo?
    var name: String
    var type: String
    var nullable: Bool
    var defaultValue: String
    var comment: String
    var isPrimaryKey: Bool
    var dropped = false

    init(_ c: ColumnInfo) {
        original = c
        name = c.name
        type = c.type
        nullable = c.nullable
        defaultValue = c.defaultValue ?? ""
        comment = c.comment
        isPrimaryKey = c.isPrimaryKey
    }

    init(name: String, type: String) {
        original = nil
        self.name = name
        self.type = type
        nullable = true
        defaultValue = ""
        comment = ""
        isPrimaryKey = false
    }

    var isNew: Bool { original == nil }
    var isModified: Bool {
        guard let o = original else { return false }
        return name != o.name || type != o.type || nullable != o.nullable || defaultValue != (o.defaultValue ?? "") || comment != o.comment
    }
}

struct IndexDraft: Identifiable, Hashable {
    let id = UUID()
    var original: IndexInfo?
    var name: String
    var columns: String
    var unique: Bool
    var dropped = false
    var isNew: Bool { original == nil }
}

struct ForeignKeyDraft: Identifiable, Hashable {
    let id = UUID()
    var original: ForeignKeyInfo?
    var name: String
    var columns: String
    var refTable: String
    var refColumns: String
    var onDelete: String
    var onUpdate: String
    var dropped = false
    var isNew: Bool { original == nil }
}

@Observable
final class StructureDraft {
    var columns: [ColumnDraft]
    var indexes: [IndexDraft]
    var foreignKeys: [ForeignKeyDraft]
    private let originalColumns: [ColumnInfo]
    private let originalIndexes: [IndexInfo]
    private let originalForeignKeys: [ForeignKeyInfo]

    init(columns: [ColumnInfo], indexes: [IndexInfo], foreignKeys: [ForeignKeyInfo]) {
        originalColumns = columns
        originalIndexes = indexes
        originalForeignKeys = foreignKeys
        self.columns = columns.map(ColumnDraft.init)
        self.indexes = indexes.map { IndexDraft(original: $0, name: $0.name, columns: $0.columns.joined(separator: ", "), unique: $0.unique) }
        self.foreignKeys = foreignKeys.map {
            ForeignKeyDraft(original: $0, name: $0.name, columns: $0.columns.joined(separator: ", "), refTable: $0.refTable,
                            refColumns: $0.refColumns.joined(separator: ", "), onDelete: $0.onDelete, onUpdate: $0.onUpdate)
        }
    }

    func reset() {
        columns = originalColumns.map(ColumnDraft.init)
        indexes = originalIndexes.map { IndexDraft(original: $0, name: $0.name, columns: $0.columns.joined(separator: ", "), unique: $0.unique) }
        foreignKeys = originalForeignKeys.map {
            ForeignKeyDraft(original: $0, name: $0.name, columns: $0.columns.joined(separator: ", "), refTable: $0.refTable,
                            refColumns: $0.refColumns.joined(separator: ", "), onDelete: $0.onDelete, onUpdate: $0.onUpdate)
        }
    }

    var changeCount: Int {
        columns.filter { $0.isNew || $0.dropped || $0.isModified }.count
            + indexes.filter { $0.isNew || $0.dropped }.count
            + foreignKeys.filter { $0.isNew || $0.dropped }.count
    }
    var hasChanges: Bool { changeCount > 0 }

    private func list(_ s: String, _ d: SQLDialect) -> String {
        s.split(separator: ",").map { d.quoteIdent($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ")
    }

    private func mysqlDefault(_ v: String) -> String {
        let u = v.uppercased()
        if v.hasPrefix("'") || Double(v) != nil || u.hasPrefix("CURRENT_TIMESTAMP") || u == "NULL" || v.contains("(") { return v }
        return SQLDialect(family: .mysql).literal(v)
    }

    func statements(table: DBObject, dialect d: SQLDialect) throws -> [String] {
        let t = d.qualified(table)
        var out: [String] = []
        // Columns
        for c in columns {
            let name = d.quoteIdent(c.name)
            if c.isNew {
                if c.dropped || c.name.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard !c.type.trimmingCharacters(in: .whitespaces).isEmpty else { throw DBError("Column “\(c.name)” needs a type") }
                var s = "ALTER TABLE \(t) ADD COLUMN \(name) \(c.type)"
                if !c.nullable { s += " NOT NULL" }
                if !c.defaultValue.isEmpty { s += " DEFAULT \(d.family == .mysql ? mysqlDefault(c.defaultValue) : c.defaultValue)" }
                if d.family == .mysql && !c.comment.isEmpty { s += " COMMENT \(d.literal(c.comment))" }
                out.append(s + ";")
                if d.family == .postgres && !c.comment.isEmpty {
                    out.append("COMMENT ON COLUMN \(t).\(name) IS \(d.literal(c.comment));")
                }
                continue
            }
            guard let o = c.original else { continue }
            if c.dropped {
                out.append("ALTER TABLE \(t) DROP COLUMN \(d.quoteIdent(o.name));")
                continue
            }
            guard c.isModified else { continue }
            switch d.family {
            case .postgres:
                var cur = d.quoteIdent(o.name)
                if c.name != o.name {
                    out.append("ALTER TABLE \(t) RENAME COLUMN \(cur) TO \(name);")
                    cur = name
                }
                if c.type != o.type { out.append("ALTER TABLE \(t) ALTER COLUMN \(cur) TYPE \(c.type) USING \(cur)::\(c.type);") }
                if c.nullable != o.nullable { out.append("ALTER TABLE \(t) ALTER COLUMN \(cur) \(c.nullable ? "DROP" : "SET") NOT NULL;") }
                if c.defaultValue != (o.defaultValue ?? "") {
                    out.append(c.defaultValue.isEmpty ? "ALTER TABLE \(t) ALTER COLUMN \(cur) DROP DEFAULT;" : "ALTER TABLE \(t) ALTER COLUMN \(cur) SET DEFAULT \(c.defaultValue);")
                }
                if c.comment != o.comment {
                    out.append("COMMENT ON COLUMN \(t).\(cur) IS \(c.comment.isEmpty ? "NULL" : d.literal(c.comment));")
                }
            case .mysql:
                var s = "ALTER TABLE \(t) CHANGE COLUMN \(d.quoteIdent(o.name)) \(name) \(c.type)"
                s += c.nullable ? " NULL" : " NOT NULL"
                if !c.defaultValue.isEmpty { s += " DEFAULT \(mysqlDefault(c.defaultValue))" }
                let extra = o.extra.lowercased()
                if extra.contains("auto_increment") { s += " AUTO_INCREMENT" }
                if let r = extra.range(of: "on update current_timestamp") { s += " " + extra[r.lowerBound...].uppercased() }
                if !c.comment.isEmpty { s += " COMMENT \(d.literal(c.comment))" }
                out.append(s + ";")
            case .sqlite:
                if c.name != o.name { out.append("ALTER TABLE \(t) RENAME COLUMN \(d.quoteIdent(o.name)) TO \(name);") }
                if c.type != o.type || c.nullable != o.nullable || c.defaultValue != (o.defaultValue ?? "") {
                    throw DBError("SQLite can't change the type, nullability or default of an existing column (“\(o.name)”). Create a new table and copy the data instead.")
                }
            case .redis:
                break
            }
        }
        // Indexes
        for i in indexes {
            if i.isNew {
                guard !i.dropped, !i.columns.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let name = i.name.isEmpty ? "idx_\(table.name)_\(i.columns.replacingOccurrences(of: ",", with: "_").replacingOccurrences(of: " ", with: ""))" : i.name
                out.append("CREATE \(i.unique ? "UNIQUE " : "")INDEX \(d.quoteIdent(name)) ON \(t) (\(list(i.columns, d)));")
            } else if i.dropped, let o = i.original {
                switch d.family {
                case .postgres:
                    if o.primary || o.definition.isEmpty || (o.unique && o.name.hasSuffix("_key")) {
                        out.append("ALTER TABLE \(t) DROP CONSTRAINT \(d.quoteIdent(o.name));")
                    } else {
                        let schema = table.schema.map { d.quoteIdent($0) + "." } ?? ""
                        out.append("DROP INDEX \(schema)\(d.quoteIdent(o.name));")
                    }
                case .mysql:
                    out.append(o.primary ? "ALTER TABLE \(t) DROP PRIMARY KEY;" : "DROP INDEX \(d.quoteIdent(o.name)) ON \(t);")
                default:
                    out.append("DROP INDEX \(d.quoteIdent(o.name));")
                }
            }
        }
        // Foreign keys
        for f in foreignKeys {
            if f.isNew {
                guard !f.dropped, !f.columns.isEmpty, !f.refTable.isEmpty else { continue }
                if d.family == .sqlite { throw DBError("SQLite can't add foreign keys to an existing table.") }
                let name = f.name.isEmpty ? "fk_\(table.name)_\(f.refTable)" : f.name
                var s = "ALTER TABLE \(t) ADD CONSTRAINT \(d.quoteIdent(name)) FOREIGN KEY (\(list(f.columns, d))) REFERENCES \(d.quoteIdent(f.refTable)) (\(list(f.refColumns, d)))"
                if !f.onDelete.isEmpty && f.onDelete != "NO ACTION" { s += " ON DELETE \(f.onDelete)" }
                if !f.onUpdate.isEmpty && f.onUpdate != "NO ACTION" { s += " ON UPDATE \(f.onUpdate)" }
                out.append(s + ";")
            } else if f.dropped, let o = f.original {
                switch d.family {
                case .mysql: out.append("ALTER TABLE \(t) DROP FOREIGN KEY \(d.quoteIdent(o.name));")
                case .postgres: out.append("ALTER TABLE \(t) DROP CONSTRAINT \(d.quoteIdent(o.name));")
                default: throw DBError("SQLite can't drop foreign keys from an existing table.")
                }
            }
        }
        return out
    }
}
