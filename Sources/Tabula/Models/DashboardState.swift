import Foundation
import SwiftUI
import Observation

/// Live state of one tile: its last result or error and refresh timing.
struct DashboardTileRuntime {
    var result: QueryResult?
    var error: String?
    var isRunning = false
    var lastRefreshed: Date?
    var duration: TimeInterval?
}

/// Request to present the add/edit tile sheet.
struct DashboardEditorRequest: Identifiable {
    let id = UUID()
    var tile: DashboardTile
    var isNew: Bool
}

/// Metrics board for one connection: SQL-backed tiles persisted to
/// `AppPaths.support/dashboards/<connection-uuid>.json`.
@MainActor
@Observable
final class DashboardState {
    weak var workspace: WorkspaceState?
    let connectionID: UUID

    private(set) var tiles: [DashboardTile] = []
    private(set) var runtimes: [UUID: DashboardTileRuntime] = [:]
    var refreshInterval: DashboardRefreshInterval = .off {
        didSet {
            guard oldValue != refreshInterval else { return }
            save()
            if autoRefreshActive { startAutoRefresh() }
        }
    }
    private(set) var isRefreshingAll = false
    var editor: DashboardEditorRequest?
    /// Chart tiles currently flipped to their table view.
    var showingData: Set<UUID> = []
    /// Bumped when a table tile's grid re-sorts, to re-render it.
    private(set) var gridTick = 0
    var saveError: String?

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshActive = false
    @ObservationIgnored private var gridModels: [UUID: ResultGridModel] = [:]
    @ObservationIgnored private var chartCache: [Int: DashboardChartData] = [:]

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.connectionID = workspace.config.id
        if let doc = DashboardStore.load(connectionID: connectionID, base: AppPaths.support) {
            tiles = doc.tiles
            refreshInterval = doc.refreshInterval
        }
    }

    var family: DatabaseFamily { workspace?.family ?? .postgres }
    var isSupported: Bool { family != .redis }

    func runtime(_ id: UUID) -> DashboardTileRuntime { runtimes[id] ?? DashboardTileRuntime() }

    // MARK: Persistence

    private func save() {
        do {
            try DashboardStore.save(DashboardDocument(refreshInterval: refreshInterval, tiles: tiles),
                                    connectionID: connectionID, base: AppPaths.support)
            saveError = nil
        } catch {
            saveError = "Couldn’t save dashboard: \(error.localizedDescription)"
            workspace?.showToast(saveError!, error: true)
        }
    }

    // MARK: Running queries

    /// Why `sql` can't be used on a dashboard (empty, or contains a write statement).
    static func validationProblem(_ sql: String) -> String? {
        DashboardSQLGuard.problem(with: sql, statements: SQLTokenizer.statements(sql), isWrite: SQLTokenizer.isWriteStatement)
    }

    /// Run a read-only tile query through the workspace's serial DB queue.
    func execute(_ sql: String) async throws -> QueryResult {
        guard let ws = workspace else { throw DBError("Workspace closed") }
        guard isSupported else { throw DBError("Metrics dashboards need a SQL connection.") }
        if let problem = Self.validationProblem(sql) { throw DBError(problem) }
        let start = Date()
        let results = try await ws.run { driver in try driver.execute(sql) }
        guard var r = results.last(where: { $0.isResultSet }) else {
            throw DBError("The query didn’t return a result set. Dashboard tiles need a SELECT.")
        }
        r.duration = Date().timeIntervalSince(start)
        return r
    }

    func refreshAll() async {
        guard !isRefreshingAll, !tiles.isEmpty else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        let ids = tiles.map(\.id)
        for id in ids { runtimes[id, default: DashboardTileRuntime()].isRunning = true }
        // ws.run serialises on the DB queue anyway; running in order keeps the UI predictable.
        for id in ids {
            if Task.isCancelled { break }
            await run(id)
        }
        for id in ids { runtimes[id]?.isRunning = false }
    }

    func refresh(_ id: UUID) async {
        if runtimes[id]?.isRunning == true { return }
        runtimes[id, default: DashboardTileRuntime()].isRunning = true
        await run(id)
    }

    private func run(_ id: UUID) async {
        guard let tile = tiles.first(where: { $0.id == id }) else { runtimes[id] = nil; return }
        let start = Date()
        do {
            let r = try await execute(tile.sql)
            guard tiles.contains(where: { $0.id == id }) else { return }
            setResult(r, for: id, duration: Date().timeIntervalSince(start))
        } catch {
            guard tiles.contains(where: { $0.id == id }) else { return }
            var rt = runtime(id)
            rt.error = error.localizedDescription
            rt.isRunning = false
            rt.lastRefreshed = Date()
            rt.duration = Date().timeIntervalSince(start)
            runtimes[id] = rt
        }
    }

    private func setResult(_ r: QueryResult, for id: UUID, duration: TimeInterval?) {
        var rt = runtime(id)
        if let old = rt.result { gridModels[old.id] = nil }
        rt.result = r
        rt.error = nil
        rt.isRunning = false
        rt.lastRefreshed = Date()
        rt.duration = duration ?? r.duration
        runtimes[id] = rt
    }

    /// Cached read-only grid model for a table tile's result.
    func gridModel(for r: QueryResult) -> ResultGridModel {
        if let m = gridModels[r.id] { return m }
        let m = ResultGridModel(result: r, workspace: workspace)
        m.onChange = { [weak self] in self?.gridTick += 1 }
        gridModels[r.id] = m
        return m
    }

    /// Chart data for a tile/result pair, cached so hover re-renders don't re-parse rows.
    func chartData(for tile: DashboardTile, result: QueryResult) -> DashboardChartData {
        var h = Hasher()
        h.combine(result.id)
        h.combine(tile.kind)
        h.combine(tile.xColumn)
        h.combine(tile.yColumns)
        h.combine(tile.seriesColumn)
        let key = h.finalize()
        if let d = chartCache[key] { return d }
        let d = DashboardChartData.make(columns: result.columns.map(\.name), rows: result.rows, tile: tile)
        if chartCache.count > 64 { chartCache.removeAll() }
        chartCache[key] = d
        return d
    }

    /// Drop grid models for results no tile shows any more (e.g. editor previews).
    func pruneGridModels() {
        let live = Set(runtimes.values.compactMap { $0.result?.id })
        gridModels = gridModels.filter { live.contains($0.key) }
    }

    // MARK: Auto refresh

    func startAutoRefresh() {
        autoRefreshActive = true
        timer?.cancel()
        timer = nil
        let seconds = refreshInterval.rawValue
        guard seconds > 0 else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                guard let self else { break }
                await self.refreshAll()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshActive = false
        timer?.cancel()
        timer = nil
    }

    // MARK: Editing

    func beginAdd() {
        editor = DashboardEditorRequest(tile: DashboardTile(title: "", sql: "", kind: .bar), isNew: true)
    }

    func beginEdit(_ tile: DashboardTile) {
        editor = DashboardEditorRequest(tile: tile, isNew: false)
    }

    /// Insert or replace a tile. A preview result for the same SQL is reused instead of re-running.
    func commit(_ tile: DashboardTile, preview: QueryResult?) {
        if let i = tiles.firstIndex(where: { $0.id == tile.id }) {
            tiles[i] = tile
        } else {
            tiles.append(tile)
        }
        save()
        if let preview {
            setResult(preview, for: tile.id, duration: preview.duration)
        } else {
            Task { await refresh(tile.id) }
        }
        pruneGridModels()
    }

    func duplicate(_ tile: DashboardTile) {
        var copy = tile
        copy.id = UUID()
        copy.title = tile.title + " copy"
        let idx = (tiles.firstIndex { $0.id == tile.id } ?? tiles.count - 1) + 1
        tiles.insert(copy, at: idx)
        if let r = runtimes[tile.id]?.result { setResult(r, for: copy.id, duration: runtimes[tile.id]?.duration) }
        save()
    }

    func delete(_ tile: DashboardTile) {
        tiles.removeAll { $0.id == tile.id }
        if let r = runtimes[tile.id]?.result { gridModels[r.id] = nil }
        runtimes[tile.id] = nil
        showingData.remove(tile.id)
        save()
    }

    func move(_ tile: DashboardTile, by delta: Int) {
        guard let i = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        let j = i + delta
        guard tiles.indices.contains(j) else { return }
        tiles.swapAt(i, j)
        save()
    }

    func canMove(_ tile: DashboardTile, by delta: Int) -> Bool {
        guard let i = tiles.firstIndex(where: { $0.id == tile.id }) else { return false }
        return tiles.indices.contains(i + delta)
    }

    func toggleData(_ id: UUID) {
        if showingData.contains(id) { showingData.remove(id) } else { showingData.insert(id) }
    }

    func openInQueryTab(_ tile: DashboardTile) {
        workspace?.newQueryTab(sql: tile.sql, title: tile.title)
    }

    // MARK: Samples

    var sampleTiles: [DashboardTile] {
        let tables = (workspace?.objects ?? []).filter { $0.kind == .table }.map(\.name)
        return DashboardSamples.tiles(family: family, tables: tables)
    }

    func addSampleTiles() {
        let samples = sampleTiles
        guard !samples.isEmpty else { return }
        tiles.append(contentsOf: samples)
        save()
        Task {
            for t in samples { await refresh(t.id) }
        }
    }
}
