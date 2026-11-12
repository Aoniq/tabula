import SwiftUI
import AppKit

@main
struct TabulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        Settings.register()
    }

    var body: some Scene {
        Window("Tabula", id: "connections") {
            WelcomeView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 920, height: 600)
        .windowResizability(.contentMinSize)
        .commands { TabulaCommands() }

        WindowGroup("Workspace", id: "workspace", for: UUID.self) { $id in
            WorkspaceRoot(connectionID: id)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1360, height: 860)

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

/// Lets AppKit code (dock, open-file, menus) reach SwiftUI window actions.
@MainActor
final class AppRouter {
    static let shared = AppRouter()
    var openWorkspace: ((UUID) -> Void)?
    var openConnections: (() -> Void)?
    var pendingSQLiteFiles: [URL] = []

    func connect(_ id: UUID) {
        openWorkspace?(id)
    }

    func openSQLiteFile(_ url: URL) {
        let store = ConnectionStore.shared
        let path = url.path
        let config: ConnectionConfig
        if let existing = store.connections.first(where: { $0.kind == .sqlite && $0.filePath == path }) {
            config = existing
        } else {
            var c = ConnectionConfig()
            c.kind = .sqlite
            c.filePath = path
            c.name = url.lastPathComponent
            c.port = 0
            store.upsert(c)
            config = c
        }
        if let open = openWorkspace { open(config.id) } else { pendingSQLiteFiles.append(url) }
    }
}

/// Weak map from windows to their workspace (for ⌘W tab closing).
@MainActor
enum WorkspaceRegistry {
    private static var map: [ObjectIdentifier: WeakBox] = [:]
    final class WeakBox { weak var ws: WorkspaceState?; init(_ ws: WorkspaceState) { self.ws = ws } }

    static func register(_ window: NSWindow, _ ws: WorkspaceState) {
        map[ObjectIdentifier(window)] = WeakBox(ws)
    }

    static func workspace(for window: NSWindow?) -> WorkspaceState? {
        guard let window else { return nil }
        return map[ObjectIdentifier(window)]?.ws
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppearanceMode.current.nsAppearance
        if DevSnapshot.requested {
            Task { @MainActor in await DevSnapshot.run() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘W closes the current tab instead of the window while tabs are open.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "w",
               let ws = MainActor.assumeIsolated({ WorkspaceRegistry.workspace(for: NSApp.keyWindow) }) {
                let handled: Bool = MainActor.assumeIsolated {
                    guard let id = ws.selectedTabID else { return false }
                    ws.closeTab(id)
                    return true
                }
                if handled { return nil }
            }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppRouter.shared.openConnections?() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppRouter.shared.openSQLiteFile(url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = MainActor.assumeIsolated {
            NSApp.windows.compactMap { WorkspaceRegistry.workspace(for: $0) }.contains { $0.tabs.contains(where: \.hasPendingChanges) }
        }
        if dirty {
            let a = NSAlert()
            a.messageText = "Quit with uncommitted changes?"
            a.informativeText = "Some tabs have changes that were not committed to the database."
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }
}

extension AppearanceMode {
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct WorkspaceRoot: View {
    let connectionID: UUID?
    @State private var ws: WorkspaceState?
    @State private var missing = false

    var body: some View {
        Group {
            if let ws {
                WorkspaceView(ws: ws)
            } else if missing {
                ContentUnavailableView("Connection not found", systemImage: "questionmark.folder", description: Text("This connection was deleted."))
            } else {
                ProgressView()
            }
        }
        .task {
            guard ws == nil else { return }
            guard let id = connectionID, let c = ConnectionStore.shared.connection(id) else { missing = true; return }
            let w = WorkspaceState(config: c)
            ws = w
            await w.start()
        }
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

// MARK: - Focused workspace

struct WorkspaceFocusKey: FocusedValueKey { typealias Value = WorkspaceState }

extension FocusedValues {
    var workspace: WorkspaceState? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

// MARK: - Menus

struct TabulaCommands: Commands {
    @FocusedValue(\.workspace) private var ws
    @Environment(\.openWindow) private var openWindow

    private var hasWS: Bool { ws?.isConnected == true }
    private var table: TableTabState? { ws?.selectedTableTab }
    private var query: QueryTabState? { ws?.selectedQueryTab }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                openWindow(id: "connections")
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Connections") { openWindow(id: "connections") }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Open SQLite File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { AppRouter.shared.openSQLiteFile(url) }
            }
            Divider()
            Button("New Query Tab") { ws?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(!hasWS)
            Button("Open SQL File…") { ws?.newQueryTab().openFile() }
                .keyboardShortcut("o")
                .disabled(!hasWS)
            Button("Save Query…") { query?.saveAsFavorite() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(query == nil)
            Button("Save Query to File…") { query?.saveFile() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(query == nil)
            Divider()
            Menu("Import") {
                Button("CSV into Current Table…") { if let t = table { ImportController.importCSV(into: t) } }
                    .disabled(table == nil || table?.canEditData == false)
                Button("Run SQL File…") { if let ws { ImportController.runSQLFile(ws) } }
                    .disabled(!hasWS)
            }
            Menu("Export") {
                Button("Current Table…") { if let t = table { ExportController.exportTable(t) } }
                    .disabled(table == nil)
                Button("Query Result…") { if let q = query { ExportController.exportResult(q) } }
                    .disabled(query?.selectedResult?.isResultSet != true)
            }
            Divider()
            Button("Backup Database…") { if let ws { DumpController.backup(ws) } }
                .disabled(!hasWS || ws?.family == .redis)
            Button("Restore Database…") { if let ws { DumpController.restore(ws) } }
                .disabled(!hasWS || ws?.family == .redis)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Toggle Comment") { NSApp.sendAction(#selector(SQLTextView.toggleComment), to: nil, from: nil) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Format SQL") { query?.format() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(query == nil)
        }

        CommandMenu("Query") {
            Button("Run Current Statement") { Task { await query?.runCurrent() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(query == nil)
            Button("Run All") { Task { await query?.runAll() } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(query == nil)
            Button("Explain Current Statement") { Task { await query?.explainCurrent() } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(query == nil)
            Button("Stop") { ws?.cancelRunning() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!hasWS)
        }

        CommandMenu("Data") {
            Button(table != nil ? "Filter Rows" : "Find") {
                if let t = table {
                    t.showFilters.toggle()
                    if t.showFilters && t.filters.isEmpty { t.addFilter() }
                } else {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Add Row") { table?.addRow() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(table?.canEditData != true)
            Button("Duplicate Row") { if let t = table { t.duplicateRows(t.selection) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(table?.canEditData != true || table?.selection.isEmpty == true)
            Divider()
            Button("Commit Changes") { Task { await table?.commit() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(table?.hasChanges != true)
            Button("Review Changes…") { table?.previewChanges() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(table?.hasChanges != true)
            Button("Discard Changes") { table?.discardChanges() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(table?.hasChanges != true)
            Divider()
            Button("Show Data") { table?.switchMode(.data) }
                .keyboardShortcut("[", modifiers: [.command, .control])
                .disabled(table == nil)
            Button("Show Structure") { table?.switchMode(.structure) }
                .keyboardShortcut("]", modifiers: [.command, .control])
                .disabled(table == nil)
            Divider()
            Button("Next Page") { if let t = table { t.goToPage(t.page + 1) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(table == nil)
            Button("Previous Page") { if let t = table { t.goToPage(t.page - 1) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(table == nil)
        }

        CommandMenu("Navigate") {
            Button("Open Anything…") { ws?.showOpenAnything = true }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasWS)
            Button("Switch Database…") { ws?.showDatabaseSwitcher = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!hasWS)
            Divider()
            Button("Next Tab") { ws?.selectNextTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { ws?.selectNextTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Refresh") {
                Task {
                    if let t = table { await t.mode == .data ? t.reload() : t.loadStructure() }
                    await ws?.reloadObjects()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!hasWS)
            Button("Toggle Row Inspector") { ws?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!hasWS)
            Button("AI Assistant") {
                ws?.showInspector = true
                ws?.showAssistant = true
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!hasWS)
        }

        CommandMenu("Database") {
            Button("Create Table…") { ws?.showCreateTable = true }
                .disabled(!hasWS || ws?.family == .redis)
            Button("Process List") { ws?.openProcessList() }
                .disabled(!hasWS || ws?.dialect.processListSQL == nil)
            Button("Users & Roles") {
                if let ws, let sql = ws.dialect.usersSQL { ws.newQueryTab(sql: sql, title: "Users", run: true) }
            }
            .disabled(!hasWS || ws?.dialect.usersSQL == nil)
            Button("Metrics Dashboard") { ws?.openDashboard() }
                .disabled(!hasWS || ws?.family == .redis)
            Divider()
            Button("Reconnect") { Task { await ws?.reconnect() } }
                .disabled(ws == nil)
        }
    }
}

extension Notification.Name {
    static let newConnection = Notification.Name("TabulaNewConnection")
}
