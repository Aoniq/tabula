import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class ExportSheetModel {
    enum Scope: Hashable { case page, all }
    enum Phase: Equatable { case options, running, failed(String) }

    private enum Source {
        case table(TableTabState)
        case result(QueryResult, rows: [[String?]])
    }

    private let source: Source
    let workspace: WorkspaceState
    let title: String

    var format: ExportFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "exportLastFormat") }
    }
    var scope: Scope = .all
    var includeHeader = true
    var sqlTableName: String
    var phase: Phase = .options
    var exported = 0
    var cancelRequested = false
    var close: () -> Void = {}

    init(table: TableTabState, workspace: WorkspaceState) {
        source = .table(table)
        self.workspace = workspace
        title = table.object.name
        sqlTableName = table.object.name
        format = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "exportLastFormat") ?? "") ?? .csv
    }

    init(result: QueryResult, orderedRows: [[String?]], title: String, workspace: WorkspaceState) {
        source = .result(result, rows: orderedRows)
        self.workspace = workspace
        self.title = title
        sqlTableName = "table_name"
        format = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "exportLastFormat") ?? "") ?? .csv
    }

    var isTable: Bool { if case .table = source { return true } else { return false } }

    var tableTab: TableTabState? { if case .table(let t) = source { return t } else { return nil } }

    var pageRowCount: Int {
        switch source {
        case .table(let t): return t.rows.count
        case .result(_, let rows): return rows.count
        }
    }

    /// Known total for the "all rows" scope (nil while unknown).
    var totalRows: Int? {
        switch source {
        case .table(let t): return scope == .page ? t.rows.count : t.totalCount
        case .result(_, let rows): return rows.count
        }
    }

    var subtitle: String {
        switch source {
        case .table(let t):
            let filtered = t.appliedFilters.contains(where: \.enabled)
            return "\(t.object.kind == .table ? "Table" : "View") · \(workspace.config.displayName)\(filtered ? " · filtered" : "")"
        case .result(let r, let rows):
            return "Query result · \(rows.count.ioGrouped) row\(rows.count == 1 ? "" : "s") × \(r.columns.count) column\(r.columns.count == 1 ? "" : "s")"
        }
    }

    private var columns: [ResultColumn] {
        switch source {
        case .table(let t):
            if !t.resultColumns.isEmpty { return t.resultColumns }
            return t.columns.map { ResultColumn(name: $0.name, typeName: $0.type) }
        case .result(let r, _): return r.columns
        }
    }

    private var sqlTable: DBObject {
        let name = sqlTableName.trimmingCharacters(in: .whitespaces)
        if case .table(let t) = source, name == t.object.name { return t.object }
        return DBObject(schema: nil, name: name.isEmpty ? "table_name" : name, kind: .table)
    }

    // MARK: Running

    func export() {
        guard let url = Exporter.askDestination(format: format, suggestedName: title) else { return }
        phase = .running
        exported = 0
        cancelRequested = false
        let cols = columns
        let names = cols.map(\.name), types = cols.map(\.typeName)
        let format = format, includeHeader = includeHeader || !format.supportsHeaderToggle
        let table = sqlTable, dialect = workspace.dialect
        let ws = workspace

        Task {
            let writer: ExportWriter
            do {
                writer = try ExportWriter(url: url, format: format, columns: names, columnTypes: types, table: table, dialect: dialect, includeHeader: includeHeader)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            do {
                switch source {
                case .result(_, let rows):
                    try await Self.writeOffMain(writer, rows: rows)
                    exported = rows.count
                case .table(let t):
                    if scope == .page {
                        try await Self.writeOffMain(writer, rows: t.rows)
                        exported = t.rows.count
                    } else {
                        var q = TableExportQuery(object: t.object, columns: t.columns.map(\.name), filters: t.appliedFilters, sort: t.sort)
                        q.stabilize(primaryKey: t.primaryKey)
                        let family = ws.family
                        var offset = 0
                        while true {
                            let at = offset
                            let n = try await ws.run { d -> Int in
                                let r = try q.fetch(d, offset: at)
                                try writer.write(r.rows)
                                return r.rows.count
                            }
                            offset += n
                            exported = offset
                            if q.isLastBatch(n, family: family) || cancelRequested { break }
                        }
                    }
                }
                if cancelRequested {
                    writer.abort()
                    close()
                    ws.showToast("Export cancelled")
                    return
                }
                try writer.finish()
                close()
                ws.showToast("Exported \(exported.ioGrouped) row\(exported == 1 ? "" : "s") to \(url.lastPathComponent)")
            } catch {
                writer.abort()
                if cancelRequested {
                    close()
                    ws.showToast("Export cancelled")
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func writeOffMain(_ writer: ExportWriter, rows: [[String?]]) async throws {
        try await Task.detached(priority: .userInitiated) {
            try writer.write(rows)
        }.value
    }

    func cancel() {
        if phase == .running {
            cancelRequested = true
        } else {
            close()
        }
    }
}

struct ExportSheet: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSheetHeader(icon: "square.and.arrow.up", title: "Export “\(model.title)”", subtitle: model.subtitle)

            switch model.phase {
            case .options:
                options
            case .running:
                progress
            case .failed(let message):
                Label {
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .running && model.cancelRequested)
                if model.phase != .running {
                    Button(model.phase == .options ? "Export…" : "Try Again…") { model.export() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var options: some View {
        Form {
            Picker("Format:", selection: $model.format) {
                ForEach(ExportFormat.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)

            if model.isTable {
                Picker("Rows:", selection: $model.scope) {
                    Text("Current page (\(model.pageRowCount.ioGrouped) row\(model.pageRowCount == 1 ? "" : "s"))").tag(ExportSheetModel.Scope.page)
                    Text(allRowsLabel).tag(ExportSheetModel.Scope.all)
                }
                .pickerStyle(.radioGroup)
            }

            if model.format.supportsHeaderToggle {
                Toggle("Include column names as the first row", isOn: $model.includeHeader)
            }
            if model.format == .sql {
                TextField("Table name:", text: $model.sqlTableName)
                    .frame(maxWidth: 260)
            }
        }
        .formStyle(.columns)
    }

    private var allRowsLabel: String {
        let filtered = model.tableTab?.appliedFilters.contains(where: \.enabled) ?? false
        var s = filtered ? "All rows matching the current filters" : "All rows"
        if let n = model.tableTab?.totalCount { s += " (\(n.ioGrouped))" }
        if let t = model.tableTab, !t.sort.isEmpty { s += ", sorted" }
        return s
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let total = model.totalRows, total > 0 {
                ProgressView(value: Double(min(model.exported, total)), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(model.cancelRequested ? "Cancelling…" : "Exported \(model.exported.ioGrouped)\(model.totalRows.map { " of \($0.ioGrouped)" } ?? "") rows…")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
