import SwiftUI
import AppKit

struct WorkspaceView: View {
    @Bindable var ws: WorkspaceState
    @State private var promptPassword = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch ws.status {
            case .connected:
                main
            case .idle, .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(ws.config.displayName)…").foregroundStyle(.secondary)
                    if ws.config.ssh.enabled { Text("via SSH \(ws.config.ssh.host)").font(.caption).foregroundStyle(.tertiary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsPassword:
                VStack(spacing: 12) {
                    KindBadge(kind: ws.config.kind, size: 48)
                    Text("Password for \(ws.config.displayName)").font(.headline)
                    SecureField("Password", text: $promptPassword)
                        .frame(width: 260)
                        .onSubmit { Task { await ws.connect(password: promptPassword) } }
                    Button("Connect") { Task { await ws.connect(password: promptPassword) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 44)).foregroundStyle(.red)
                    Text("Could not connect to \(ws.config.displayName)").font(.headline)
                    Text(msg).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .multilineTextAlignment(.center).frame(maxWidth: 520)
                    HStack {
                        Button("Connections") { openWindow(id: "connections") }
                        Button("Retry") { Task { await ws.start() } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(ws.windowTitle)
        .navigationSubtitle(ws.isConnected ? ws.serverVersion.components(separatedBy: " on ").first ?? "" : "")
        .focusedSceneValue(\.workspace, ws)
        .background(WindowAccessor { WorkspaceRegistry.register($0, ws) })
        .onDisappear { ws.disconnect() }
    }

    private var main: some View {
        NavigationSplitView {
            SidebarView(ws: ws)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if ws.config.tag != .none {
                    Rectangle().fill(ws.config.tag.color).frame(height: ws.config.tag == .production ? 3 : 2)
                }
                TabBarView(ws: ws)
                Divider()
                ZStack {
                    if let tab = ws.selectedTab {
                        TabContentView(ws: ws, tab: tab).id(tab.id)
                    } else {
                        EmptyWorkspaceView(ws: ws)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .inspector(isPresented: $ws.showInspector) {
                RightPanel(ws: ws)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
            }
        }
        .toolbar { WorkspaceToolbar(ws: ws) }
        .sheet(isPresented: $ws.showOpenAnything) { OpenAnythingView(ws: ws) }
        .sheet(isPresented: $ws.showDatabaseSwitcher) { DatabaseSwitcherView(ws: ws) }
        .sheet(isPresented: $ws.showCreateTable) { CreateTableSheet(ws: ws) }
        .sheet(item: $ws.review) { ReviewSheet(request: $0) }
        .overlay(alignment: .bottom) {
            if let t = ws.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? .red : .green)
                    Text(t.message).lineLimit(4).textSelection(.enabled)
                    Button { ws.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 44)
                .frame(maxWidth: 640)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: ws.toast)
    }
}

struct TabContentView: View {
    let ws: WorkspaceState
    let tab: WorkspaceTab
    var body: some View {
        switch tab.content {
        case .table(let t): TableTabView(tab: t)
        case .query(let q): QueryTabView(ws: ws, query: q)
        case .processes(let p): ProcessListView(state: p)
        case .dashboard(let d): DashboardView(state: d)
        }
    }
}

struct EmptyWorkspaceView: View {
    let ws: WorkspaceState
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.dashed").font(.system(size: 40, weight: .thin)).foregroundStyle(.tertiary)
            Text("Open a table from the sidebar or start a query").foregroundStyle(.secondary)
            HStack {
                Button("New Query  ⌘T") { ws.newQueryTab() }
                Button("Open Anything  ⌘P") { ws.showOpenAnything = true }
            }
        }
    }
}

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var ws: WorkspaceState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                KindBadge(kind: ws.config.kind, size: 20)
                if ws.config.tag != .none { TagPill(tag: ws.config.tag) }
                if ws.config.safeMode != .off {
                    Image(systemName: ws.config.safeMode == .readOnly ? "lock.fill" : "lock.shield")
                        .foregroundStyle(.orange)
                        .help("Safe mode: \(ws.config.safeMode.label)")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if ws.family != .sqlite {
                Menu {
                    ForEach(ws.databases, id: \.self) { db in
                        Button { Task { await ws.switchDatabase(db) } } label: {
                            if db == ws.currentDatabase { Label(db, systemImage: "checkmark") } else { Text(db) }
                        }
                    }
                } label: {
                    Label(ws.currentDatabase.isEmpty ? "Database" : ws.currentDatabase, systemImage: "cylinder")
                }
                .help("Switch database (⌘K)")
            }
            if ws.family == .postgres && !ws.schemas.isEmpty {
                Menu {
                    ForEach(ws.schemas, id: \.self) { s in
                        Button { Task { await ws.switchSchema(s) } } label: {
                            if s == ws.currentSchema { Label(s, systemImage: "checkmark") } else { Text(s) }
                        }
                    }
                } label: {
                    Label(ws.currentSchema ?? "schema", systemImage: "folder")
                }
                .help("Switch schema")
            }
            Button { Task { await ws.reloadObjects(); if let t = ws.selectedTableTab { await t.reload() } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
            Button { ws.newQueryTab() } label: { Label("SQL Query", systemImage: "terminal") }
                .help("New query tab (⌘T)")
            Button { ws.showOpenAnything = true } label: { Label("Open Anything", systemImage: "magnifyingglass") }
                .help("Open anything (⌘P)")
            if let t = ws.selectedTableTab, t.hasChanges {
                Button { t.discardChanges() } label: { Label("Discard", systemImage: "arrow.uturn.backward") }
                    .help("Discard changes")
                Button { t.previewChanges() } label: { Label("Review", systemImage: "doc.text.magnifyingglass") }
                    .help("Review SQL for pending changes (⇧⌘P)")
                Button { Task { await t.commit() } } label: { Label("Commit \(t.changeCount)", systemImage: "checkmark.circle.fill") }
                    .help("Commit changes (⌘S)")
                    .tint(.accentColor)
            }
            Button { ws.showAssistant = true; ws.showInspector = true } label: { Label("AI Assistant", systemImage: "sparkles") }
                .help("AI assistant (⌘J)")
            Button { ws.showAssistant = false; ws.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Row inspector (⌥⌘I)")
        }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Bindable var ws: WorkspaceState
    @State private var hovered: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(ws.tabs) { tab in
                            tabButton(tab).id(tab.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: ws.selectedTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Button { ws.newQueryTab() } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New query tab")
                .padding(.trailing, 6)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        let selected = tab.id == ws.selectedTabID
        return HStack(spacing: 5) {
            Image(systemName: tab.icon).font(.system(size: 11)).foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(tab.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .italic(tab.isPreview)
                .lineLimit(1)
            ZStack {
                if tab.hasPendingChanges && hovered != tab.id {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                } else if selected || hovered == tab.id {
                    Button { ws.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(nsColor: .controlBackgroundColor) : (hovered == tab.id ? Color.primary.opacity(0.05) : .clear))
                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tab.isPreview = false }
        .onTapGesture { ws.select(tab) }
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .contextMenu {
            Button("Close Tab") { ws.closeTab(tab.id) }
            Button("Close Other Tabs") { ws.closeOtherTabs(tab.id) }
            if tab.isPreview { Button("Keep Open") { tab.isPreview = false } }
            if case .query(let q) = tab.content {
                Divider()
                Button("Rename…") { renameQuery(q) }
                Button("Duplicate") { ws.newQueryTab(sql: q.text, title: q.title + " copy") }
            }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            if let s = items.first, let id = UUID(uuidString: s) { ws.moveTab(id, before: tab.id) }
            return true
        }
    }

    private func renameQuery(_ q: QueryTabState) {
        let a = NSAlert()
        a.messageText = "Rename tab"
        let f = NSTextField(string: q.title)
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { q.title = f.stringValue }
    }
}

// MARK: - Review sheet

struct ReviewSheet: View {
    let request: WorkspaceState.ReviewRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text("\(request.statements.count) statement\(request.statements.count == 1 ? "" : "s") will run in a single transaction.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(request.statements.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.statements.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit") { request.onCommit(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 720, height: 460)
    }
}

// MARK: - Database switcher (⌘K)

struct DatabaseSwitcherView: View {
    let ws: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0

    private var items: [(String, Bool)] {
        let dbs = ws.databases.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.map { ($0, true) }
        let schemas = ws.family == .postgres ? ws.schemas.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.map { ($0, false) } : []
        return dbs + schemas
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch to database or schema…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14)
                .onSubmit { choose() }
                .onKeyPress(.downArrow) { index = min(index + 1, max(0, items.count - 1)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        HStack {
                            Image(systemName: item.1 ? "cylinder" : "folder").foregroundStyle(.secondary)
                            Text(item.0)
                            Spacer()
                            if (item.1 && item.0 == ws.currentDatabase) || (!item.1 && item.0 == ws.currentSchema) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                            Text(item.1 ? "database" : "schema").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(i == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; choose() }
                        .id(i)
                    }
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 460, height: 380)
        .onExitCommand { dismiss() }
    }

    private func choose() {
        guard index < items.count else { return }
        let (name, isDB) = items[index]
        dismiss()
        Task { isDB ? await ws.switchDatabase(name) : await ws.switchSchema(name) }
    }
}
