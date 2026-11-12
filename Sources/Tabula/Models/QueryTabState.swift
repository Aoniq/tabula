import Foundation
import AppKit
import Observation

struct QueryLogEntry: Identifiable {
    let id = UUID()
    var date = Date()
    var statement: String
    var summary: String
    var duration: TimeInterval
    var isError: Bool
}

/// Requests from state to the editor view (e.g. replace selection after formatting).
enum EditorRequest: Equatable {
    case insert(String)
    case replaceAll(String)
    case select(NSRange)
    case focus
}

@MainActor
@Observable
final class QueryTabState {
    weak var workspace: WorkspaceState?
    var title: String
    var text: String
    var savedQueryID: UUID?

    var results: [QueryResult] = []
    var resultModels: [UUID: ResultGridModel] = [:]
    var selectedResultID: UUID?
    var resultSelection = IndexSet()
    var log: [QueryLogEntry] = []
    var showLog = false
    var running = false
    var error: String?
    var runStarted: Date?

    /// Kept up to date by the editor.
    var selectedRange = NSRange(location: 0, length: 0)
    var editorRequest: EditorRequest?
    var editorRequestID = 0

    init(workspace: WorkspaceState, title: String, text: String) {
        self.workspace = workspace
        self.title = title
        self.text = text
    }

    var selectedResult: QueryResult? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    func model(for r: QueryResult) -> ResultGridModel {
        if let m = resultModels[r.id] { return m }
        let m = ResultGridModel(result: r, workspace: workspace)
        m.onSelection = { [weak self] s in self?.resultSelection = s }
        resultModels[r.id] = m
        return m
    }

    func request(_ r: EditorRequest) {
        editorRequest = r
        editorRequestID += 1
    }

    // MARK: Running

    var selectedText: String? {
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= (text as NSString).length else { return nil }
        let s = (text as NSString).substring(with: selectedRange)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    func statementsToRunCurrent() -> [String] {
        if let sel = selectedText {
            return workspace?.family == .redis ? [sel] : SQLTokenizer.statements(sel)
        }
        if workspace?.family == .redis {
            // current line
            let ns = text as NSString
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: min(selectedRange.location, ns.length), length: 0)))
            return [line.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        }
        guard let r = SQLTokenizer.statementRange(at: selectedRange.location, in: text) else { return [] }
        return [(text as NSString).substring(with: r)]
    }

    func runCurrent() async {
        await run(statementsToRunCurrent())
    }

    func runAll() async {
        let stmts = workspace?.family == .redis ? [text] : SQLTokenizer.statements(text)
        await run(stmts)
    }

    func explainCurrent() async {
        guard let ws = workspace, let stmt = statementsToRunCurrent().first else { return }
        let prefix: String
        switch ws.family {
        case .postgres: prefix = "EXPLAIN (FORMAT TEXT) "
        case .sqlite: prefix = "EXPLAIN QUERY PLAN "
        case .mysql: prefix = "EXPLAIN "
        case .redis: return
        }
        await run([prefix + stmt])
    }

    func run(_ statements: [String]) async {
        guard let ws = workspace, !statements.isEmpty, !running else { return }
        guard ws.approveWrites(statements) else { return }
        running = true
        runStarted = Date()
        error = nil
        results = []
        resultModels = [:]
        selectedResultID = nil
        var hadDDL = false
        for stmt in statements {
            let start = Date()
            do {
                let rs = try await ws.run { try $0.execute(stmt) }
                let dur = Date().timeIntervalSince(start)
                for var r in rs {
                    if r.statement.isEmpty || statements.count > 1 || rs.count == 1 { r.statement = stmt }
                    r.duration = dur
                    results.append(r)
                }
                log.append(QueryLogEntry(statement: stmt, summary: rs.last?.summary ?? "OK", duration: dur, isError: false))
                ws.logHistory(stmt, duration: dur, success: true)
                let kw = SQLTokenizer.leadingKeywords(stmt, count: 1).first ?? ""
                if ["CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE", "USE", "COMMENT"].contains(kw) { hadDDL = true }
            } catch {
                let dur = Date().timeIntervalSince(start)
                self.error = error.localizedDescription
                log.append(QueryLogEntry(statement: stmt, summary: error.localizedDescription, duration: dur, isError: true))
                ws.logHistory(stmt, duration: dur, success: false)
                break
            }
        }
        selectedResultID = results.last(where: { $0.isResultSet })?.id ?? results.last?.id
        running = false
        if error != nil { showLog = results.isEmpty }
        if hadDDL {
            await ws.syncCurrentDatabase()
            await ws.reloadObjects()
        }
    }

    func stop() {
        workspace?.cancelRunning()
    }

    // MARK: Editing helpers

    func format() {
        let upper = Settings.uppercaseKeywords
        if let sel = selectedText {
            request(.insert(SQLFormatter.format(sel, uppercase: upper)))
        } else {
            request(.replaceAll(SQLFormatter.format(text, uppercase: upper)))
        }
    }

    func saveAsFavorite() {
        guard let ws = workspace else { return }
        let store = SavedQueryStore.shared
        if let id = savedQueryID, var existing = store.queries.first(where: { $0.id == id }) {
            existing.sql = text
            store.upsert(existing)
            ws.showToast("Saved “\(existing.name)”")
            return
        }
        let a = NSAlert()
        a.messageText = "Save query"
        a.informativeText = "Saved queries appear under Queries in the sidebar."
        let field = NSTextField(string: title.hasPrefix("Query ") ? "" : title)
        field.placeholderString = "Name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let scope = NSButton(checkboxWithTitle: "Available for all connections", target: nil, action: nil)
        let stack = NSStackView(views: [field, scope])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 52)
        a.accessoryView = stack
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let q = SavedQuery(connectionID: scope.state == .on ? nil : ws.config.id, name: name.isEmpty ? title : name, sql: text)
        store.upsert(q)
        savedQueryID = q.id
        title = q.name
        ws.showToast("Saved “\(q.name)”")
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql")!, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = s
        title = url.lastPathComponent
        request(.replaceAll(s))
    }

    func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql")!]
        panel.nameFieldStringValue = title.hasSuffix(".sql") ? title : title + ".sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            title = url.lastPathComponent
        } catch {
            workspace?.showToast(error.localizedDescription, error: true)
        }
    }
}

// MARK: - Process list

@MainActor
@Observable
final class ProcessListState {
    weak var workspace: WorkspaceState?
    var result = QueryResult()
    var model: ResultGridModel?
    var error: String?
    var loading = false
    var autoRefresh = false
    var selection = IndexSet()
    private var timer: Timer?

    init(workspace: WorkspaceState) { self.workspace = workspace }

    func refresh() async {
        guard let ws = workspace else { return }
        guard let sql = ws.dialect.processListSQL else {
            error = "Process list is not available for \(ws.config.kind.displayName)."
            return
        }
        loading = true
        do {
            let r = try await ws.run { try $0.execute(sql) }.first(where: { $0.isResultSet }) ?? QueryResult()
            result = r
            model = ResultGridModel(result: r, workspace: ws)
            model?.onSelection = { [weak self] s in self?.selection = s }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func killSelected() async {
        guard let ws = workspace else { return }
        let pidCol = result.columns.firstIndex { ["pid", "id"].contains($0.name.lowercased()) } ?? 0
        let pids = selection.compactMap { $0 < result.rows.count ? result.rows[$0][pidCol] : nil }
        guard !pids.isEmpty, ws.confirm("Terminate \(pids.count) process\(pids.count == 1 ? "" : "es")?", pids.joined(separator: ", "), button: "Terminate") else { return }
        for pid in pids {
            if let sql = ws.dialect.killSQL(pid) { _ = try? await ws.run { try $0.execute(sql) } }
        }
        await refresh()
    }

    func setAutoRefresh(_ on: Bool) {
        autoRefresh = on
        timer?.invalidate()
        timer = nil
        if on {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    func stopAutoRefresh() { setAutoRefresh(false) }
}
