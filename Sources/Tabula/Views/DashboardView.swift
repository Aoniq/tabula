import SwiftUI
import AppKit

/// The "Metrics" tab: a responsive grid of SQL-backed tiles.
struct DashboardView: View {
    @Bindable var state: DashboardState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(DashboardTheme.plane)
        .onAppear { state.startAutoRefresh() }
        .onDisappear { state.stopAutoRefresh() }
        .sheet(item: $state.editor, onDismiss: { state.pruneGridModels() }) { req in
            DashboardTileEditor(state: state, request: req)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Metrics").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if state.isSupported {
                if state.isRefreshingAll {
                    ProgressView().controlSize(.small)
                }
                Picker(selection: $state.refreshInterval) {
                    ForEach(DashboardRefreshInterval.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Auto-refresh", systemImage: "timer")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Refresh all tiles automatically while this tab is visible")
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(state.tiles.isEmpty || state.isRefreshingAll)
                .help("Re-run every tile")
                Button {
                    state.beginAdd()
                } label: {
                    Label("Add Tile", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    private var subtitle: String {
        let ws = state.workspace
        var parts: [String] = []
        if let db = ws?.currentDatabase, !db.isEmpty { parts.append(db) }
        parts.append("\(state.tiles.count) tile\(state.tiles.count == 1 ? "" : "s")")
        if state.refreshInterval != .off { parts.append("auto-refresh every \(state.refreshInterval.label)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if !state.isSupported {
            DashboardMessage(symbol: "chart.bar.xaxis",
                             text: "Metrics dashboards are built from SQL queries and aren’t available for Redis connections.")
        } else if state.tiles.isEmpty {
            emptyState
        } else {
            ScrollView {
                DashboardGridLayout(minColumnWidth: 320, spacing: 12, maxColumns: 4) {
                    ForEach(state.tiles) { tile in
                        DashboardCard(state: state, tile: tile)
                            .layoutValue(key: DashboardSpanKey.self, value: tile.width)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(DashboardTheme.muted)
            Text("Build a metrics board").font(.title3.weight(.semibold))
            Text("Each tile is a read-only SQL query shown as a number, a table or a chart. Tiles refresh on demand or on a timer and are saved for this connection.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            let samples = state.sampleTiles
            HStack {
                Button {
                    state.beginAdd()
                } label: {
                    Label("Add Tile", systemImage: "plus")
                }
                if !samples.isEmpty {
                    Button {
                        state.addSampleTiles()
                    } label: {
                        Label("Add Sample Tiles", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            if !samples.isEmpty {
                Text("Samples: " + samples.map(\.title).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

struct DashboardCard: View {
    @Bindable var state: DashboardState
    let tile: DashboardTile

    private var rt: DashboardTileRuntime { state.runtime(tile.id) }
    private var idealHeight: CGFloat { tile.kind == .number ? 150 : 320 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content(for: rt)
        }
        .padding(14)
        .frame(minHeight: 130, idealHeight: idealHeight, maxHeight: .infinity, alignment: .top)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardTheme.border))
        .contextMenu { menuItems }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title.isEmpty ? "Untitled" : tile.title)
                    .font(.headline)
                    .foregroundStyle(DashboardTheme.ink)
                    .lineLimit(1)
                    .help(tile.title)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if rt.isRunning {
                ProgressView().controlSize(.mini)
                    .padding(.top, 3)
            }
            if tile.kind.isChart && rt.result != nil && rt.error == nil {
                Button {
                    state.toggleData(tile.id)
                } label: {
                    Image(systemName: state.showingData.contains(tile.id) ? tile.kind.symbol : "tablecells")
                }
                .buttonStyle(.borderless)
                .help(state.showingData.contains(tile.id) ? "Show chart" : "Show data as a table")
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Tile actions")
        }
    }

    private var statusLine: String {
        if rt.isRunning && rt.lastRefreshed == nil { return "Running…" }
        guard let last = rt.lastRefreshed else { return "Not run yet" }
        var parts = ["Updated " + last.formatted(date: .omitted, time: .standard)]
        if let d = rt.duration { parts.append(d < 1 ? "\(Int((d * 1000).rounded())) ms" : String(format: "%.2f s", d)) }
        if rt.error == nil, let r = rt.result, tile.kind != .number { parts.append("\(r.rows.count.formatted()) row\(r.rows.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit…") { state.beginEdit(tile) }
        Button("Duplicate") { state.duplicate(tile) }
        Button("Refresh") { Task { await state.refresh(tile.id) } }
        Button("Open SQL in New Query Tab") { state.openInQueryTab(tile) }
        Divider()
        Button("Move Earlier") { state.move(tile, by: -1) }.disabled(!state.canMove(tile, by: -1))
        Button("Move Later") { state.move(tile, by: 1) }.disabled(!state.canMove(tile, by: 1))
        Divider()
        Button("Delete", role: .destructive) {
            if state.workspace?.confirm("Delete tile “\(tile.title)”?", "The tile and its query are removed from this dashboard.", button: "Delete") ?? true {
                state.delete(tile)
            }
        }
    }

    @ViewBuilder
    private func content(for rt: DashboardTileRuntime) -> some View {
        if let err = rt.error {
            DashboardTileError(message: err,
                               retry: { Task { await state.refresh(tile.id) } },
                               edit: { state.beginEdit(tile) })
        } else if let r = rt.result {
            DashboardTileContent(state: state, tile: tile, result: r, showData: state.showingData.contains(tile.id))
        } else {
            VStack {
                if rt.isRunning { ProgressView() } else {
                    Button("Run") { Task { await state.refresh(tile.id) } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DashboardTileError: View {
    let message: String
    var retry: (() -> Void)?
    var edit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Query failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DashboardTheme.critical)
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DashboardTheme.inkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if retry != nil || edit != nil {
                HStack {
                    if let retry { Button("Retry", action: retry) }
                    if let edit { Button("Edit Query…", action: edit) }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Renders a tile's result according to its kind. Shared by cards and the editor preview.
struct DashboardTileContent: View {
    let state: DashboardState
    let tile: DashboardTile
    let result: QueryResult
    var showData = false

    var body: some View {
        switch tile.kind {
        case .number:
            DashboardNumberView(kpi: DashboardKPI.make(columns: result.columns.map(\.name), rows: result.rows, format: tile.format))
        case .table:
            grid
        case .bar, .line, .area, .pie:
            if showData {
                grid
            } else {
                DashboardChart(tile: tile, data: state.chartData(for: tile, result: result))
            }
        }
    }

    private var grid: some View {
        let _ = state.gridTick
        let m = state.gridModel(for: result)
        return DataGridView(source: m, version: m.version)
            .id(result.id)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DashboardTheme.border))
    }
}

// MARK: - Grid layout

struct DashboardSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

/// Row-packed responsive grid: as many columns of at least `minColumnWidth` as fit
/// (capped at `maxColumns`); tiles span 1 or 2 columns; each row takes its tallest tile's height.
struct DashboardGridLayout: Layout {
    var minColumnWidth: CGFloat = 320
    var spacing: CGFloat = 12
    var maxColumns = 4

    private func frames(width rawWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        // SwiftUI may propose infinite/NaN widths (e.g. during ideal-size queries).
        let width = rawWidth.isFinite && rawWidth > 0 ? rawWidth : minColumnWidth * 2 + spacing
        let cols = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        let colW = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var frames: [CGRect] = []
        var rowStart = 0
        var col = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0

        func closeRow(upTo end: Int) {
            for i in rowStart..<end { frames[i].size.height = rowH }
            y += rowH + spacing
            rowH = 0
            rowStart = end
            col = 0
        }

        for (i, s) in subviews.enumerated() {
            let span = min(cols, max(1, s[DashboardSpanKey.self]))
            if col + span > cols { closeRow(upTo: i) }
            let w = colW * CGFloat(span) + spacing * CGFloat(span - 1)
            let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            frames.append(CGRect(x: CGFloat(col) * (colW + spacing), y: y, width: w, height: h))
            rowH = max(rowH, h)
            col += span
        }
        if rowStart < subviews.count { closeRow(upTo: subviews.count) }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 1000
        let f = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: f.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frames(width: bounds.width, subviews: subviews)
        for (s, r) in zip(subviews, f) {
            s.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: r.width, height: r.height))
        }
    }
}
