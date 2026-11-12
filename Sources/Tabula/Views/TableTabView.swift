import SwiftUI
import AppKit

struct TableTabView: View {
    @Bindable var tab: TableTabState

    var body: some View {
        VStack(spacing: 0) {
            if tab.showFilters && tab.mode == .data {
                FilterBarView(tab: tab)
                Divider()
            }
            if let err = tab.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { tab.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                Divider()
            }
            ZStack {
                switch tab.mode {
                case .data:
                    DataGridView(source: tab, version: tab.gridVersion, scrollToRow: tab.scrollToRow, onScrolled: { tab.scrollToRow = nil })
                        .overlay {
                            if tab.loading && !tab.dataLoaded { ProgressView() }
                        }
                case .structure:
                    StructureView(tab: tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            TableBottomBar(tab: tab)
        }
    }
}

struct TableBottomBar: View {
    @Bindable var tab: TableTabState

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { tab.mode }, set: { tab.switchMode($0) })) {
                Text("Data").tag(TableTabState.Mode.data)
                Text("Structure").tag(TableTabState.Mode.structure)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!tab.object.kind.isBrowsable)

            if tab.mode == .data {
                Divider().frame(height: 16)
                Button { tab.addRow() } label: { Image(systemName: "plus") }
                    .help("Add row (⌥⌘N)").disabled(!tab.canEditData)
                Button { tab.deleteRows(tab.selection) } label: { Image(systemName: "minus") }
                    .help("Delete selected rows (⌫)").disabled(!tab.canEditData || tab.selection.isEmpty)
                Button {
                    tab.showFilters.toggle()
                    if tab.showFilters && tab.filters.isEmpty { tab.addFilter() }
                } label: {
                    Image(systemName: tab.appliedFilters.contains(where: \.enabled) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Filter (⌘F)")
                Button { ExportController.exportTable(tab) } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export…")
            }
            Spacer()
            if tab.loading { ProgressView().controlSize(.small) }
            if tab.mode == .data {
                Text(statusText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help(tab.lastQuery)
                    .contextMenu {
                        Button("Copy Query") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tab.lastQuery, forType: .string)
                        }
                        Button("Open Query in Editor") { tab.workspace?.newQueryTab(sql: tab.lastQuery + ";") }
                    }
                Divider().frame(height: 16)
                Button { tab.goToPage(0) } label: { Image(systemName: "chevron.left.to.line") }.disabled(tab.page == 0)
                Button { tab.goToPage(tab.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(tab.page == 0)
                Menu {
                    ForEach([100, 300, 500, 1000, 5000], id: \.self) { n in
                        Button("\(n) rows per page") { tab.pageSize = n; tab.goToPage(0) }
                    }
                } label: {
                    Text("Page \(tab.page + 1)\(tab.pageCount.map { " of \($0)" } ?? "")").font(.caption).monospacedDigit()
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button { tab.goToPage(tab.page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(tab.rows.count < tab.pageSize || (tab.pageCount.map { tab.page + 1 >= $0 } ?? false))
                Button { if let c = tab.pageCount { tab.goToPage(c - 1) } } label: { Image(systemName: "chevron.right.to.line") }
                    .disabled(tab.pageCount.map { tab.page + 1 >= $0 } ?? true)
            }
            if tab.hasChanges {
                Divider().frame(height: 16)
                Button("Discard") { tab.discardChanges() }
                Button("Review") { tab.previewChanges() }
                Button("Commit \(tab.changeCount)") { Task { await tab.commit() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var statusText: String {
        let start = tab.page * tab.pageSize
        let n = tab.rows.count
        var s = n == 0 ? "No rows" : "Rows \(start + 1)–\(start + n)"
        if let total = tab.totalCount { s += " of \(total.formatted())" } else if tab.countingRows { s += " of …" }
        if tab.lastDuration > 0 { s += String(format: " · %.0f ms", tab.lastDuration * 1000) }
        return s
    }
}

struct FilterBarView: View {
    @Bindable var tab: TableTabState

    private var columnNames: [String] { tab.columns.isEmpty ? tab.resultColumns.map(\.name) : tab.columns.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($tab.filters) { $f in
                HStack(spacing: 6) {
                    Toggle("", isOn: $f.enabled).labelsHidden().toggleStyle(.checkbox)
                    Picker("", selection: $f.column) {
                        Text("Any column").tag("")
                        Divider()
                        ForEach(columnNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                    Picker("", selection: $f.op) {
                        ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    if f.op.needsValue {
                        TextField(f.op == .raw ? "SQL condition, e.g. price > 10" : (f.op == .inList ? "a, b, c" : "Value"), text: $f.value)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { tab.applyFilters() }
                        if f.op == .between {
                            Text("and")
                            TextField("Value", text: $f.value2).textFieldStyle(.roundedBorder).onSubmit { tab.applyFilters() }
                        }
                    } else {
                        Spacer()
                    }
                    Button { tab.filters.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    Button { tab.addFilter() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                if tab.filters.isEmpty {
                    Button("Add Filter") { tab.addFilter() }
                }
                Text(tab.dialect.whereClause(tab.filters, columns: columnNames).trimmingCharacters(in: .whitespaces))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer()
                Button("Clear") { tab.clearFilters() }
                Button("Apply") { tab.applyFilters() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
