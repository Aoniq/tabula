import Foundation
import SwiftUI
import AppKit
import Observation

enum SidebarMode: String, CaseIterable, Identifiable {
    case items = "Items", queries = "Queries", history = "History"
    var id: String { rawValue }
}

@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    enum Content {
        case table(TableTabState)
        case query(QueryTabState)
        case processes(ProcessListState)
        case dashboard(DashboardState)
        case erd(ERDState)
    }
    let id = UUID()
    let content: Content
    /// Preview tabs get replaced when another item is single-clicked in the sidebar.
    var isPreview = false

    init(_ content: Content) { self.content = content }

    var title: String {
        switch content {
        case .table(let t): return t.object.name
        case .query(let q): return q.title
        case .processes: return "Processes"
        case .dashboard: return "Metrics"
        case .erd: return "ER Diagram"
        }
    }

    var icon: String {
        switch content {
        case .table(let t): return t.object.kind.symbol
        case .query: return "terminal"
        case .processes: return "cpu"
        case .dashboard: return "chart.bar.xaxis"
        case .erd: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    var hasPendingChanges: Bool {
        if case .table(let t) = content { return t.hasChanges }
        return false
    }
}

@MainActor
@Observable
final class WorkspaceState {
    enum Status: Equatable {
        case idle, needsPassword, connecting, connected, failed(String)
    }

    var config: ConnectionConfig
    private(set) var session: DBSession?
    /// Password used for the live session (needed by external tools like pg_dump).
    private(set) var connectionPassword = ""
    var status: Status = .idle
    var serverVersion = ""

    var databases: [String] = []
    var currentDatabase = ""
    var schemas: [String] = []
    var currentSchema: String?
    var objects: [DBObject] = []
    var loadingObjects = false

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?

    var sidebarMode: SidebarMode = .items
    var sidebarFilter = ""
    var showInspector = false
    var showOpenAnything = false
    var showDatabaseSwitcher = false
    var showCreateTable = false
    var showAssistant = false
    var review: ReviewRequest?
    var toast: Toast?

    private(set) var columnCache: [String: [ColumnInfo]] = [:]
    private var columnLoads: Set<String> = []
    let assistant = AssistantState()

    struct ReviewRequest: Identifiable {
        let id = UUID()
        var title: String
        var statements: [String]
        var onCommit: () -> Void
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    init(config: ConnectionConfig) {
        self.config = config
    }

    var family: DatabaseFamily { config.kind.family }
    var dialect: SQLDialect { SQLDialect(family: family) }
    var isConnected: Bool { status == .connected }

    /// Host/port to reach the server (the local tunnel end when SSH is used).
    var endpoint: (host: String, port: Int) {
        if let t = session?.tunnel { return ("127.0.0.1", t.localPort) }
        return (config.host == "localhost" ? "127.0.0.1" : config.host, config.port)
    }

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var selectedTableTab: TableTabState? {
        if case .table(let t) = selectedTab?.content { return t }
        return nil
    }

    var selectedQueryTab: QueryTabState? {
        if case .query(let q) = selectedTab?.content { return q }
        return nil
    }

    var windowTitle: String {
        var t = config.displayName
        if !currentDatabase.isEmpty && family != .sqlite { t += " — \(currentDatabase)" }
        if let s = currentSchema, family == .postgres { t += " / \(s)" }
        return t
    }

    // MARK: Connection lifecycle

    var needsPasswordPrompt: Bool {
        !config.savePassword && family != .sqlite
    }

    func start() async {
        if needsPasswordPrompt && session == nil {
            status = .needsPassword
            return
        }
        await connect(password: nil)
    }

    func connect(password: String?) async {
        status = .connecting
        let pw = password ?? Keychain.get(account: config.passwordAccount) ?? ""
        let sshSecret = config.ssh.enabled && config.ssh.auth != .agent ? Keychain.get(account: config.sshPasswordAccount) : nil
        do {
            let s = try await DBSession.open(config: config, password: pw, sshSecret: sshSecret)
            session = s
            connectionPassword = pw
            serverVersion = (try? await s.run { $0.serverVersion() }) ?? ""
            status = .connected
            ConnectionStore.shared.touch(config.id)
            await reloadAll()
            if tabs.isEmpty && family != .redis { newQueryTab(select: false) }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        session?.close()
        session = nil
        status = .idle
    }

    func reconnect() async {
        session?.close()
        session = nil
        await start()
    }

    // MARK: Running SQL

    func run<T>(_ body: @escaping (DatabaseDriver) throws -> T) async throws -> T {
        guard let session else { throw DBError("Not connected") }
        return try await session.run(body)
    }

    func cancelRunning() {
        session?.cancel()
    }

    /// Execute statements as one transaction (best effort for engines with implicit DDL commits).
    func executeTransaction(_ statements: [String]) async throws {
        let fam = family
        let start = Date()
        do {
            try await run { d in
                if fam == .redis {
                    for s in statements { _ = try d.execute(s) }
                    return
                }
                _ = try d.execute(fam == .mysql ? "START TRANSACTION" : "BEGIN")
                do {
                    for s in statements { _ = try d.execute(s) }
                    _ = try d.execute("COMMIT")
                } catch {
                    _ = try? d.execute("ROLLBACK")
                    throw error
                }
            }
            logHistory(statements.joined(separator: "\n"), duration: Date().timeIntervalSince(start), success: true)
        } catch {
            logHistory(statements.joined(separator: "\n"), duration: Date().timeIntervalSince(start), success: false)
            throw error
        }
    }

    func logHistory(_ sql: String, duration: TimeInterval, success: Bool) {
        HistoryStore.shared.add(HistoryItem(connectionID: config.id, database: currentDatabase, sql: sql, date: Date(), duration: duration, success: success))
    }

    /// Safe-mode gate. Returns true when the statements may run.
    func approveWrites(_ statements: [String]) -> Bool {
        let writes = statements.filter { SQLTokenizer.isWriteStatement($0) }
        guard !writes.isEmpty else { return true }
        switch config.safeMode {
        case .off:
            return true
        case .readOnly:
            let a = NSAlert()
            a.messageText = "This connection is read-only"
            a.informativeText = "Safe mode blocks statements that modify data or schema. Change it in the connection settings."
            a.alertStyle = .warning
            a.runModal()
            return false
        case .confirmWrites:
            let a = NSAlert()
            a.messageText = "Run \(writes.count) statement\(writes.count == 1 ? "" : "s") that modify \(config.displayName)?"
            let preview = writes.prefix(12).joined(separator: "\n")
            a.informativeText = String(preview.prefix(1500)) + (writes.count > 12 ? "\n…" : "")
            a.alertStyle = config.tag == .production ? .critical : .warning
            a.addButton(withTitle: "Run")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    func showToast(_ message: String, error: Bool = false) {
        let t = Toast(message: message, isError: error)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 3)) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: Metadata

    func reloadAll() async {
        do {
            databases = try await run { try $0.listDatabases() }
            currentDatabase = try await run { $0.currentDatabase }
            schemas = try await run { try $0.listSchemas() }
            if currentSchema == nil || !(schemas.contains(currentSchema ?? "")) {
                let def = try await run { $0.defaultSchema() }
                currentSchema = schemas.contains(def ?? "") ? def : schemas.first
            }
        } catch {
            showToast(error.localizedDescription, error: true)
        }
        await reloadObjects()
    }

    func reloadObjects() async {
        loadingObjects = true
        defer { loadingObjects = false }
        let schema = currentSchema
        do {
            objects = try await run { try $0.listObjects(schema: schema) }
            columnCache.removeAll()
        } catch {
            objects = []
            showToast(error.localizedDescription, error: true)
        }
    }

    func switchDatabase(_ name: String) async {
        guard name != currentDatabase || family == .redis else { return }
        if tabs.contains(where: \.hasPendingChanges) {
            let a = NSAlert()
            a.messageText = "Discard uncommitted changes?"
            a.informativeText = "Switching database closes table tabs with pending changes."
            a.addButton(withTitle: "Discard & Switch")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        do {
            try await run { try $0.useDatabase(name) }
            currentDatabase = name
            tabs.removeAll { if case .table = $0.content { return true } else { return false } }
            if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.last?.id }
            currentSchema = nil
            await reloadAll()
        } catch {
            showToast(error.localizedDescription, error: true)
        }
    }

    func switchSchema(_ name: String) async {
        currentSchema = name
        await reloadObjects()
    }

    func syncCurrentDatabase() async {
        if let db = try? await run({ $0.currentDatabase }), db != currentDatabase {
            currentDatabase = db
            await reloadAll()
        }
    }

    func cacheKey(_ o: DBObject) -> String { "\(o.schema ?? ""):\(o.name)" }

    func cachedColumns(_ o: DBObject) -> [ColumnInfo]? { columnCache[cacheKey(o)] }

    func columns(for o: DBObject) async -> [ColumnInfo] {
        if let c = columnCache[cacheKey(o)] { return c }
        let cols = (try? await run { try $0.columns(of: o) }) ?? []
        columnCache[cacheKey(o)] = cols
        return cols
    }

    /// Kick off a background column load (used by autocompletion).
    func prefetchColumns(_ o: DBObject) {
        let key = cacheKey(o)
        guard columnCache[key] == nil, !columnLoads.contains(key) else { return }
        columnLoads.insert(key)
        Task {
            _ = await columns(for: o)
            columnLoads.remove(key)
        }
    }

    func setCachedColumns(_ cols: [ColumnInfo], for o: DBObject) {
        columnCache[cacheKey(o)] = cols
    }

    func findObject(named name: String) -> DBObject? {
        let parts = name.split(separator: ".").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]")) }
        guard let last = parts.last else { return nil }
        return objects.first { $0.kind.isBrowsable && $0.name.caseInsensitiveCompare(last) == .orderedSame }
    }

    // MARK: Tabs

    func select(_ tab: WorkspaceTab) { selectedTabID = tab.id }

    func openTable(_ o: DBObject, mode: TableTabState.Mode = .data, preview: Bool = false) {
        if let existing = tabs.first(where: { if case .table(let t) = $0.content { return t.object == o } else { return false } }) {
            if case .table(let t) = existing.content, t.mode != mode { t.switchMode(mode) }
            if !preview { existing.isPreview = false }
            selectedTabID = existing.id
            return
        }
        let state = TableTabState(workspace: self, object: o, mode: mode)
        let tab = WorkspaceTab(.table(state))
        tab.isPreview = preview
        if preview, let idx = tabs.firstIndex(where: { $0.isPreview && !$0.hasPendingChanges }) {
            tabs[idx] = tab
        } else if let sel = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: sel + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        Task { await state.initialLoad() }
    }

    @discardableResult
    func newQueryTab(sql: String = "", title: String? = nil, run: Bool = false, select: Bool = true, saved: SavedQuery? = nil) -> QueryTabState {
        let n = tabs.filter { if case .query = $0.content { return true } else { return false } }.count + 1
        let q = QueryTabState(workspace: self, title: title ?? "Query \(n)", text: sql)
        q.savedQueryID = saved?.id
        let tab = WorkspaceTab(.query(q))
        tabs.append(tab)
        if select || selectedTabID == nil { selectedTabID = tab.id }
        if run { Task { await q.runAll() } }
        return q
    }

    func openProcessList() {
        if let t = tabs.first(where: { if case .processes = $0.content { return true } else { return false } }) {
            selectedTabID = t.id
            return
        }
        let p = ProcessListState(workspace: self)
        let tab = WorkspaceTab(.processes(p))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await p.refresh() }
    }

    func openDashboard() {
        if let t = tabs.first(where: { if case .dashboard = $0.content { return true } else { return false } }) {
            selectedTabID = t.id
            return
        }
        let d = DashboardState(workspace: self)
        let tab = WorkspaceTab(.dashboard(d))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await d.refreshAll() }
    }

    /// Open (or focus) the ER diagram tab, optionally selecting a table.
    func openERD(select o: DBObject? = nil) {
        let id = o.map { ERDTable.makeID(schema: family == .postgres ? ($0.schema ?? currentSchema) : $0.schema, name: $0.name) }
        if let t = tabs.first(where: { if case .erd = $0.content { return true } else { return false } }), case .erd(let e) = t.content {
            selectedTabID = t.id
            if let id {
                e.selected = id
                e.request(.center(id))
            }
            return
        }
        let e = ERDState(workspace: self, select: id)
        let tab = WorkspaceTab(.erd(e))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openDefinition(_ o: DBObject) {
        Task {
            do {
                let ddl = try await run { try $0.ddl(of: o) }
                newQueryTab(sql: ddl, title: o.name + " (definition)")
            } catch {
                showToast(error.localizedDescription, error: true)
            }
        }
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        if tab.hasPendingChanges {
            let a = NSAlert()
            a.messageText = "Discard uncommitted changes in “\(tab.title)”?"
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        if case .processes(let p) = tab.content { p.stopAutoRefresh() }
        tabs.remove(at: idx)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }

    func closeOtherTabs(_ id: UUID) {
        for t in tabs where t.id != id { closeTab(t.id) }
    }

    func selectNextTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let idx = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(idx + delta + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
    }

    // MARK: Object operations

    func confirm(_ title: String, _ detail: String, button: String, destructive: Bool = true) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = destructive ? .critical : .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        if destructive { a.buttons.first?.hasDestructiveAction = true }
        return a.runModal() == .alertFirstButtonReturn
    }

    func runAdminStatement(_ sql: String, success: String) async {
        guard approveWrites([sql]) else { return }
        do {
            let start = Date()
            _ = try await run { try $0.execute(sql) }
            logHistory(sql, duration: Date().timeIntervalSince(start), success: true)
            showToast(success)
            await reloadObjects()
        } catch {
            showToast(error.localizedDescription, error: true)
        }
    }

    func drop(_ o: DBObject) async {
        let sql = dialect.dropSQL(o)
        if Settings.confirmDrop && !confirm("Drop \(o.kind.label.lowercased().dropLast()) “\(o.name)”?", sql, button: "Drop") { return }
        tabs.removeAll { if case .table(let t) = $0.content { return t.object == o } else { return false } }
        await runAdminStatement(sql, success: "Dropped \(o.name)")
    }

    func truncate(_ o: DBObject) async {
        let sql = dialect.truncateSQL(o)
        if !confirm("Truncate “\(o.name)”?", "All rows will be deleted.\n\n\(sql)", button: "Truncate") { return }
        await runAdminStatement(sql, success: "Truncated \(o.name)")
        for t in tabs { if case .table(let s) = t.content, s.object == o { await s.reload() } }
    }

    func rename(_ o: DBObject) async {
        let a = NSAlert()
        a.messageText = "Rename “\(o.name)”"
        let field = NSTextField(string: o.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != o.name else { return }
        tabs.removeAll { if case .table(let t) = $0.content { return t.object == o } else { return false } }
        await runAdminStatement(dialect.renameSQL(o, to: newName), success: "Renamed to \(newName)")
    }

    func refreshMaterializedView(_ o: DBObject) async {
        await runAdminStatement("REFRESH MATERIALIZED VIEW \(dialect.qualified(o));", success: "Refreshed \(o.name)")
    }
}
