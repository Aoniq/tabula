import SwiftUI
import AppKit

/// Developer tool: `Tabula --snapshot "<connection name>" <outdir>` renders key screens
/// offscreen to PNG files (no screen-recording permission needed), then quits.
@MainActor
enum DevSnapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func run() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else {
            print("usage: --snapshot <connection name> <outdir>")
            exit(2)
        }
        let name = args[i + 1]
        let out = args[i + 2]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let welcome = host(WelcomeView().frame(width: 920, height: 600), size: NSSize(width: 920, height: 600))
        await pause(1.0)
        snap(welcome, "\(out)/01-welcome.png")
        welcome.close()

        let ws: WorkspaceState
        if let (cfg, pw) = ConnectionURL.parse(name) {
            var c = cfg
            c.ssl.mode = .disable
            ws = WorkspaceState(config: c)
            await ws.connect(password: pw ?? "")
        } else if let config = ConnectionStore.shared.connections.first(where: { $0.name == name }) {
            ws = WorkspaceState(config: config)
            await ws.start()
        } else {
            print("no connection named \(name)")
            exit(1)
        }
        guard ws.isConnected else {
            print("connect failed: \(ws.status)")
            exit(1)
        }
        let win = host(WorkspaceView(ws: ws).frame(width: 1360, height: 860), size: NSSize(width: 1360, height: 860))
        await pause(1.0)
        snap(win, "\(out)/02-workspace.png")
        if let si = args.firstIndex(of: "--schema"), args.count > si + 1 { await ws.switchSchema(args[si + 1]); await pause(0.5) }
        if args.contains("--erd-only") {
            ws.openERD()
            await pause(2.0)
            snap(win, "\(out)/erd-1-overview.png")
            if let canvas = findView(ERDCanvasView.self, in: win.contentView!), let scroll = canvas.enclosingScrollView {
                func wheel(_ lines: Int32, precise: Bool, cmd: Bool = false) -> NSEvent? {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
                    let mid = canvas.convert(NSPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY), to: nil)
                    cg.location = win.convertPoint(toScreen: mid)
                    if cmd { cg.flags = .maskCommand }
                    return NSEvent(cgEvent: cg)
                }
                let m0 = scroll.magnification
                if let e = wheel(3, precise: false) { canvas.scrollWheel(with: e) }
                let m1 = scroll.magnification
                if let e = wheel(-3, precise: false) { canvas.scrollWheel(with: e) }
                let m2 = scroll.magnification
                scroll.magnification = 2
                let o0 = scroll.contentView.bounds.origin
                if let e = wheel(-40, precise: true) { canvas.scrollWheel(with: e) }
                await pause(0.4)
                let m3 = scroll.magnification
                let o1 = scroll.contentView.bounds.origin
                if let e = wheel(30, precise: true, cmd: true) { canvas.scrollWheel(with: e) }
                let m4 = scroll.magnification

                print(String(format: "zoom test: start %.3f  mouse-wheel up %.3f  down %.3f  trackpad-scroll %.3f (pan dy %.0f)  cmd+trackpad %.3f",
                             m0, m1, m2, m3, o1.y - o0.y, m4))
                await pause(0.2)
            }
            if case .erd(let e) = ws.selectedTab?.content, let g = e.graph {
                let pick = g.tables.first { $0.name == "orders" || $0.name == "employees" } ?? g.tables.first!
                e.select(pick.id)
                await pause(0.8)
                snap(win, "\(out)/erd-2-selected.png")
                e.setFocus(true)
                await pause(1.2)
                snap(win, "\(out)/erd-3-focus.png")
                e.setFocus(false)
                e.options.detail = .keys
                await pause(1.2)
                snap(win, "\(out)/erd-4-keys.png")
                e.options.detail = .all
                e.selected = nil
                if let sc = e.scene() {
                    let cap = "\(g.title) · \(g.tables.count) tables · \(g.relations.count) relationships"
                    try? ERDImageExport.png(sc, theme: .light, caption: cap)?.write(to: URL(fileURLWithPath: "\(out)/export.png"))
                    try? ERDImageExport.png(sc, theme: .dark, caption: cap)?.write(to: URL(fileURLWithPath: "\(out)/export-dark.png"))
                    try? ERDImageExport.pdf(sc, theme: .light, caption: cap, title: g.title)?.write(to: URL(fileURLWithPath: "\(out)/export.pdf"))
                    try? ERDImageExport.svg(sc, theme: .light, caption: cap).write(toFile: "\(out)/export.svg", atomically: true, encoding: .utf8)
                }
            }
            print("erd snapshots written to \(out)")
            exit(0)
        }
        if CommandLine.arguments.contains("--assistant-first") {
            ws.showInspector = true
            ws.showAssistant = !CommandLine.arguments.contains("--row-panel")
            await pause(2.0)
            snap(win, "\(out)/02b-assistant.png")
            ws.showInspector = false
            await pause(1.0)
        }

        if let table = ws.objects.first(where: { $0.kind == .table && ["customers", "user:1"].contains($0.name) }) ?? ws.objects.first(where: { $0.kind == .table }) {
            ws.openTable(table)
            await pause(1.5)
            if let t = ws.selectedTableTab {
                t.selection = IndexSet(integer: 1)
                if ws.family != .redis { t.setValue(.text("edited value"), row: 0, column: min(1, t.resultColumns.count - 1)) }
                t.addRow()
                ws.showInspector = true
                await pause(1.0)
                snap(win, "\(out)/03-table-data.png")
                t.discardChanges()
                t.showFilters = true
                t.filters = [FilterRule(column: t.resultColumns.dropFirst().first?.name ?? "", op: .contains, value: "1")]
                t.applyFilters()
                ws.showInspector = false
                await pause(1.2)
                snap(win, "\(out)/04-table-filter.png")
                t.switchMode(.structure)
                await pause(1.2)
                snap(win, "\(out)/05-table-structure.png")
            }
        }

        let sql: String
        switch ws.family {
        case .postgres: sql = "-- Revenue per country\nSELECT c.country, count(o.id) AS orders, sum(o.total) AS revenue\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nWHERE o.status <> 'cancelled'\nGROUP BY c.country\nORDER BY revenue DESC;"
        case .mysql: sql = "SELECT c.country, COUNT(o.id) AS orders, SUM(o.total) AS revenue FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.country ORDER BY revenue DESC;"
        case .sqlite: sql = "SELECT * FROM customers;"
        case .redis: sql = "INFO server\nKEYS *"
        }
        let q = ws.newQueryTab(sql: sql, title: "Snapshot query")
        await q.runAll()
        q.selectedRange = NSRange(location: 0, length: 0)
        await pause(1.2)
        snap(win, "\(out)/06-query.png")

        if ws.family != .redis {
            let q2 = ws.newQueryTab(sql: "SELECT * FROM products ORDER BY id LIMIT 20;", title: "Editable result")
            await q2.runAll()
            if let r = q2.selectedResult {
                let m = q2.model(for: r)
                await pause(0.8)
                m.gridSetValue(.text("Renamed product"), row: 0, column: 2)
                print("editable result:", m.editTable?.name ?? "no", "changes:", m.changeStatements())
            }
            await pause(0.8)
            snap(win, "\(out)/06b-editable-result.png")
        }

        if ws.family != .redis {
            ws.openDashboard()
            if case .dashboard(let d) = ws.selectedTab?.content {
                if d.tiles.isEmpty { d.addSampleTiles() }
                await d.refreshAll()
            }
            await pause(2.0)
            snap(win, "\(out)/06c-dashboard.png")
            ws.showInspector = true
            ws.showAssistant = true
            ws.selectNextTab(-1)
            await pause(2.5)
            snap(win, "\(out)/06d-assistant.png")
            ws.showInspector = false
        }

        ws.openProcessList()
        await pause(1.2)
        snap(win, "\(out)/07-processes.png")

        ws.showOpenAnything = true
        await pause(1.0)
        snap(win, "\(out)/08-open-anything.png", includeSheets: true)
        ws.showOpenAnything = false

        print("snapshots written to \(out)")
        exit(0)
    }

    private static func findView<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for sub in v.subviews { if let t = findView(type, in: sub) { return t } }
        return nil
    }

    private static func pause(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private static func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        let hv = NSHostingView(rootView: view)
        hv.sceneBridgingOptions = [.toolbars, .title]
        w.contentView = hv
        w.isReleasedWhenClosed = false
        w.alphaValue = 0.01
        w.orderFrontRegardless()
        return w
    }

    private static func snap(_ window: NSWindow, _ path: String, includeSheets: Bool = false) {
        let target = includeSheets ? (window.attachedSheet ?? window) : window
        guard let view = target.contentView?.superview ?? target.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Developer tool: `Tabula --scrollbench "<connection name>" <table> [rows]` loads a table
/// into the grid and measures how long it takes to scroll through it, then quits.
@MainActor
enum ScrollBench {
    static var requested: Bool { CommandLine.arguments.contains("--scrollbench") }

    static func run() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scrollbench"), args.count > i + 2,
              let (config, password) = ConnectionURL.parse(args[i + 1]) else {
            print("usage: --scrollbench <connection url> <table> [rows]"); exit(2)
        }
        let tableName = args[i + 2]
        let rows = args.count > i + 3 ? Int(args[i + 3]) ?? 5000 : 5000
        var cfg = config
        cfg.ssl.mode = .disable
        let ws = WorkspaceState(config: cfg)
        await ws.connect(password: password ?? "")
        guard ws.isConnected, let obj = ws.objects.first(where: { $0.name == tableName }) else { print("connect/table failed: \(ws.status) objects=\(ws.objects.count)"); exit(1) }
        let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1360, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: WorkspaceView(ws: ws).frame(width: 1360, height: 860))
        win.alphaValue = 0.01
        win.orderFrontRegardless()
        ws.openTable(obj)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let t = ws.selectedTableTab else { exit(1) }
        t.pageSize = rows
        await t.reload(recount: false)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let table = findTable(in: win.contentView!) else { print("no table view"); exit(1) }
        let scroll = table.enclosingScrollView!
        let rowH = table.rowHeight
        let visible = scroll.contentView.bounds.height
        let total = CGFloat(table.numberOfRows) * rowH
        var frames: [Double] = []
        // Fling-style scroll: ~1.2 screens per frame, top to bottom and back.
        let step = visible * 1.2
        var y: CGFloat = 0
        var dir: CGFloat = 1
        for _ in 0..<(Int(ProcessInfo.processInfo.environment["BENCH_FRAMES"] ?? "") ?? 400) {
            y += step * dir
            if y > total - visible { y = total - visible; dir = -1 }
            if y < 0 { y = 0; dir = 1 }
            let t0 = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            win.contentView!.displayIfNeeded()
            frames.append((CACurrentMediaTime() - t0) * 1000)
        }
        frames.sort()
        let avg = frames.reduce(0, +) / Double(frames.count)
        print(String(format: "rows=%d cols=%d  frame avg %.2f ms  p50 %.2f  p95 %.2f  max %.2f",
                     table.numberOfRows, table.numberOfColumns, avg, frames[frames.count / 2], frames[Int(Double(frames.count) * 0.95)], frames.last!))
        exit(0)
    }

    private static func findTable(in v: NSView) -> NSTableView? {
        if let t = v as? GridTableView { return t }
        for s in v.subviews { if let t = findTable(in: s) { return t } }
        return nil
    }
}

/// Developer tool: `Tabula --erd-dump <connection url> [schema]` prints the ER graph as JSON.
@MainActor
enum ERDDump {
    static var requested: Bool { CommandLine.arguments.contains("--erd-dump") }

    static func run() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--erd-dump"), args.count > i + 1, let (cfg, pw) = ConnectionURL.parse(args[i + 1]) else {
            FileHandle.standardError.write("usage: --erd-dump <connection url> [schema]\n".data(using: .utf8)!)
            exit(2)
        }
        var c = cfg
        c.ssl.mode = .disable
        let ws = WorkspaceState(config: c)
        await ws.connect(password: pw ?? "")
        guard ws.isConnected else { FileHandle.standardError.write("connect failed: \(ws.status)\n".data(using: .utf8)!); exit(1) }
        if args.count > i + 2 { await ws.switchSchema(args[i + 2]) }
        do {
            let g = try await ERDLoader.load(ws)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(g), encoding: .utf8)!)
            exit(0)
        } catch {
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
