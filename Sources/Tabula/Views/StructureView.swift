import SwiftUI
import AppKit

/// TablePlus-style structure editor: columns, indexes and foreign keys of a table.
/// Edits go into `tab.structure` (a `StructureDraft`); committing happens through the table tab's bottom bar.
struct StructureView: View {
    @Bindable var tab: TableTabState

    var body: some View {
        if let draft = tab.structure {
            StructureEditor(tab: tab, draft: draft)
        } else if tab.error != nil {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Couldn't load the structure of “\(tab.object.name)”.").foregroundStyle(.secondary)
                Button("Retry") {
                    tab.error = nil
                    Task { await tab.loadStructure() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading structure…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Editor

private let referentialActions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]

private struct DDLText: Identifiable {
    let id = UUID()
    let title: String
    let sql: String
}

private struct StructureEditor: View {
    @Bindable var tab: TableTabState
    let draft: StructureDraft

    @State private var ddl: DDLText?
    @State private var loadingDDL = false
    @State private var showSQL = false
    @State private var gridWidth: CGFloat = 1000
    @FocusState private var focus: UUID?

    private var ws: WorkspaceState? { tab.workspace }
    private var family: DatabaseFamily { tab.dialect.family }
    private var editable: Bool { tab.canEditStructure }
    private var isView: Bool { tab.object.kind == .view || tab.object.kind == .materializedView }

    private var readOnlyReason: String? {
        guard !editable else { return nil }
        if ws?.family == .redis { return "Redis keys have no editable structure" }
        if ws?.config.safeMode == .readOnly { return "Read-only connection (safe mode)" }
        if isView { return "Views are read-only" }
        return "Read-only"
    }

    private var pending: Result<[String], Error> {
        Result { try draft.statements(table: tab.object, dialect: tab.dialect) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 18) {
                        columnsSection
                        if tab.object.kind == .table || !draft.indexes.isEmpty { indexesSection }
                        if tab.object.kind == .table && family != .redis { foreignKeysSection }
                        if draft.hasChanges { sqlPreview }
                    }
                    .padding(12)
                    .frame(width: max(geo.size.width, minContentWidth), alignment: .topLeading)
                }
                .onChange(of: geo.size.width, initial: true) { _, w in gridWidth = max(w, minContentWidth) - 24 }
            }
        }
        .sheet(item: $ddl) { DDLSheet(item: $0, ws: ws) }
    }

    private var minContentWidth: CGFloat { family == .sqlite ? 860 : 1000 }

    /// Turns flexible specs into fixed widths so every row of a grid lines up
    /// (HStack would otherwise size flexible cells per row from their content).
    private func resolve(_ specs: [CellSpec]) -> [CellSpec] {
        resolveCellSpecs(specs, total: gridWidth - 2)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.object.kind.symbol).foregroundStyle(.secondary)
            Text(tab.object.name).fontWeight(.semibold)
            if let reason = readOnlyReason {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .help(reason)
            }
            Spacer()
            pendingHint
            if isView {
                Button { if let ws { ws.openDefinition(tab.object) } } label: { Label("Show Definition", systemImage: "doc.text") }
            }
            Button { showDDL() } label: { Label("Show DDL", systemImage: "chevron.left.forwardslash.chevron.right") }
                .disabled(loadingDDL)
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload structure")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    @ViewBuilder private var pendingHint: some View {
        let n = draft.changeCount
        if n > 0 {
            switch pending {
            case .failure(let e):
                Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                    .help(e.localizedDescription)
            case .success:
                Text("\(n) pending change\(n == 1 ? "" : "s") · commit below")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sqlPreview: some View {
        DisclosureGroup(isExpanded: $showSQL) {
            Group {
                switch pending {
                case .success(let stmts): Text(stmts.joined(separator: "\n"))
                case .failure(let e): Text(e.localizedDescription).foregroundStyle(.orange)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            Text("Pending SQL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    // MARK: Columns

    private var columnSpecs: [CellSpec] {
        var s: [CellSpec] = [
            CellSpec("#", 34, center: true),
            CellSpec("Name", nil, min: 150),
            CellSpec("Type", nil, min: 170),
            CellSpec("Nullable", 60, center: true),
            CellSpec("Default", nil, min: 140),
            CellSpec("Key", 36, center: true),
        ]
        if family != .sqlite { s.append(CellSpec("Comment", nil, min: 140)) }
        s.append(CellSpec("Extra", 120))
        if editable { s.append(CellSpec("", 30, center: true)) }
        return resolve(s)
    }

    private var columnsSection: some View {
        SectionBox(title: "Columns", count: draft.columns.filter { !$0.isNew }.count,
                   addTitle: editable ? "Column" : nil, addHelp: "Add column", onAdd: addColumn) {
            HeaderRow(specs: columnSpecs)
            ForEach(Array(draft.columns.enumerated()), id: \.element.id) { i, c in
                columnRow(i, c)
                Divider().opacity(0.5)
            }
        }
    }

    private func columnRow(_ i: Int, _ c: ColumnDraft) -> some View {
        let specs = columnSpecs
        let live = editable && !c.dropped
        // SQLite can only rename existing columns.
        let defEditable = live && (c.isNew || family != .sqlite)
        let sqliteHelp = family == .sqlite && !c.isNew ? "SQLite can't alter an existing column's type, nullability or default" : ""
        var k = 0
        func next() -> CellSpec { defer { k += 1 }; return specs[k] }
        return HStack(spacing: 0) {
            Text("\(i + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit().cell(next())
            CellField(text: bind(\.columns, c.id, \.name, ""), editable: live, placeholder: "column_name", struck: c.dropped)
                .focused($focus, equals: c.id)
                .cell(next())
            HStack(spacing: 2) {
                CellField(text: bind(\.columns, c.id, \.type, ""), editable: defEditable, placeholder: "type", mono: true, struck: c.dropped)
                if defEditable {
                    Menu {
                        ForEach(tab.dialect.commonTypes, id: \.self) { t in
                            Button(t) { set(\.columns, c.id) { $0.type = t } }
                        }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .help(sqliteHelp)
            .cell(next())
            Toggle("", isOn: bind(\.columns, c.id, \.nullable, true))
                .toggleStyle(.checkbox).labelsHidden().disabled(!defEditable)
                .cell(next())
            CellField(text: bind(\.columns, c.id, \.defaultValue, ""), editable: defEditable, placeholder: defEditable ? "NULL" : "",
                      mono: true, struck: c.dropped)
                .help(sqliteHelp)
                .cell(next())
            Group {
                if c.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).help("Primary key") }
                else if isForeignKeyColumn(c.original?.name ?? c.name) { Image(systemName: "link").foregroundStyle(.secondary).help("Foreign key") }
                else { Color.clear.frame(width: 1, height: 1) }   // an empty Group would drop the cell entirely
            }
            .cell(next())
            if family != .sqlite {
                CellField(text: bind(\.columns, c.id, \.comment, ""), editable: live, placeholder: "", struck: c.dropped)
                    .cell(next())
            }
            Text(c.original?.extra ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(c.original?.extra ?? "").cell(next())
            if editable {
                DeleteButton(isNew: c.isNew, dropped: c.dropped, noun: "column") { toggleDrop(\.columns, c.id, isNew: c.isNew) }
                    .cell(next())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(rowTint(new: c.isNew, modified: c.isModified, dropped: c.dropped, odd: i % 2 == 1))
        .contextMenu {
            Button("Copy Name") { copy(c.name) }
            Button("Copy Type") { copy(c.type) }
        }
    }

    private func isForeignKeyColumn(_ name: String) -> Bool {
        draft.foreignKeys.contains { !$0.isNew && StructureDraft.names($0.columns).contains(name) }
    }

    private func addColumn() {
        let c = ColumnDraft(name: "", type: CreateTableSQL.defaultType(family))
        draft.columns.append(c)
        DispatchQueue.main.async { focus = c.id }
    }

    // MARK: Indexes

    private var indexSpecs: [CellSpec] {
        var s = [CellSpec("Name", nil, min: 180), CellSpec("Columns", nil, min: 180), CellSpec("Unique", 56, center: true), CellSpec("Definition", nil, min: 300)]
        if editable { s.append(CellSpec("", 30, center: true)) }
        return resolve(s)
    }

    private var indexesSection: some View {
        SectionBox(title: "Indexes", count: draft.indexes.filter { !$0.isNew }.count,
                   addTitle: editable ? "Index" : nil, addHelp: "Add index", onAdd: {
                       let i = IndexDraft(original: nil, name: "", columns: "", unique: false)
                       draft.indexes.append(i)
                       DispatchQueue.main.async { focus = i.id }
                   }) {
            HeaderRow(specs: indexSpecs)
            if draft.indexes.isEmpty { EmptyRow(text: "No indexes") }
            ForEach(Array(draft.indexes.enumerated()), id: \.element.id) { i, idx in
                indexRow(i, idx)
                Divider().opacity(0.5)
            }
        }
    }

    private func indexRow(_ i: Int, _ idx: IndexDraft) -> some View {
        let s = indexSpecs
        let live = editable && idx.isNew && !idx.dropped
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                CellField(text: bind(\.indexes, idx.id, \.name, ""), editable: live, placeholder: "auto-generated", struck: idx.dropped)
                    .focused($focus, equals: idx.id)
                if idx.original?.primary == true { Badge("PRIMARY") }
            }
            .cell(s[0])
            ColumnListField(text: bind(\.indexes, idx.id, \.columns, ""), editable: live, struck: idx.dropped, options: columnNames)
                .cell(s[1])
            Toggle("", isOn: bind(\.indexes, idx.id, \.unique, false))
                .toggleStyle(.checkbox).labelsHidden().disabled(!live)
                .cell(s[2])
            Text(idx.original?.definition ?? "New index")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).strikethrough(idx.dropped)
                .textSelection(.enabled).help(idx.original?.definition ?? "")
                .cell(s[3])
            if editable {
                DeleteButton(isNew: idx.isNew, dropped: idx.dropped, noun: "index") { toggleDrop(\.indexes, idx.id, isNew: idx.isNew) }
                    .cell(s[4])
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(rowTint(new: idx.isNew, modified: false, dropped: idx.dropped, odd: i % 2 == 1))
        .contextMenu {
            Button("Copy Name") { copy(idx.name) }
            if let d = idx.original?.definition { Button("Copy Definition") { copy(d) } }
        }
    }

    private var columnNames: [String] { draft.columns.filter { !$0.dropped && !$0.name.isEmpty }.map(\.name) }

    // MARK: Foreign keys

    private var canEditFKs: Bool { editable && family != .sqlite }

    private var fkSpecs: [CellSpec] {
        var s = [CellSpec("Name", nil, min: 150), CellSpec("Columns", nil, min: 130), CellSpec("Referenced Table", nil, min: 150),
                 CellSpec("Referenced Columns", nil, min: 130), CellSpec("On Delete", 112), CellSpec("On Update", 112)]
        if canEditFKs { s.append(CellSpec("", 30, center: true)) }
        return resolve(s)
    }

    private var foreignKeysSection: some View {
        SectionBox(title: "Foreign Keys", count: draft.foreignKeys.filter { !$0.isNew }.count,
                   addTitle: canEditFKs ? "Foreign Key" : nil, addHelp: "Add foreign key", onAdd: {
                       let f = ForeignKeyDraft(original: nil, name: "", columns: "", refTable: "", refColumns: "", onDelete: "NO ACTION", onUpdate: "NO ACTION")
                       draft.foreignKeys.append(f)
                       DispatchQueue.main.async { focus = f.id }
                   }) {
            HeaderRow(specs: fkSpecs)
            if draft.foreignKeys.isEmpty { EmptyRow(text: family == .sqlite && editable ? "No foreign keys (SQLite can't add foreign keys to an existing table)" : "No foreign keys") }
            ForEach(Array(draft.foreignKeys.enumerated()), id: \.element.id) { i, f in
                fkRow(i, f)
                Divider().opacity(0.5)
            }
        }
    }

    private func fkRow(_ i: Int, _ f: ForeignKeyDraft) -> some View {
        let s = fkSpecs
        let live = canEditFKs && f.isNew && !f.dropped
        return HStack(spacing: 0) {
            CellField(text: bind(\.foreignKeys, f.id, \.name, ""), editable: live, placeholder: "auto-generated", struck: f.dropped)
                .focused($focus, equals: f.id)
                .cell(s[0])
            ColumnListField(text: bind(\.foreignKeys, f.id, \.columns, ""), editable: live, struck: f.dropped, options: columnNames)
                .cell(s[1])
            Group {
                if live {
                    Picker("", selection: Binding(get: { f.refTable }, set: { pickReferencedTable(f.id, $0) })) {
                        Text("Select…").tag("")
                        ForEach(referenceTargets.map(\.value), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                } else {
                    let ref = (f.original?.refSchema).flatMap { $0 == tab.object.schema || family != .postgres ? nil : $0 + "." } ?? ""
                    Text(ref + f.refTable).lineLimit(1).strikethrough(f.dropped)
                        .textSelection(.enabled)
                }
            }
            .cell(s[2])
            ColumnListField(text: bind(\.foreignKeys, f.id, \.refColumns, ""), editable: live, struck: f.dropped,
                            options: referencedColumns(f.refTable))
                .cell(s[3])
            actionCell(f, \.onDelete, live).cell(s[4])
            actionCell(f, \.onUpdate, live).cell(s[5])
            if canEditFKs {
                DeleteButton(isNew: f.isNew, dropped: f.dropped, noun: "foreign key") { toggleDrop(\.foreignKeys, f.id, isNew: f.isNew) }
                    .cell(s[6])
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(rowTint(new: f.isNew, modified: false, dropped: f.dropped, odd: i % 2 == 1))
        .contextMenu {
            Button("Copy Name") { copy(f.name) }
            if let ws, let target = referencedObject(f.refTable)
                ?? ws.objects.first(where: { $0.kind == .table && $0.name == f.refTable && (family != .postgres || $0.schema == f.original?.refSchema) }) {
                Button("Open “\(f.refTable)”") { ws.openTable(target) }
                Button("Open “\(f.refTable)” Structure") { ws.openTable(target, mode: .structure) }
            }
        }
    }

    @ViewBuilder
    private func actionCell(_ f: ForeignKeyDraft, _ kp: WritableKeyPath<ForeignKeyDraft, String>, _ live: Bool) -> some View {
        if live {
            Picker("", selection: bind(\.foreignKeys, f.id, kp, "NO ACTION")) {
                ForEach(referentialActions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
        } else {
            Text(f[keyPath: kp]).font(.caption).lineLimit(1).strikethrough(f.dropped)
                .foregroundStyle(f[keyPath: kp] == "NO ACTION" ? .secondary : .primary)
        }
    }

    /// The value stored in `refTable` for a table: bare name, or `schema.name` when it lives in
    /// another Postgres schema than the edited table.
    private func refValue(_ o: DBObject) -> String {
        if family == .postgres, let s = o.schema, !s.isEmpty, s != tab.object.schema { return "\(s).\(o.name)" }
        return o.name
    }

    private var referenceTargets: [(value: String, object: DBObject)] {
        (ws?.objects ?? []).filter { $0.kind == .table }.map { (refValue($0), $0) }
    }

    private func referencedObject(_ value: String) -> DBObject? {
        guard !value.isEmpty else { return nil }
        return referenceTargets.first { $0.value == value }?.object
    }

    /// Column names of the referenced table, when already loaded (picking the table loads them).
    private func referencedColumns(_ table: String) -> [String] {
        guard let ws, let o = referencedObject(table) else { return [] }
        return ws.cachedColumns(o)?.map(\.name) ?? []
    }

    /// Picking a referenced table pre-fills its primary key as the referenced columns.
    private func pickReferencedTable(_ id: UUID, _ table: String) {
        set(\.foreignKeys, id) { $0.refTable = table }
        guard let ws, let o = referencedObject(table) else { return }
        Task {
            let cols = await ws.columns(for: o)
            let pk = cols.filter(\.isPrimaryKey).map(\.name)
            guard !pk.isEmpty else { return }
            set(\.foreignKeys, id) { f in
                if f.refTable == table && (f.refColumns.isEmpty || !StructureDraft.names(f.refColumns).allSatisfy { n in cols.contains { $0.name == n } }) {
                    f.refColumns = pk.joined(separator: ", ")
                }
            }
        }
    }

    // MARK: Draft helpers

    private func bind<Row: Identifiable, V>(_ list: ReferenceWritableKeyPath<StructureDraft, [Row]>, _ id: UUID,
                                            _ kp: WritableKeyPath<Row, V>, _ fallback: V) -> Binding<V> where Row.ID == UUID {
        let d = draft
        return Binding(get: { d[keyPath: list].first { $0.id == id }?[keyPath: kp] ?? fallback },
                       set: { v in
                           guard let i = d[keyPath: list].firstIndex(where: { $0.id == id }) else { return }
                           d[keyPath: list][i][keyPath: kp] = v
                       })
    }

    private func set<Row: Identifiable>(_ list: ReferenceWritableKeyPath<StructureDraft, [Row]>, _ id: UUID, _ body: (inout Row) -> Void) where Row.ID == UUID {
        guard let i = draft[keyPath: list].firstIndex(where: { $0.id == id }) else { return }
        body(&draft[keyPath: list][i])
    }

    /// Delete on a new row removes it; on an existing row it toggles "dropped".
    private func toggleDrop<Row: Identifiable & DroppableDraft>(_ list: ReferenceWritableKeyPath<StructureDraft, [Row]>, _ id: UUID, isNew: Bool) where Row.ID == UUID {
        if isNew {
            draft[keyPath: list].removeAll { $0.id == id }
        } else {
            set(list, id) { $0.dropped.toggle() }
        }
    }

    private func rowTint(new: Bool, modified: Bool, dropped: Bool, odd: Bool) -> Color {
        if dropped { return Color.red.opacity(0.15) }
        if new { return Color.green.opacity(0.15) }
        if modified { return Color.yellow.opacity(0.2) }
        return odd ? Color(nsColor: .alternatingContentBackgroundColors[1]) : .clear
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Actions

    private func showDDL() {
        guard let ws else { return }
        let o = tab.object
        loadingDDL = true
        Task {
            defer { loadingDDL = false }
            do {
                let sql = try await ws.run { try $0.ddl(of: o) }
                ddl = DDLText(title: o.name, sql: sql)
            } catch {
                ws.showToast(error.localizedDescription, error: true)
            }
        }
    }

    private func refresh() {
        if draft.hasChanges {
            let a = NSAlert()
            a.messageText = "Discard pending structure changes?"
            a.addButton(withTitle: "Discard & Reload")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await tab.loadStructure() }
    }
}

// MARK: - Building blocks

protocol DroppableDraft { var dropped: Bool { get set } }
extension ColumnDraft: DroppableDraft {}
extension IndexDraft: DroppableDraft {}
extension ForeignKeyDraft: DroppableDraft {}

private struct CellSpec {
    let title: String
    let width: CGFloat?
    let minWidth: CGFloat
    let center: Bool
    init(_ title: String, _ width: CGFloat?, min: CGFloat = 60, center: Bool = false) {
        self.title = title; self.width = width; self.minWidth = min; self.center = center
    }
}

private func resolveCellSpecs(_ specs: [CellSpec], total: CGFloat) -> [CellSpec] {
    let fixed = specs.compactMap(\.width).reduce(0, +)
    let flexMin = specs.filter { $0.width == nil }.map(\.minWidth).reduce(0, +)
    guard flexMin > 0 else { return specs }
    let extra = max(0, total - fixed - flexMin)
    return specs.map { s in
        s.width != nil ? s : CellSpec(s.title, (s.minWidth + extra * s.minWidth / flexMin).rounded(.down), min: s.minWidth, center: s.center)
    }
}

private extension View {
    func cell(_ s: CellSpec) -> some View {
        self.padding(.horizontal, 6)
            .frame(minWidth: s.width ?? s.minWidth, maxWidth: s.width ?? .infinity, minHeight: 24, maxHeight: .infinity,
                   alignment: s.center ? .center : .leading)
            .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(width: 1) }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let count: Int
    let addTitle: String?
    let addHelp: String
    let onAdd: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let addTitle {
                    Button(action: onAdd) { Label(addTitle, systemImage: "plus") }
                        .buttonStyle(.borderless).controlSize(.small).help(addHelp)
                }
            }
            VStack(spacing: 0) { content }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct HeaderRow: View {
    let specs: [CellSpec]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                    Text(s.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).cell(s)
                }
            }
            .frame(height: 24)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
        }
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// A grid cell that is a plain text field when editable and selectable text otherwise.
private struct CellField: View {
    @Binding var text: String
    var editable: Bool
    var placeholder = ""
    var mono = false
    var struck = false

    private var font: Font { mono ? .system(.body, design: .monospaced) : .body }

    var body: some View {
        if editable {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(font)
        } else {
            Text(text.isEmpty ? placeholder : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .strikethrough(struck)
                .lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
                .help(text)
        }
    }
}

/// Comma separated column list with a menu that appends known column names.
private struct ColumnListField: View {
    @Binding var text: String
    var editable: Bool
    var struck: Bool
    var options: [String]

    var body: some View {
        HStack(spacing: 2) {
            CellField(text: $text, editable: editable, placeholder: editable ? "col1, col2" : "", mono: true, struck: struck)
            if editable && !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { name in
                        Button(name) {
                            var cols = StructureDraft.names(text)
                            if let i = cols.firstIndex(of: name) { cols.remove(at: i) } else { cols.append(name) }
                            text = cols.joined(separator: ", ")
                        }
                    }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add or remove a column")
            }
        }
    }
}

private struct DeleteButton: View {
    let isNew: Bool
    let dropped: Bool
    let noun: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: dropped ? "arrow.uturn.backward" : "minus.circle")
                .foregroundStyle(dropped ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(dropped ? "Restore \(noun)" : (isNew ? "Remove new \(noun)" : "Drop \(noun)"))
    }
}

private struct DDLSheet: View {
    let item: DDLText
    let ws: WorkspaceState?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DDL — \(item.title)").font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(item.sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.sql, forType: .string)
                }
                Button("Open in SQL Editor") {
                    ws?.newQueryTab(sql: item.sql, title: item.title + " (DDL)")
                    dismiss()
                }
                .disabled(ws == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 680, height: 460)
    }
}
