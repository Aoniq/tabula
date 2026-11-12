import SwiftUI
import AppKit

/// Add / edit sheet for a dashboard tile with a live preview.
struct DashboardTileEditor: View {
    let state: DashboardState
    let isNew: Bool
    @State private var draft: DashboardTile
    @State private var preview: QueryResult?
    /// SQL text the current preview was produced from.
    @State private var previewSQL: String?
    @State private var previewError: String?
    @State private var running = false
    @State private var provider: QueryCompletionProvider?
    @AppStorage(SettingsKey.editorFontSize) private var fontSize = 13.0
    @Environment(\.dismiss) private var dismiss

    init(state: DashboardState, request: DashboardEditorRequest) {
        self.state = state
        self.isNew = request.isNew
        _draft = State(initialValue: request.tile)
        // Seed the preview with the tile's last result so mapping pickers are populated.
        let rt = state.runtime(request.tile.id)
        if !request.isNew, let r = rt.result, rt.error == nil {
            _preview = State(initialValue: r)
            _previewSQL = State(initialValue: request.tile.sql)
        }
    }

    private var problem: String? { DashboardState.validationProblem(draft.sql) }
    private var isWriteProblem: Bool {
        !draft.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem != nil
    }
    private var columns: [String] { preview?.columns.map(\.name) ?? [] }
    private var previewIsStale: Bool { preview != nil && previewSQL != draft.sql }

    var body: some View {
        VStack(spacing: 0) {
            form
                .padding(16)
            Divider()
            previewPane
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DashboardTheme.plane)
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 720, idealHeight: 800)
        .onAppear {
            if provider == nil { provider = QueryCompletionProvider(workspace: state.workspace) }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Tile" : "Edit Tile").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title").gridColumnAlignment(.trailing)
                    TextField("e.g. Orders per day", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Kind")
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(DashboardTileKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Layout")
                    HStack(spacing: 16) {
                        Picker("Width", selection: $draft.width) {
                            Text("Normal").tag(1)
                            Text("Wide").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        if draft.kind != .table {
                            Picker("Values", selection: $draft.format) {
                                ForEach(DashboardValueFormat.allCases) { Text($0.label).tag($0) }
                            }
                            .fixedSize()
                        }
                        Spacer()
                    }
                }
                GridRow(alignment: .top) {
                    Text("Query").padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        SQLEditorView(text: $draft.sql,
                                      request: nil,
                                      requestID: 0,
                                      fontSize: CGFloat(fontSize),
                                      completionSource: provider,
                                      onSelectionChange: { _ in })
                            .frame(height: 170)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                        if isWriteProblem, let problem {
                            Label(problem, systemImage: "lock.fill")
                                .font(.callout)
                                .foregroundStyle(DashboardTheme.critical)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(kindHint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.kind.isChart {
                    GridRow {
                        Text("Columns")
                        mappingRow
                    }
                }
            }
        }
    }

    private var kindHint: String {
        switch draft.kind {
        case .number: return "Shows the first column of the first row as a big number; a second column becomes its caption."
        case .table: return "Shows the result as a compact, sortable grid."
        case .bar: return "Ranked horizontal bars: a label column plus one or more numeric columns (or a series column)."
        case .line, .area: return "A date, number or text x column plus numeric y columns. Up to \(DashboardChartData.maxPoints) points are plotted."
        case .pie: return "A label column and one numeric value column; slices beyond \(DashboardChartData.maxSlices - 1) fold into “Other”."
        }
    }

    // MARK: Mapping

    private var resolved: (x: String?, ys: [String], series: String?)? {
        guard let p = preview else { return nil }
        let names = p.columns.map(\.name)
        let types = DashboardProfiler.types(columns: names, rows: Array(p.rows.prefix(200)))
        let m = DashboardChartData.resolveMapping(columns: names, types: types, tile: draft)
        return (m.x.map { names[$0] }, m.ys.map { names[$0] }, m.series.map { names[$0] })
    }

    private func options(including current: String?) -> [String] {
        var c = columns
        if let current, !c.contains(current) { c.append(current) }
        return c
    }

    private var mappingRow: some View {
        HStack(spacing: 14) {
            Picker(draft.kind == .pie ? "Label" : "X", selection: $draft.xColumn) {
                Text(autoLabel(resolved?.x)).tag(String?.none)
                Divider()
                ForEach(options(including: draft.xColumn), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .fixedSize()

            Menu {
                Button {
                    draft.yColumns = []
                } label: {
                    if draft.yColumns.isEmpty { Label("Auto (numeric columns)", systemImage: "checkmark") } else { Text("Auto (numeric columns)") }
                }
                Divider()
                ForEach(options(including: nil), id: \.self) { c in
                    Button {
                        toggleY(c)
                    } label: {
                        if draft.yColumns.contains(c) { Label(c, systemImage: "checkmark") } else { Text(c) }
                    }
                }
                ForEach(draft.yColumns.filter { !columns.contains($0) }, id: \.self) { c in
                    Button { toggleY(c) } label: { Label(c + " (missing)", systemImage: "checkmark") }
                }
            } label: {
                Text((draft.kind == .pie ? "Value: " : "Y: ") + (draft.yColumns.isEmpty ? autoLabel(resolved?.ys.joined(separator: ", ")) : draft.yColumns.joined(separator: ", ")))
            }
            .fixedSize()

            if draft.kind.supportsSeries {
                Picker("Series", selection: $draft.seriesColumn) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(options(including: draft.seriesColumn), id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
                .help("Split rows into one series per distinct value of this column (uses the first Y column)")
            }
            if preview == nil {
                Text("Run Preview to choose columns").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func autoLabel(_ detected: String?) -> String {
        if let d = detected, !d.isEmpty { return "Auto (\(d))" }
        return "Auto"
    }

    private func toggleY(_ c: String) {
        if let i = draft.yColumns.firstIndex(of: c) { draft.yColumns.remove(at: i) } else { draft.yColumns.append(c) }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.subheadline.weight(.semibold))
                if let p = preview {
                    Text("\(p.rows.count.formatted()) row\(p.rows.count == 1 ? "" : "s") · \(Int((p.duration * 1000).rounded())) ms")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if previewIsStale {
                    Label("Query changed — run Preview again", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            Group {
                if let err = previewError {
                    DashboardTileError(message: err)
                } else if let p = preview {
                    DashboardTileContent(state: state, tile: draft, result: p)
                } else {
                    DashboardMessage(symbol: "play.rectangle", text: "Press Preview (⌘↩) to run the query and see the tile.")
                }
            }
            .padding(14)
            .frame(maxWidth: draft.width == 1 ? 420 : .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardTheme.border))
            .frame(maxWidth: .infinity)
        }
    }

    private func runPreview() {
        if let problem {
            previewError = problem
            preview = nil
            return
        }
        let sql = draft.sql
        running = true
        previewError = nil
        Task {
            defer { running = false }
            do {
                let r = try await state.execute(sql)
                preview = r
                previewSQL = sql
                previewError = nil
            } catch {
                previewError = error.localizedDescription
                preview = nil
                previewSQL = nil
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                runPreview()
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(running || problem != nil)
            .help("Run the query and render the tile (⌘↩)")
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Tile" : "Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
                .help("Save the tile (⌘S)")
        }
    }

    private func save() {
        guard problem == nil else { return }
        var t = draft
        t.title = t.title.trimmingCharacters(in: .whitespaces)
        if t.title.isEmpty { t.title = "Untitled tile" }
        t.sql = t.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let reuse = (previewSQL == draft.sql && previewError == nil) ? preview : nil
        state.commit(t, preview: reuse)
        dismiss()
    }
}
