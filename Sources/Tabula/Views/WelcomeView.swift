import SwiftUI
import AppKit

struct KindBadge: View {
    let kind: DatabaseKind
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(kind.color.gradient)
            .frame(width: size, height: size)
            .overlay(Text(kind.badge).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white))
    }
}

struct TagPill: View {
    let tag: EnvironmentTag
    var body: some View {
        if tag != .none {
            Text(tag.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(tag.color.opacity(0.18), in: Capsule())
                .foregroundStyle(tag.color)
        }
    }
}

struct WelcomeView: View {
    @State private var store = ConnectionStore.shared
    @State private var selection: UUID?
    @State private var editing: ConnectionConfig?
    @State private var search = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var filtered: [ConnectionConfig] {
        let all = store.connections.sorted { ($0.group, $0.displayName.lowercased()) < ($1.group, $1.displayName.lowercased()) }
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
    }

    private var grouped: [(String, [ConnectionConfig])] {
        Dictionary(grouping: filtered, by: \.group).sorted { a, b in
            if a.key.isEmpty { return false }
            if b.key.isEmpty { return true }
            return a.key < b.key
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "tablecells.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tabula").font(.title2.weight(.semibold))
                        Text("Database client").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                TextField("Search connections", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                List(selection: $selection) {
                    ForEach(grouped, id: \.0) { group, items in
                        Section(group.isEmpty ? (grouped.count > 1 ? "Ungrouped" : "Connections") : group) {
                            ForEach(items) { c in
                                ConnectionRow(config: c).tag(c.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first {
                        Button("Connect") { connect(id) }
                        Button("Edit…") { editing = store.connection(id) }
                        Button("Duplicate") { if let c = store.duplicate(id) { selection = c.id } }
                        Divider()
                        Button("Delete", role: .destructive) { delete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { connect(id) }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Button("New Connection…") { newConnection() }
                        Button("Open SQLite File…") { openSQLite() }
                        Button("Import from URL…") { importURL() }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Button { if let s = selection { delete(s) } } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).disabled(selection == nil)
                    Spacer()
                    Text("\(store.connections.count) connections").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(width: 300)
            Divider()
            Group {
                if let draft = editing {
                    ConnectionFormView(draft: draft, onCancel: { editing = nil }, onSave: { c in
                        store.upsert(c); selection = c.id; editing = nil
                    }, onConnect: { c in
                        store.upsert(c); selection = c.id; editing = nil; connect(c.id)
                    })
                    .id(draft.id)
                } else if let id = selection, let c = store.connection(id) {
                    ConnectionSummary(config: c, onConnect: { connect(id) }, onEdit: { editing = c })
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "cylinder.split.1x2").font(.system(size: 54, weight: .thin)).foregroundStyle(.secondary)
                        Text("Welcome to Tabula").font(.title.weight(.semibold))
                        Text("PostgreSQL · MySQL · MariaDB · SQLite · Redis · CockroachDB · Redshift")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("New Connection") { newConnection() }.buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Open SQLite File") { openSQLite() }.controlSize(.large)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            AppRouter.shared.openWorkspace = { id in openWindow(id: "workspace", value: id) }
            AppRouter.shared.openConnections = { openWindow(id: "connections") }
            let pending = AppRouter.shared.pendingSQLiteFiles
            AppRouter.shared.pendingSQLiteFiles = []
            pending.forEach { AppRouter.shared.openSQLiteFile($0) }
            if selection == nil { selection = store.connections.max { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in newConnection() }
    }

    private func newConnection() {
        var c = ConnectionConfig()
        c.user = c.kind.defaultUser
        editing = c
    }

    private func connect(_ id: UUID) {
        openWindow(id: "workspace", value: id)
        dismissWindow(id: "connections")
    }

    private func delete(_ id: UUID) {
        guard let c = store.connection(id) else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(c.displayName)”?"
        a.informativeText = "The saved password is removed from the Keychain as well."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.delete(id)
        if selection == id { selection = nil }
    }

    private func openSQLite() {
        let panel = NSOpenPanel()
        panel.message = "Choose an SQLite database file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppRouter.shared.openSQLiteFile(url)
        dismissWindow(id: "connections")
    }

    private func importURL() {
        let a = NSAlert()
        a.messageText = "Import connection from URL"
        a.informativeText = "e.g. postgres://user:pass@host:5432/db, mysql://…, redis://…"
        let f = NSTextField(string: NSPasteboard.general.string(forType: .string) ?? "")
        f.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let (c, pw) = ConnectionURL.parse(f.stringValue) else { return }
        var draft = c
        if let pw { Keychain.set(pw, account: draft.passwordAccount) }
        draft.name = draft.name.isEmpty ? (c.host) : draft.name
        editing = draft
    }
}

struct ConnectionRow: View {
    let config: ConnectionConfig
    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: config.kind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.displayName).font(.body.weight(.medium)).lineLimit(1)
                    TagPill(tag: config.tag)
                }
                Text(config.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ConnectionSummary: View {
    let config: ConnectionConfig
    var onConnect: () -> Void
    var onEdit: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            KindBadge(kind: config.kind, size: 64)
            VStack(spacing: 4) {
                Text(config.displayName).font(.title2.weight(.semibold))
                Text(config.kind.displayName + " · " + config.subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    TagPill(tag: config.tag)
                    if config.safeMode != .off {
                        Label(config.safeMode.label, systemImage: "lock.shield").font(.caption).foregroundStyle(.orange)
                    }
                    if config.ssh.enabled { Label("SSH", systemImage: "network.badge.shield.half.filled").font(.caption).foregroundStyle(.secondary) }
                }
                if let d = config.lastUsed {
                    Text("Last used \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Button("Edit") { onEdit() }.controlSize(.large)
                Button("Connect") { onConnect() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ConnectionURL {
    static func parse(_ s: String) -> (ConnectionConfig, String?)? {
        guard let comps = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = comps.scheme?.lowercased() else { return nil }
        var c = ConnectionConfig()
        switch scheme {
        case "postgres", "postgresql": c.kind = .postgresql
        case "mysql": c.kind = .mysql
        case "mariadb": c.kind = .mariadb
        case "redis", "rediss": c.kind = .redis
        case "cockroachdb": c.kind = .cockroachdb
        case "sqlite", "file":
            c.kind = .sqlite
            c.filePath = comps.path
            return (c, nil)
        default: return nil
        }
        c.host = comps.host ?? "127.0.0.1"
        c.port = comps.port ?? c.kind.defaultPort
        c.user = comps.user?.removingPercentEncoding ?? c.kind.defaultUser
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.database = path
        if let ssl = comps.queryItems?.first(where: { $0.name == "sslmode" })?.value, let m = SSLMode(rawValue: ssl) { c.ssl.mode = m }
        return (c, comps.password?.removingPercentEncoding)
    }
}
