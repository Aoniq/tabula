import Foundation
import AppKit

// STUB — replaced by the import/export/backup implementation.
@MainActor
enum ImportController {
    static func importCSV(into tab: TableTabState) { tab.workspace?.showToast("CSV import not implemented yet") }
    static func runSQLFile(_ ws: WorkspaceState) { ws.showToast("Run SQL file not implemented yet") }
}

@MainActor
enum ExportController {
    static func exportTable(_ tab: TableTabState) {
        let cols = tab.resultColumns.map(\.name)
        _ = try? Exporter.saveWithPanel(columns: cols, rows: tab.rows, format: .csv, table: tab.object, dialect: tab.dialect, suggestedName: tab.object.name)
    }
    static func exportResult(_ q: QueryTabState) {
        guard let r = q.selectedResult else { return }
        _ = try? Exporter.saveWithPanel(columns: r.columns.map(\.name), rows: r.rows, format: .csv, table: nil, dialect: q.workspace?.dialect ?? SQLDialect(family: .postgres), suggestedName: "result")
    }
}

@MainActor
enum DumpController {
    static func backup(_ ws: WorkspaceState) { ws.showToast("Backup not implemented yet") }
    static func restore(_ ws: WorkspaceState) { ws.showToast("Restore not implemented yet") }
}
