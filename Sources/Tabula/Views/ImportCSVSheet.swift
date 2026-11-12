import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class CSVImportModel {
    enum DelimiterChoice: String, CaseIterable, Identifiable {
        case comma = "Comma (,)", semicolon = "Semicolon (;)", tab = "Tab", pipe = "Pipe (|)", other = "Other"
        var id: String { rawValue }
        var character: Character? {
            switch self {
            case .comma: return ","
            case .semicolon: return ";"
            case .tab: return "\t"
            case .pipe: return "|"
            case .other: return nil
            }
        }
        static func from(_ c: Character) -> DelimiterChoice {
            allCases.first { $0.character == c } ?? .comma
        }
    }

    enum Phase: Equatable {
        case options
        case parsing
        case running
        case failed(title: String, detail: String)
    }

    let tab: TableTabState
    let workspace: WorkspaceState
    let url: URL
    let fileSize: Int
    private let data: Data
    /// Leading part of the file used for the preview.
    private let previewData: Data

    var delimiterChoice: DelimiterChoice
    var customDelimiter = ""
    var hasHeader = true
    var emptyAsNull = true

    private(set) var previewRecords: [[String]] = []
    private(set) var csvColumns: [String] = []
    private(set) var tableColumns: [String] = []
    var mapping: [String?] = []

    var phase: Phase = .options
    var inserted = 0
    var totalRows = 0
    var cancelRequested = false
    var close: () -> Void = {}

    static let previewRowCount = 10

    init(tab: TableTabState, workspace: WorkspaceState, url: URL) throws {
        self.tab = tab
        self.workspace = workspace
        self.url = url
        data = try CSVImporter.loadData(url)
        fileSize = data.count
        previewData = data.prefix(256 * 1024)
        let sample = String(decoding: previewData, as: UTF8.self)
        delimiterChoice = .from(CSVParser.guessDelimiter(sample))
        tableColumns = tab.columns.map(\.name)
        reparse(remap: true)
        if tableColumns.isEmpty {
            Task {
                tableColumns = await workspace.columns(for: tab.object).map(\.name)
                reparse(remap: true)
            }
        }
    }

    var delimiter: Character? {
        if let c = delimiterChoice.character { return c }
        let s = customDelimiter == "\\t" ? "\t" : customDelimiter
        return s.count == 1 ? s.first : nil
    }

    /// Re-read the preview after an option change. `remap` re-guesses the column mapping.
    func reparse(remap: Bool) {
        guard let d = delimiter else { return }
        let records = parse(previewData, delimiter: d, maxRows: Self.previewRowCount + 1)
        let width = records.map(\.count).max() ?? 0
        let header = hasHeader ? (records.first ?? []) : []
        csvColumns = (0..<width).map { i in
            let h = i < header.count ? header[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return h.isEmpty ? "Column \(i + 1)" : h
        }
        previewRecords = Array(records.dropFirst(hasHeader ? 1 : 0).prefix(Self.previewRowCount))
        if remap || mapping.count != width {
            mapping = CSVImportPlan.autoMap(csvColumns: csvColumns, tableColumns: tableColumns, hasHeader: hasHeader)
        }
    }

    private nonisolated func parse(_ data: Data, delimiter: Character, maxRows: Int) -> [[String]] {
        if let b = delimiter.asciiValue, b != 34, b != 10, b != 13 {
            return CSVParser.parse(data: data, delimiter: b, maxRows: maxRows)
        }
        return CSVParser.parse(String(decoding: data, as: UTF8.self), delimiter: delimiter, maxRows: maxRows)
    }

    var mappedCount: Int { mapping.compactMap { $0 }.count }

    var duplicateTargets: [String] {
        var seen = Set<String>(), dups = Set<String>()
        for c in mapping.compactMap({ $0 }) where !seen.insert(c).inserted { dups.insert(c) }
        return dups.sorted()
    }

    var canImport: Bool { delimiter != nil && mappedCount > 0 && duplicateTargets.isEmpty }

    func sample(column i: Int) -> String {
        for r in previewRecords where i < r.count && !r[i].isEmpty { return r[i] }
        return ""
    }

    // MARK: Import

    func start() {
        guard canImport, let d = delimiter else { return }
        let ws = workspace
        let plan = CSVImportPlan(table: tab.object, dialect: ws.dialect, mapping: mapping, emptyAsNull: emptyAsNull)
        let header = hasHeader
        let fileData = data
        phase = .parsing
        cancelRequested = false

        Task {
            let records: [[String]] = await Task.detached(priority: .userInitiated) { [self] in
                Array(self.parse(fileData, delimiter: d, maxRows: .max).dropFirst(header ? 1 : 0))
            }.value
            guard !cancelRequested else { close(); return }
            guard !records.isEmpty else {
                phase = .failed(title: "Nothing to import", detail: "The file contains no data rows.")
                return
            }
            totalRows = records.count
            // Safe-mode gate with a representative statement.
            var preview = plan.insertSQL(records.prefix(3))
            if records.count > 3 { preview += "\n-- … and \((records.count - 3).ioGrouped) more rows" }
            guard ws.approveWrites([preview]) else { phase = .options; return }

            phase = .running
            inserted = 0
            let started = Date()
            let batch = CSVImporter.batchSize
            do {
                try await ws.run { try CSVImporter.begin($0) }
                var i = 0
                while i < records.count {
                    if cancelRequested { break }
                    let slice = records[i..<min(records.count, i + batch)]
                    let first = i + 1
                    try await ws.run { try CSVImporter.insertBatch($0, plan: plan, records: slice, firstRow: first) }
                    i += slice.count
                    inserted = i
                }
                if cancelRequested {
                    try? await ws.run { CSVImporter.rollback($0) }
                    close()
                    ws.showToast("Import cancelled — no rows were imported")
                    return
                }
                try await ws.run { try CSVImporter.commit($0) }
                ws.logHistory("-- Imported \(records.count) rows from \(url.lastPathComponent)\n\(preview)", duration: Date().timeIntervalSince(started), success: true)
                close()
                ws.showToast("Imported \(records.count.ioGrouped) row\(records.count == 1 ? "" : "s") into \(tab.object.name)")
                await tab.reload()
            } catch {
                try? await ws.run { CSVImporter.rollback($0) }
                ws.logHistory("-- Import from \(url.lastPathComponent) failed\n\(preview)", duration: Date().timeIntervalSince(started), success: false)
                if let rowError = error as? CSVImportRowError {
                    let shown = zip(plan.targetColumns, rowError.values).map { "\($0) = \($1.map { "“\($0.prefix(80))”" } ?? "NULL")" }.joined(separator: "\n")
                    phase = .failed(title: "Import failed at row \(rowError.row.ioGrouped)\(hasHeader ? " (after the header)" : "")",
                                    detail: rowError.message + "\n\n" + shown + "\n\nThe transaction was rolled back; no rows were imported.")
                } else {
                    phase = .failed(title: "Import failed", detail: error.localizedDescription + "\n\nThe transaction was rolled back; no rows were imported.")
                }
            }
        }
    }

    func cancel() {
        switch phase {
        case .running, .parsing: cancelRequested = true
        default: close()
        }
    }
}

struct CSVImportSheet: View {
    @Bindable var model: CSVImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSheetHeader(icon: "square.and.arrow.down",
                          title: "Import CSV into “\(model.tab.object.name)”",
                          subtitle: "\(model.url.lastPathComponent) · \(ioByteString(model.fileSize))")

            switch model.phase {
            case .options:
                options
            case .parsing:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear)
                    Text("Reading file…").font(.callout).foregroundStyle(.secondary)
                }
            case .running:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(model.inserted), total: Double(max(model.totalRows, 1)))
                    Text(model.cancelRequested ? "Rolling back…" : "Inserted \(model.inserted.ioGrouped) of \(model.totalRows.ioGrouped) rows…")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            case .failed(let title, let detail):
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: "exclamationmark.triangle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }

            footer
        }
        .padding(20)
        .frame(width: 720)
    }

    private var cancelTitle: String {
        switch model.phase {
        case .running: return "Stop & Roll Back"
        case .failed: return "Close"
        default: return "Cancel"
        }
    }

    private var footer: some View {
        HStack {
            if model.phase == .options {
                if !model.duplicateTargets.isEmpty {
                    Label("Mapped more than once: \(model.duplicateTargets.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                } else {
                    Text("\(model.mappedCount) of \(model.csvColumns.count) columns will be imported")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(cancelTitle, role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.cancelRequested)
            switch model.phase {
            case .options:
                Button("Import") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            case .failed:
                Button("Back to Options") { model.phase = .options }
            default:
                EmptyView()
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                HStack(spacing: 6) {
                    Text("Delimiter:")
                    Picker("", selection: $model.delimiterChoice) {
                        ForEach(CSVImportModel.DelimiterChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.delimiterChoice == .other {
                        TextField("", text: $model.customDelimiter, prompt: Text("e.g. ~"))
                            .frame(width: 44)
                    }
                }
                Toggle("First row is header", isOn: $model.hasHeader)
                Toggle("Empty values as NULL", isOn: $model.emptyAsNull)
                Spacer(minLength: 0)
            }
            .onChange(of: model.delimiterChoice) { _, _ in model.reparse(remap: true) }
            .onChange(of: model.customDelimiter) { _, _ in model.reparse(remap: true) }
            .onChange(of: model.hasHeader) { _, _ in model.reparse(remap: true) }

            VStack(alignment: .leading, spacing: 6) {
                Text("Column Mapping").font(.subheadline.weight(.semibold))
                mappingList
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.subheadline.weight(.semibold))
                previewGrid
            }
        }
    }

    private var mappingList: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("CSV column").foregroundStyle(.secondary)
                    Text("Sample").foregroundStyle(.secondary)
                    Text("")
                    Text("Table column").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(Array(model.csvColumns.enumerated()), id: \.offset) { i, name in
                    GridRow {
                        Text(name).lineLimit(1).frame(width: 170, alignment: .leading).help(name)
                        Text(model.sample(column: i)).lineLimit(1).foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Picker("", selection: binding(i)) {
                            Text("Skip").tag(String?.none)
                            Divider()
                            ForEach(model.tableColumns, id: \.self) { c in Text(c).tag(String?.some(c)) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(CGFloat(model.csvColumns.count) * 26 + 46, 210))
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func binding(_ i: Int) -> Binding<String?> {
        Binding(
            get: { i < model.mapping.count ? model.mapping[i] : nil },
            set: { v in if i < model.mapping.count { model.mapping[i] = v } }
        )
    }

    private var previewGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(model.csvColumns.enumerated()), id: \.offset) { i, name in
                        let target = i < model.mapping.count ? model.mapping[i] : nil
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).fontWeight(.semibold)
                            Text(target.map { "→ \($0)" } ?? "skipped").font(.caption2).foregroundStyle(target == nil ? .tertiary : .secondary)
                        }
                        .previewCell(skipped: target == nil)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                ForEach(Array(model.previewRecords.enumerated()), id: \.offset) { _, rec in
                    GridRow {
                        ForEach(0..<model.csvColumns.count, id: \.self) { i in
                            let target = i < model.mapping.count ? model.mapping[i] : nil
                            let v = i < rec.count ? rec[i] : nil
                            Group {
                                if let v, !(v.isEmpty && model.emptyAsNull) {
                                    Text(v.replacingOccurrences(of: "\n", with: "⏎"))
                                } else {
                                    Text("NULL").foregroundStyle(.tertiary).italic()
                                }
                            }
                            .previewCell(skipped: target == nil)
                        }
                    }
                }
            }
            .font(.system(size: 11))
        }
        .frame(height: 190)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private extension View {
    func previewCell(skipped: Bool) -> some View {
        self.lineLimit(1)
            .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .opacity(skipped ? 0.45 : 1)
            .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
    }
}
