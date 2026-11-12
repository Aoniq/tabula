import SwiftUI
import AppKit

@MainActor
final class QueryCompletionProvider: CompletionSource {
    weak var workspace: WorkspaceState?
    init(workspace: WorkspaceState?) { self.workspace = workspace }

    private static let aliasStop: Set<String> = ["WHERE", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "GROUP", "ORDER", "LIMIT", "SET", "VALUES", "USING", "HAVING", "UNION", "NATURAL", "AS", "SELECT", "WINDOW", "OFFSET", "RETURNING"]
    private static let refRegex = try! NSRegularExpression(pattern: #"(?i)\b(?:from|join|update|into|table)\s+((?:[`"]?[\w$]+[`"]?\.)?[`"]?[\w$]+[`"]?)(?:\s+(?:as\s+)?([\w$]+))?"#)

    func referencedTables(_ text: String) -> [(name: String, alias: String?)] {
        let ns = text as NSString
        return Self.refRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let name = ns.substring(with: m.range(at: 1))
            var alias: String?
            if m.range(at: 2).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 2))
                if !Self.aliasStop.contains(a.uppercased()) { alias = a }
            }
            return (name, alias)
        }
    }

    private func needsQuote(_ s: String, family: DatabaseFamily) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_" + (family == .postgres ? "" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        return s.unicodeScalars.contains { !allowed.contains($0) } || (s.first?.isNumber ?? false)
    }

    func completions(prefix: String, qualifier: String?, fullText: String) -> [CompletionItem] {
        guard let ws = workspace else { return [] }
        let p = prefix.lowercased()
        let fam = ws.family
        var scored: [(Int, Int, CompletionItem)] = []
        func add(_ item: CompletionItem, kindRank: Int) {
            let l = item.text.lowercased()
            if p.isEmpty { scored.append((1, kindRank, item)); return }
            if l == p { scored.append((0, kindRank, item)) }
            else if l.hasPrefix(p) { scored.append((1, kindRank, item)) }
            else if p.count >= 2 && l.contains(p) { scored.append((3, kindRank, item)) }
        }
        func ident(_ s: String) -> String? { needsQuote(s, family: fam) ? ws.dialect.quoteIdent(s) : nil }

        let refs = referencedTables(fullText)
        if let q = qualifier {
            let ql = q.lowercased()
            let tableName = refs.first { $0.alias?.lowercased() == ql }?.name ?? q
            if let o = ws.findObject(named: tableName) {
                if let cols = ws.cachedColumns(o) {
                    for c in cols { add(CompletionItem(text: c.name, kind: .column, detail: c.type, insertText: ident(c.name)), kindRank: 0) }
                } else {
                    ws.prefetchColumns(o)
                }
            } else if ws.schemas.contains(where: { $0.lowercased() == ql }) {
                for o in ws.objects where o.kind.isBrowsable {
                    add(CompletionItem(text: o.name, kind: o.kind == .table ? .table : .view, detail: o.kind.rawValue, insertText: ident(o.name)), kindRank: 0)
                }
            }
        } else {
            var seenCols = Set<String>()
            for r in refs {
                guard let o = ws.findObject(named: r.name) else { continue }
                if let cols = ws.cachedColumns(o) {
                    for c in cols where !seenCols.contains(c.name) {
                        seenCols.insert(c.name)
                        add(CompletionItem(text: c.name, kind: .column, detail: "\(o.name) · \(c.type)", insertText: ident(c.name)), kindRank: 0)
                    }
                } else {
                    ws.prefetchColumns(o)
                }
            }
            for o in ws.objects {
                switch o.kind {
                case .table, .view, .materializedView, .foreignTable:
                    add(CompletionItem(text: o.name, kind: o.kind == .table ? .table : .view, detail: o.kind == .table ? "table" : "view", insertText: ident(o.name)), kindRank: 1)
                case .function, .procedure:
                    add(CompletionItem(text: o.name, kind: .function, detail: o.detail), kindRank: 2)
                default: break
                }
            }
            for s in ws.schemas where s != ws.currentSchema { add(CompletionItem(text: s, kind: .schema, detail: "schema"), kindRank: 3) }
            for k in SQLKeywords.keywords { add(CompletionItem(text: k, kind: .keyword), kindRank: 4) }
            for f in SQLKeywords.functions { add(CompletionItem(text: f, kind: .function, detail: "function"), kindRank: 5) }
        }
        var seen = Set<String>()
        return scored
            .sorted { ($0.0, $0.1, $0.2.text.count, $0.2.text) < ($1.0, $1.1, $1.2.text.count, $1.2.text) }
            .map(\.2)
            .filter { seen.insert($0.text.lowercased() + "\($0.kind)").inserted }
            .prefix(60).map { $0 }
    }
}

struct QueryTabView: View {
    let ws: WorkspaceState
    @Bindable var query: QueryTabState
    @State private var provider: QueryCompletionProvider?
    @AppStorage(SettingsKey.editorFontSize) private var fontSize = 13.0

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                editorToolbar
                Divider()
                SQLEditorView(text: $query.text,
                              request: query.editorRequest,
                              requestID: query.editorRequestID,
                              fontSize: CGFloat(fontSize),
                              completionSource: provider,
                              onSelectionChange: { query.selectedRange = $0 },
                              redisMode: ws.family == .redis)
            }
            .frame(minHeight: 100, idealHeight: 260)
            ResultsPane(ws: ws, query: query)
                .frame(minHeight: 120, idealHeight: 380)
        }
        .onAppear { if provider == nil { provider = QueryCompletionProvider(workspace: ws) } }
    }

    private var editorToolbar: some View {
        HStack(spacing: 6) {
            if query.running {
                Button { query.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
            } else {
                Button { Task { await query.runCurrent() } } label: { Label("Run", systemImage: "play.fill") }
                    .help("Run current statement or selection (⌘↩)")
                    .buttonStyle(.borderedProminent)
            }
            Button { Task { await query.runAll() } } label: { Label("Run All", systemImage: "forward.fill") }
                .help("Run all statements (⇧⌘↩)").disabled(query.running)
            if ws.family != .redis {
                Button { Task { await query.explainCurrent() } } label: { Label("Explain", systemImage: "list.bullet.indent") }
                    .help("Explain current statement (⌥⌘E)").disabled(query.running)
                Divider().frame(height: 16)
                Button { query.format() } label: { Label("Format", systemImage: "text.alignleft") }
                    .help("Beautify SQL (⌘I)")
            }
            Button { query.saveAsFavorite() } label: { Label("Save", systemImage: query.savedQueryID == nil ? "star" : "star.fill") }
                .help("Save query (⌥⌘S)")
            Spacer()
            if ws.family == .redis {
                Text("One Redis command per line").font(.caption).foregroundStyle(.secondary)
            }
            Text(ws.currentDatabase).font(.caption).foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 32)
    }
}

struct ResultsPane: View {
    let ws: WorkspaceState
    @Bindable var query: QueryTabState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Picker("", selection: $query.showLog) {
                    Text("Results").tag(false)
                    Text("Messages\(query.log.isEmpty ? "" : " (\(query.log.count))")").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if !query.showLog && query.results.count > 1 {
                    Picker("", selection: Binding(get: { query.selectedResultID ?? query.results.first?.id }, set: { query.selectedResultID = $0 })) {
                        ForEach(Array(query.results.enumerated()), id: \.element.id) { i, r in
                            Text("\(i + 1): \(r.summary)").tag(Optional(r.id))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Spacer()
                if let r = query.selectedResult, !query.showLog {
                    Text("\(r.summary) · \(String(format: "%.0f ms", r.duration * 1000))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if r.isResultSet {
                        Button { ExportController.exportResult(query) } label: { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless).help("Export result…")
                    }
                }
                if query.showLog && !query.log.isEmpty {
                    Button("Clear") { query.log.removeAll() }.buttonStyle(.borderless)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 30)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if query.showLog {
            List(query.log.reversed()) { e in
                HStack(alignment: .top) {
                    Image(systemName: e.isError ? "xmark.octagon.fill" : "checkmark.circle.fill").foregroundStyle(e.isError ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.statement).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        Text(e.summary).font(.caption).foregroundStyle(e.isError ? .red : .secondary).textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(e.date.formatted(date: .omitted, time: .standard))
                        Text(String(format: "%.1f ms", e.duration * 1000))
                    }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else if query.running {
            VStack(spacing: 10) {
                ProgressView()
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(String(format: "Running… %.1fs", Date().timeIntervalSince(query.runStarted ?? .now))).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Stop") { query.stop() }
            }
        } else if let err = query.error, query.results.isEmpty {
            ScrollView {
                Text(err).font(.system(.callout, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } else if let r = query.selectedResult {
            if r.isResultSet {
                let m = query.model(for: r)
                DataGridView(source: m, version: m.version)
                    .id(r.id)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                    Text("Query OK").font(.headline)
                    Text(r.summary).foregroundStyle(.secondary)
                    if let err = query.error { Text(err).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
        } else {
            Text("Run a query with ⌘↩").foregroundStyle(.tertiary)
        }
    }
}
