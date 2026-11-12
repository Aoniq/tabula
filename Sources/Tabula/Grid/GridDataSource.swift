import Foundation
import AppKit
import Observation

/// Everything the AppKit grid needs from a model.
@MainActor
protocol GridDataSource: AnyObject {
    var gridColumns: [ResultColumn] { get }
    var gridRowCount: Int { get }
    func gridValue(row: Int, column: Int) -> String?
    func gridIsEdited(row: Int, column: Int) -> Bool
    func gridIsDefault(row: Int, column: Int) -> Bool
    func gridRowState(_ row: Int) -> GridRowState
    var gridEditable: Bool { get }
    var gridSort: [SortKey] { get }
    var gridTable: DBObject? { get }
    var gridDialect: SQLDialect { get }
    var gridSelection: IndexSet { get }

    func gridSetValue(_ value: EditValue, row: Int, column: Int)
    func gridDeleteRows(_ rows: IndexSet)
    func gridDuplicateRows(_ rows: IndexSet)
    func gridSelectionChanged(_ rows: IndexSet)
    func gridSortRequested(column: Int)
    func gridQuickFilter(column: Int, value: String?)
    func gridForeignKey(column: Int) -> ForeignKeyInfo?
    func gridFollowForeignKey(row: Int, column: Int)
}

extension GridDataSource {
    func gridIsEdited(row: Int, column: Int) -> Bool { false }
    func gridIsDefault(row: Int, column: Int) -> Bool { false }
    func gridRowState(_ row: Int) -> GridRowState { .normal }
    var gridEditable: Bool { false }
    var gridSort: [SortKey] { [] }
    var gridTable: DBObject? { nil }
    func gridSetValue(_ value: EditValue, row: Int, column: Int) {}
    func gridDeleteRows(_ rows: IndexSet) {}
    func gridDuplicateRows(_ rows: IndexSet) {}
    func gridSortRequested(column: Int) {}
    func gridQuickFilter(column: Int, value: String?) {}
    func gridForeignKey(column: Int) -> ForeignKeyInfo? { nil }
    func gridFollowForeignKey(row: Int, column: Int) {}
}

extension TableTabState: GridDataSource {
    var gridColumns: [ResultColumn] { resultColumns }
    var gridRowCount: Int { displayRowCount }
    func gridValue(row: Int, column: Int) -> String? { value(row: row, column: column) }
    func gridIsEdited(row: Int, column: Int) -> Bool { isEdited(row: row, column: column) }
    func gridIsDefault(row: Int, column: Int) -> Bool { isDefaultPlaceholder(row: row, column: column) }
    func gridRowState(_ row: Int) -> GridRowState { rowState(row) }
    var gridEditable: Bool { canEditData }
    var gridSort: [SortKey] { sort }
    var gridTable: DBObject? { object }
    var gridDialect: SQLDialect { dialect }
    var gridSelection: IndexSet { selection }
    func gridSetValue(_ value: EditValue, row: Int, column: Int) { setValue(value, row: row, column: column) }
    func gridDeleteRows(_ rows: IndexSet) { deleteRows(rows) }
    func gridDuplicateRows(_ rows: IndexSet) { duplicateRows(rows) }
    func gridSelectionChanged(_ rows: IndexSet) { if selection != rows { selection = rows } }
    func gridSortRequested(column: Int) {
        guard column < resultColumns.count else { return }
        toggleSort(column: resultColumns[column].name)
    }
    func gridQuickFilter(column: Int, value: String?) {
        guard column < resultColumns.count else { return }
        quickFilter(column: resultColumns[column].name, value: value)
    }
    func gridForeignKey(column: Int) -> ForeignKeyInfo? {
        guard column < resultColumns.count else { return nil }
        return foreignKey(for: resultColumns[column].name)
    }
    func gridFollowForeignKey(row: Int, column: Int) {
        guard column < resultColumns.count else { return }
        followForeignKey(column: resultColumns[column].name, value: value(row: row, column: column))
    }
}

/// Grid model for query results: client-side sorting, and inline editing when the
/// result comes from a simple single-table SELECT that includes the primary key.
@MainActor
@Observable
final class ResultGridModel: GridDataSource {
    let result: QueryResult
    @ObservationIgnored weak var workspace: WorkspaceState?
    private var order: [Int]
    private(set) var sort: [SortKey] = []
    var selection = IndexSet()
    var version = 0
    @ObservationIgnored var onSelection: ((IndexSet) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    // Editing (set by QueryTabState when the result is editable)
    var editTable: DBObject?
    var keyColumns: [String] = []
    private(set) var edits: [Int: [Int: EditValue]] = [:]   // keyed by original row index
    private(set) var deleted: Set<Int> = []

    init(result: QueryResult, workspace: WorkspaceState?) {
        self.result = result
        self.workspace = workspace
        self.order = Array(result.rows.indices)
    }

    var hasChanges: Bool { !edits.isEmpty || !deleted.isEmpty }
    var changeCount: Int { edits.count + deleted.count }

    var gridColumns: [ResultColumn] { result.columns }
    var gridRowCount: Int { result.rows.count }
    func gridValue(row: Int, column: Int) -> String? {
        guard row < order.count else { return nil }
        let orig = order[row]
        if let e = edits[orig]?[column] { return e.displayText }
        let r = result.rows[orig]
        return column < r.count ? r[column] : nil
    }
    var gridSort: [SortKey] { sort }
    var gridTable: DBObject? { editTable }
    var gridDialect: SQLDialect { workspace?.dialect ?? SQLDialect(family: .postgres) }
    var gridSelection: IndexSet { selection }
    var gridEditable: Bool { editTable != nil && workspace?.config.safeMode != .readOnly }

    func gridIsEdited(row: Int, column: Int) -> Bool {
        row < order.count && edits[order[row]]?[column] != nil
    }

    func gridRowState(_ row: Int) -> GridRowState {
        guard row < order.count else { return .normal }
        let orig = order[row]
        if deleted.contains(orig) { return .deleted }
        return edits[orig] == nil ? .normal : .edited
    }

    func gridSetValue(_ value: EditValue, row: Int, column: Int) {
        guard gridEditable, row < order.count else { return }
        let orig = order[row]
        let original = result.rows[orig][column]
        let same: Bool
        switch value {
        case .null: same = original == nil
        case .text(let s): same = original == s
        case .defaultValue: same = false
        }
        if same {
            edits[orig]?[column] = nil
            if edits[orig]?.isEmpty == true { edits[orig] = nil }
        } else {
            edits[orig, default: [:]][column] = value
        }
        version += 1
    }

    func gridDeleteRows(_ rows: IndexSet) {
        guard gridEditable else { return }
        for r in rows where r < order.count {
            let orig = order[r]
            if deleted.contains(orig) { deleted.remove(orig) } else { deleted.insert(orig) }
        }
        version += 1
    }

    func gridSelectionChanged(_ rows: IndexSet) {
        selection = rows
        onSelection?(rows)
    }

    func discardChanges() {
        edits.removeAll()
        deleted.removeAll()
        version += 1
    }

    func changeStatements() -> [String] {
        guard let table = editTable else { return [] }
        let d = gridDialect
        let names = result.columns.map(\.name)
        func keys(_ orig: Int) -> [(String, String?)] {
            keyColumns.compactMap { k in names.firstIndex(of: k).map { (k, result.rows[orig][$0]) } }
        }
        var out: [String] = []
        for orig in deleted.sorted() { out.append(d.deleteSQL(table, keys: keys(orig), limitOne: false)) }
        for orig in edits.keys.sorted() where !deleted.contains(orig) {
            let set = edits[orig]!.sorted { $0.key < $1.key }.map { (names[$0.key], $0.value) }
            out.append(d.updateSQL(table, set: set, keys: keys(orig), limitOne: false))
        }
        return out
    }

    func row(_ i: Int) -> [String?] { i < order.count ? result.rows[order[i]] : [] }
    var orderedRows: [[String?]] { order.map { result.rows[$0] } }

    func gridSortRequested(column: Int) {
        guard column < result.columns.count else { return }
        let name = result.columns[column].name
        if let s = sort.first, s.column == name {
            sort = s.ascending ? [SortKey(column: name, ascending: false)] : []
        } else {
            sort = [SortKey(column: name, ascending: true)]
        }
        if let s = sort.first {
            order.sort { a, b in
                let x = result.rows[a][column], y = result.rows[b][column]
                switch (x, y) {
                case (nil, nil): return false
                case (nil, _): return s.ascending
                case (_, nil): return !s.ascending
                case let (x?, y?):
                    if let dx = Double(x), let dy = Double(y) { return s.ascending ? dx < dy : dx > dy }
                    let c = x.localizedStandardCompare(y)
                    return s.ascending ? c == .orderedAscending : c == .orderedDescending
                }
            }
        } else {
            order = Array(result.rows.indices)
        }
        version += 1
        onChange?()
    }
}
