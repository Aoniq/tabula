import SwiftUI
import AppKit

struct RightPanel: View {
    @Bindable var ws: WorkspaceState
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.showAssistant) {
                Text("Row").tag(false)
                Text("AI Assistant").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(8)
            Divider()
            if ws.showAssistant {
                AssistantView(ws: ws)
            } else {
                RowInspectorView(ws: ws)
            }
        }
    }
}

struct RowInspectorView: View {
    let ws: WorkspaceState

    var body: some View {
        Group {
            if let t = ws.selectedTableTab, t.mode == .data {
                if let row = t.selection.first, row < t.displayRowCount {
                    fields(columns: t.resultColumns, row: row, editable: t.canEditData && t.rowState(row) != .deleted,
                           placeholder: { t.isDefaultPlaceholder(row: row, column: $0) ? "DEFAULT" : nil },
                           value: { t.isDefaultPlaceholder(row: row, column: $0) ? nil : t.value(row: row, column: $0) },
                           columnInfo: { name in t.columns.first { $0.name == name } },
                           set: { t.setValue($1, row: row, column: $0) })
                        .id("\(row)-\(t.gridVersion)")
                } else {
                    placeholder("Select a row")
                }
            } else if let q = ws.selectedQueryTab, let r = q.selectedResult, r.isResultSet {
                if let row = q.resultSelection.first {
                    let m = q.model(for: r)
                    let values = m.row(row)
                    fields(columns: r.columns, row: row, editable: false, value: { $0 < values.count ? values[$0] : nil }, columnInfo: { _ in nil }, set: { _, _ in })
                        .id("q\(row)-\(r.id)")
                } else {
                    placeholder("Select a result row")
                }
            } else {
                placeholder("Row details appear here")
            }
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fields(columns: [ResultColumn], row: Int, editable: Bool, placeholder: @escaping (Int) -> String? = { _ in nil }, value: @escaping (Int) -> String?, columnInfo: @escaping (String) -> ColumnInfo?, set: @escaping (Int, EditValue) -> Void) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { i, c in
                    InspectorField(name: c.name, type: columnInfo(c.name)?.type ?? c.typeName,
                                   isKey: columnInfo(c.name)?.isPrimaryKey ?? false,
                                   value: value(i), placeholder: placeholder(i), editable: editable, onCommit: { set(i, $0) })
                }
            }
            .padding(12)
        }
    }
}

struct InspectorField: View {
    let name: String
    let type: String
    let isKey: Bool
    let value: String?
    var placeholder: String? = nil
    let editable: Bool
    let onCommit: (EditValue) -> Void

    @State private var text = ""
    @State private var dirty = false
    @FocusState private var focused: Bool

    private var looksLikeJSON: Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces) else { return false }
        return (v.hasPrefix("{") && v.hasSuffix("}")) || (v.hasPrefix("[") && v.hasSuffix("]"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if isKey { Image(systemName: "key.fill").font(.caption2).foregroundStyle(.yellow) }
                Text(name).font(.caption.weight(.semibold))
                Text(type).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value ?? "", forType: .string)
                    }
                    if looksLikeJSON { Button("Pretty-print JSON") { text = prettyJSON(text); dirty = editable } }
                    if editable {
                        Divider()
                        Button("Set NULL") { onCommit(.null) }
                        Button("Set Empty") { onCommit(.text("")) }
                        Button("Set DEFAULT") { onCommit(.defaultValue) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }
            if editable {
                TextField(placeholder ?? (value == nil ? Settings.nullText : ""), text: $text, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...12)
                    .focused($focused)
                    .onChange(of: text) { dirty = true }
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(value ?? Settings.nullText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .onAppear { text = value ?? ""; dirty = false }
    }

    private func commit() {
        guard dirty else { return }
        dirty = false
        if value == nil && text.isEmpty { return }
        if text != value { onCommit(.text(text)) }
    }

    private func prettyJSON(_ s: String) -> String {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return s }
        return String(data: out, encoding: .utf8) ?? s
    }
}

// MARK: - Open anything (⌘P)

struct OpenAnythingView: View {
    let ws: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        for o in ws.objects {
            out.append(Entry(id: o.id, title: o.displayName, subtitle: o.kind.label.lowercased(), icon: o.kind.symbol) { [ws] in
                if o.kind.isBrowsable { ws.openTable(o) } else { ws.openDefinition(o) }
            })
        }
        for q in SavedQueryStore.shared.queries(for: ws.config.id) {
            out.append(Entry(id: "saved:\(q.id)", title: q.name, subtitle: "saved query", icon: "star") { [ws] in
                ws.newQueryTab(sql: q.sql, title: q.name, saved: q)
            })
        }
        for db in ws.databases where db != ws.currentDatabase {
            out.append(Entry(id: "db:\(db)", title: db, subtitle: "switch database", icon: "cylinder") { [ws] in
                Task { await ws.switchDatabase(db) }
            })
        }
        out.append(Entry(id: "cmd:query", title: "New Query", subtitle: "command", icon: "terminal") { [ws] in ws.newQueryTab() })
        if ws.dialect.processListSQL != nil {
            out.append(Entry(id: "cmd:proc", title: "Process List", subtitle: "command", icon: "cpu") { [ws] in ws.openProcessList() })
        }
        out.append(Entry(id: "cmd:metrics", title: "Metrics Dashboard", subtitle: "command", icon: "chart.bar.xaxis") { [ws] in ws.openDashboard() })
        if ws.family != .redis {
            out.append(Entry(id: "cmd:erd", title: "ER Diagram", subtitle: "command", icon: "point.3.filled.connected.trianglepath.dotted") { [ws] in ws.openERD() })
        }
        return out
    }

    /// Fuzzy subsequence score; nil when no match.
    private func score(_ text: String, _ q: String) -> Int? {
        if q.isEmpty { return 0 }
        let t = text.lowercased(), q = q.lowercased()
        if t == q { return -1000 }
        if t.hasPrefix(q) { return -500 + t.count }
        if t.contains(q) { return -200 + t.count }
        var ti = t.startIndex
        var gaps = 0
        for ch in q {
            guard let found = t[ti...].firstIndex(of: ch) else { return nil }
            gaps += t.distance(from: ti, to: found)
            ti = t.index(after: found)
        }
        return gaps + t.count
    }

    private var matches: [Entry] {
        entries.compactMap { e in score(e.title, query).map { (e, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(80).map(\.0)
    }

    var body: some View {
        let m = matches
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open table, view, function, saved query…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .onSubmit { run(m) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(0, m.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onChange(of: query) { index = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(m.enumerated()), id: \.element.id) { i, e in
                        HStack {
                            Image(systemName: e.icon).foregroundStyle(.secondary).frame(width: 18)
                            Text(e.title).lineLimit(1)
                            Spacer()
                            Text(e.subtitle).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(i == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; run(m) }
                        .id(i)
                    }
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 560, height: 420)
        .onExitCommand { dismiss() }
    }

    private func run(_ m: [Entry]) {
        guard index < m.count else { return }
        let e = m[index]
        dismiss()
        DispatchQueue.main.async { e.action() }
    }
}

// MARK: - Process list

struct ProcessListView: View {
    @Bindable var state: ProcessListState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await state.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Toggle("Auto-refresh (3s)", isOn: Binding(get: { state.autoRefresh }, set: { state.setAutoRefresh($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Text("\(state.result.rows.count) processes").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { Task { await state.killSelected() } } label: { Label("Terminate", systemImage: "xmark.octagon") }
                    .disabled(state.selection.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            if let e = state.error {
                Text(e).foregroundStyle(.red).textSelection(.enabled).padding()
                Spacer()
            } else if let m = state.model {
                DataGridView(source: m, version: m.version).id(ObjectIdentifier(m))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { state.stopAutoRefresh() }
    }
}
