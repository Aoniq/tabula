import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// State of an ER-diagram tab.
@MainActor
@Observable
final class ERDState {
    enum ZoomRequest: Equatable { case fit, zoomIn, zoomOut, actualSize, center(String) }
    enum ImageTheme: String, CaseIterable, Identifiable { case light = "Light", dark = "Dark", app = "Match App"; var id: String { rawValue } }

    @ObservationIgnored weak var workspace: WorkspaceState?
    var graph: ERDGraph?
    private(set) var positions: [String: CGPoint] = [:]
    private var focusPositions: [String: CGPoint] = [:]
    /// The user dragged tables; don't re-run auto layout on detail changes.
    private var userArranged = false

    var options = ERDOptions() { didSet { if oldValue != options { optionsChanged(oldValue) } } }
    var includeViews = true
    var selected: String?
    var focusMode = false
    var loading = false
    var error: String?
    var search = ""
    /// Bumped whenever the scene must be rebuilt.
    private(set) var version = 0
    private(set) var zoomRequest: ZoomRequest?
    private(set) var zoomRequestID = 0
    var imageTheme: ImageTheme = ImageTheme(rawValue: UserDefaults.standard.string(forKey: "erdImageTheme") ?? "") ?? .light {
        didSet { UserDefaults.standard.set(imageTheme.rawValue, forKey: "erdImageTheme") }
    }
    var includeCaption = UserDefaults.standard.object(forKey: "erdCaption") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeCaption, forKey: "erdCaption") }
    }

    init(workspace: WorkspaceState, select: String? = nil) {
        self.workspace = workspace
        self.selected = select
    }

    // MARK: Derived

    var shownGraph: ERDGraph? {
        guard let g = graph else { return nil }
        if focusMode, let s = selected, g.table(s) != nil { return g.subgraph(g.neighborhood(of: s)) }
        return g
    }

    var shownPositions: [String: CGPoint] { focusMode && selected != nil ? focusPositions : positions }

    func scene() -> ERDScene? {
        guard let g = shownGraph else { return nil }
        return ERDScene.build(graph: g, positions: shownPositions, options: options)
    }

    var relatedToSelection: Set<String> {
        guard let g = graph, let s = selected else { return [] }
        return g.neighborhood(of: s)
    }

    // MARK: Loading

    private var storeKey: String? {
        guard let ws = workspace else { return nil }
        let scope = ws.family == .postgres ? "\(ws.currentDatabase).\(ws.currentSchema ?? "public")" : ws.currentDatabase
        let safe = scope.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "_" }
        return "\(ws.config.id.uuidString)-\(String(safe))"
    }

    private var storeURL: URL? {
        guard let key = storeKey else { return nil }
        let dir = AppPaths.support.appendingPathComponent("erd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key + ".json")
    }

    private struct Stored: Codable {
        var positions: [String: [Double]]
        var detail: ERDDetail
        var showTypes: Bool
        var includeViews: Bool
        var userArranged: Bool
    }

    func load() async {
        guard let ws = workspace else { return }
        loading = true
        error = nil
        do {
            var stored: Stored?
            if let url = storeURL, let data = try? Data(contentsOf: url) { stored = try? JSONDecoder().decode(Stored.self, from: data) }
            if let s = stored, graph == nil {
                includeViews = s.includeViews
                userArranged = s.userArranged
                options = ERDOptions(detail: s.detail, showTypes: s.showTypes)
            }
            let g = try await ERDLoader.load(ws, includeViews: includeViews)
            graph = g
            var pos = ERDAutoLayout.layout(g, options: options)
            if let s = stored, s.userArranged {
                for (id, p) in s.positions where p.count == 2 && pos[id] != nil { pos[id] = CGPoint(x: p[0], y: p[1]) }
            }
            positions = pos
            if let sel = selected, g.table(sel) == nil { selected = nil }
            if focusMode, let sg = shownGraph { focusPositions = ERDAutoLayout.layout(sg, options: options) }
            version += 1
            if let sel = selected { request(.center(sel)) } else { request(.fit) }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        guard let url = storeURL else { return }
        let s = Stored(positions: positions.mapValues { [Double($0.x), Double($0.y)] }, detail: options.detail,
                       showTypes: options.showTypes, includeViews: includeViews, userArranged: userArranged)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private func optionsChanged(_ old: ERDOptions) {
        guard let g = graph else { return }
        if !userArranged { positions = ERDAutoLayout.layout(g, options: options) }
        if focusMode, let sg = shownGraph { focusPositions = ERDAutoLayout.layout(sg, options: options) }
        version += 1
        save()
    }

    // MARK: Interaction

    func request(_ z: ZoomRequest) {
        zoomRequest = z
        zoomRequestID += 1
    }

    func autoArrange() {
        guard let g = graph else { return }
        userArranged = false
        positions = ERDAutoLayout.layout(g, options: options)
        if focusMode, let sg = shownGraph { focusPositions = ERDAutoLayout.layout(sg, options: options) }
        version += 1
        save()
        request(.fit)
    }

    func moved(_ id: String, to p: CGPoint) {
        if focusMode && selected != nil {
            focusPositions[id] = p
        } else {
            positions[id] = p
            userArranged = true
            save()
        }
    }

    func select(_ id: String?) {
        guard id != selected else { return }
        selected = id
        if focusMode {
            if let sg = shownGraph, id != nil { focusPositions = ERDAutoLayout.layout(sg, options: options) }
            version += 1
            request(.fit)
        }
    }

    func setFocus(_ on: Bool) {
        focusMode = on
        if on, let sg = shownGraph { focusPositions = ERDAutoLayout.layout(sg, options: options) }
        version += 1
        request(on ? .fit : (selected.map { .center($0) } ?? .fit))
    }

    func setIncludeViews(_ on: Bool) {
        includeViews = on
        Task { await load(); save() }
    }

    func find() {
        guard let g = graph else { return }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return }
        let match = g.tables.first { $0.name.lowercased() == q }
            ?? g.tables.first { $0.name.lowercased().hasPrefix(q) }
            ?? g.tables.first { $0.name.lowercased().contains(q) }
        guard let m = match else { workspace?.showToast("No table matching “\(search)”"); return }
        if focusMode { setFocus(false) }
        selected = m.id
        request(.center(m.id))
    }

    func open(_ id: String, mode: TableTabState.Mode = .data) {
        guard let ws = workspace, let t = graph?.table(id), !t.isExternal else { return }
        let obj = ws.objects.first { $0.name == t.name && ($0.schema ?? "") == (t.schema ?? $0.schema ?? "") && $0.kind.isBrowsable }
            ?? DBObject(schema: t.schema, name: t.name, kind: t.kind)
        ws.openTable(obj, mode: mode)
    }

    // MARK: Export

    private var exportTheme: ERDTheme {
        switch imageTheme {
        case .light: return .light
        case .dark: return .dark
        case .app: return ERDTheme.forAppearance(NSApp.effectiveAppearance)
        }
    }

    private var caption: String? {
        guard includeCaption, let g = shownGraph else { return nil }
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return "\(g.title) · \(g.tables.count) tables · \(g.relations.count) relationships · \(date)"
    }

    private var baseName: String {
        let title = shownGraph?.title ?? "erd"
        let base = focusMode ? (graph?.table(selected ?? "")?.name ?? title) : title
        return "\(base)-erd".map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    private func save(_ data: Data, ext: String, type: UTType?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        if let type { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            workspace?.showToast("Exported \(url.lastPathComponent)")
        } catch {
            workspace?.showToast(error.localizedDescription, error: true)
        }
    }

    enum ImageFormat { case png, pdf, svg }

    func exportImage(_ f: ImageFormat) {
        guard let scene = scene(), let g = shownGraph else { return }
        switch f {
        case .png:
            guard let d = ERDImageExport.png(scene, theme: exportTheme, caption: caption) else { return }
            save(d, ext: "png", type: .png)
        case .pdf:
            guard let d = ERDImageExport.pdf(scene, theme: exportTheme, caption: caption, title: g.title) else { return }
            save(d, ext: "pdf", type: .pdf)
        case .svg:
            save(Data(ERDImageExport.svg(scene, theme: exportTheme, caption: caption).utf8), ext: "svg", type: .svg)
        }
    }

    func copyImage() {
        guard let scene = scene(), let g = shownGraph else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = ERDImageExport.png(scene, theme: exportTheme, caption: caption) { pb.setData(png, forType: .png) }
        if let pdf = ERDImageExport.pdf(scene, theme: exportTheme, caption: caption, title: g.title) { pb.setData(pdf, forType: .pdf) }
        workspace?.showToast("Diagram copied to the clipboard")
    }

    enum TextFormat: String, CaseIterable, Identifiable {
        case mermaid = "Mermaid", dbml = "DBML", plantUML = "PlantUML", dot = "Graphviz DOT", markdown = "Markdown Data Dictionary"
        var id: String { rawValue }
        var ext: String {
            switch self {
            case .mermaid: return "mmd"
            case .dbml: return "dbml"
            case .plantUML: return "puml"
            case .dot: return "dot"
            case .markdown: return "md"
            }
        }
        var hint: String {
            switch self {
            case .mermaid: return "GitHub, GitLab, Notion, Obsidian, Confluence"
            case .dbml: return "dbdiagram.io, dbdocs"
            case .plantUML: return "PlantUML, Confluence, IntelliJ"
            case .dot: return "Graphviz"
            case .markdown: return "Docs, wikis, READMEs"
            }
        }
    }

    func text(_ f: TextFormat) -> String? {
        guard let g = shownGraph else { return nil }
        switch f {
        case .mermaid: return ERDTextExport.mermaid(g)
        case .dbml: return ERDTextExport.dbml(g)
        case .plantUML: return ERDTextExport.plantUML(g)
        case .dot: return ERDTextExport.dot(g)
        case .markdown: return ERDTextExport.markdownDictionary(g)
        }
    }

    func exportText(_ f: TextFormat) {
        guard let s = text(f) else { return }
        save(Data(s.utf8), ext: f.ext, type: UTType(filenameExtension: f.ext) ?? .plainText)
    }

    func copyText(_ f: TextFormat) {
        guard var s = text(f) else { return }
        if f == .mermaid { s = "```mermaid\n" + s + (s.hasSuffix("\n") ? "" : "\n") + "```\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        workspace?.showToast("\(f.rawValue) copied\(f == .mermaid ? " as a Markdown code block" : "")")
    }

    /// CREATE statements for every (non-external) table/view in the diagram, in dependency order.
    func exportDDL(copy: Bool) {
        guard let ws = workspace, let g = shownGraph else { return }
        // parents before children so the script runs top to bottom
        var ordered: [ERDTable] = []
        var done: Set<String> = []
        func visit(_ t: ERDTable, _ path: Set<String>) {
            if done.contains(t.id) || path.contains(t.id) { return }
            for r in g.relations where r.fromTable == t.id && r.toTable != t.id {
                if let p = g.table(r.toTable) { visit(p, path.union([t.id])) }
            }
            done.insert(t.id)
            ordered.append(t)
        }
        for t in g.tables.sorted(by: { ($0.kind == .table ? 0 : 1, $0.name) < ($1.kind == .table ? 0 : 1, $1.name) }) { visit(t, []) }
        let objects = ordered.filter { !$0.isExternal }.map { DBObject(schema: $0.schema, name: $0.name, kind: $0.kind) }
        Task {
            do {
                let parts = try await ws.run { d in try objects.map { o in "-- \(o.kind.rawValue): \(o.name)\n" + (try d.ddl(of: o)) } }
                let sql = "-- \(g.title) — generated by Tabula on \(Date().formatted())\n\n" + parts.joined(separator: "\n\n") + "\n"
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                    ws.showToast("SQL DDL copied")
                } else {
                    save(Data(sql.utf8), ext: "sql", type: UTType(filenameExtension: "sql"))
                }
            } catch {
                ws.showToast(error.localizedDescription, error: true)
            }
        }
    }
}
