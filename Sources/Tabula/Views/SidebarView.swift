import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var ws: WorkspaceState
    @State private var selection: String?
    @State private var expanded: Set<ObjectKind> = [.table, .view]
    @State private var savedStore = SavedQueryStore.shared
    @State private var historyStore = HistoryStore.shared
    @State private var historySearch = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.sidebarMode) {
                ForEach(SidebarMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)

            switch ws.sidebarMode {
            case .items: itemsView
            case .queries: queriesView
            case .history: historyView
            }
        }
    }

    // MARK: Items

    private var filteredObjects: [DBObject] {
        let f = ws.sidebarFilter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return ws.objects }
        return ws.objects.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    private var itemsView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(ws.family == .redis ? "Filter keys" : "Filter items", text: $ws.sidebarFilter)
                    .textFieldStyle(.plain)
                if !ws.sidebarFilter.isEmpty {
                    Button { ws.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.bottom, 6)

            let objs = filteredObjects
            let kinds = ObjectKind.allCases.filter { k in objs.contains { $0.kind == k } }
            List(selection: $selection) {
                ForEach(kinds, id: \.self) { kind in
                    Section(isExpanded: Binding(
                        get: { expanded.contains(kind) || !ws.sidebarFilter.isEmpty },
                        set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } })) {
                        ForEach(objs.filter { $0.kind == kind }) { o in
                            HStack(spacing: 6) {
                                Image(systemName: kind.symbol).foregroundStyle(iconColor(kind)).frame(width: 16)
                                Text(o.displayName).lineLimit(1).truncationMode(.middle)
                                if kind == .trigger && !o.detail.isEmpty {
                                    Text(o.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .tag(o.id)
                        }
                    } header: {
                        HStack {
                            Text(ws.family == .redis && kind == .table ? "Keys" : kind.label)
                            Spacer()
                            Text("\(objs.filter { $0.kind == kind }.count)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if ws.loadingObjects { ProgressView().controlSize(.small) }
                else if ws.objects.isEmpty { Text(ws.currentDatabase.isEmpty && ws.family == .mysql ? "Select a database (⌘K)" : "No items").foregroundStyle(.secondary) }
            }
            .onChange(of: selection) { _, id in
                guard let id, let o = ws.objects.first(where: { $0.id == id }) else { return }
                if o.kind.isBrowsable { ws.openTable(o, preview: true) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let o = ws.objects.first(where: { $0.id == id }) {
                    objectMenu(o)
                }
            } primaryAction: { ids in
                guard let id = ids.first, let o = ws.objects.first(where: { $0.id == id }) else { return }
                if o.kind.isBrowsable { ws.openTable(o, preview: false) } else { ws.openDefinition(o) }
            }
            Divider()
            HStack(spacing: 10) {
                if ws.family != .redis {
                    Button { ws.showCreateTable = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Create table")
                }
                Button { Task { await ws.reloadObjects() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Spacer()
                Text("\(ws.objects.count) items").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func iconColor(_ k: ObjectKind) -> Color {
        switch k {
        case .table: return .accentColor
        case .view, .materializedView: return .teal
        case .function, .procedure: return .purple
        case .trigger: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder
    private func objectMenu(_ o: DBObject) -> some View {
        if o.kind.isBrowsable {
            Button("Open") { ws.openTable(o) }
            Button("Open Structure") { ws.openTable(o, mode: .structure) }
        }
        if ws.family != .redis {
            Button("Show Definition (DDL)") { ws.openDefinition(o) }
            if o.kind.isBrowsable { Button("Show in ER Diagram") { ws.openERD(select: o) } }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(o.name, forType: .string)
        }
        if o.kind.isBrowsable && ws.family != .redis {
            Button("New Query: SELECT …") {
                ws.newQueryTab(sql: "SELECT * FROM \(ws.dialect.qualified(o)) LIMIT 100;", title: o.name, run: true)
            }
        }
        if o.kind == .materializedView {
            Button("Refresh Materialized View") { Task { await ws.refreshMaterializedView(o) } }
        }
        if o.kind == .table {
            Divider()
            Button("Export…") {
                ws.openTable(o)
                if let t = ws.selectedTableTab { ExportController.exportTable(t) }
            }
            if ws.family != .redis {
                Button("Import CSV…") {
                    ws.openTable(o)
                    if let t = ws.selectedTableTab { ImportController.importCSV(into: t) }
                }
            }
        }
        if ws.family != .redis && ws.config.safeMode != .readOnly {
            Divider()
            if o.kind == .table || o.kind == .view || o.kind == .materializedView {
                Button("Rename…") { Task { await ws.rename(o) } }
            }
            if o.kind == .table {
                Button("Truncate…", role: .destructive) { Task { await ws.truncate(o) } }
            }
            Button("Drop…", role: .destructive) { Task { await ws.drop(o) } }
        }
        if ws.family == .redis && ws.config.safeMode != .readOnly {
            Divider()
            Button("Delete Key…", role: .destructive) {
                if ws.confirm("Delete key “\(o.name)”?", "", button: "Delete") {
                    Task { await ws.runAdminStatement("DEL \"\(o.name.replacingOccurrences(of: "\"", with: "\\\""))\"", success: "Deleted \(o.name)") }
                }
            }
        }
    }

    // MARK: Saved queries

    private var queriesView: some View {
        let queries = savedStore.queries(for: ws.config.id)
        return List {
            if queries.isEmpty {
                Text("Save a query with ⌥⌘S to see it here.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(queries) { q in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: q.connectionID == nil ? "star.circle" : "star").foregroundStyle(.yellow)
                        Text(q.name).lineLimit(1)
                    }
                    Text(q.sql.replacingOccurrences(of: "\n", with: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openSaved(q, run: false) }
                .contextMenu {
                    Button("Open") { openSaved(q, run: false) }
                    Button("Open & Run") { openSaved(q, run: true) }
                    Button("Rename…") { renameSaved(q) }
                    Divider()
                    Button("Delete", role: .destructive) { savedStore.delete(q.id) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func openSaved(_ q: SavedQuery, run: Bool) {
        if let tab = ws.tabs.first(where: { if case .query(let s) = $0.content { return s.savedQueryID == q.id } else { return false } }) {
            ws.select(tab)
            return
        }
        ws.newQueryTab(sql: q.sql, title: q.name, run: run, saved: q)
    }

    private func renameSaved(_ q: SavedQuery) {
        let a = NSAlert()
        a.messageText = "Rename saved query"
        let f = NSTextField(string: q.name)
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
            var n = q
            n.name = f.stringValue
            savedStore.upsert(n)
        }
    }

    // MARK: History

    private var historyView: some View {
        let items = historyStore.items.filter { $0.connectionID == ws.config.id && (historySearch.isEmpty || $0.sql.localizedCaseInsensitiveContains(historySearch)) }.prefix(500)
        return VStack(spacing: 0) {
            TextField("Search history", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10).padding(.bottom, 6)
            List {
                ForEach(Array(items)) { h in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.sql.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .foregroundStyle(h.success ? .primary : Color.red)
                        HStack {
                            Text(h.date.formatted(date: .abbreviated, time: .shortened))
                            if !h.database.isEmpty { Text("· \(h.database)") }
                            Spacer()
                            Text(String(format: "%.0f ms", h.duration * 1000))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { insertHistory(h) }
                    .contextMenu {
                        Button("Insert into Current Query") { insertHistory(h) }
                        Button("Open in New Tab") { ws.newQueryTab(sql: h.sql) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(h.sql, forType: .string)
                        }
                        Divider()
                        Button("Remove", role: .destructive) { historyStore.remove(h.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Spacer()
                Button("Clear History") {
                    if ws.confirm("Clear query history for this connection?", "", button: "Clear") { historyStore.clear(connectionID: ws.config.id) }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(6)
        }
    }

    private func insertHistory(_ h: HistoryItem) {
        if let q = ws.selectedQueryTab {
            q.request(.insert(h.sql.hasSuffix(";") ? h.sql + "\n" : h.sql + ";\n"))
        } else {
            ws.newQueryTab(sql: h.sql)
        }
    }
}
