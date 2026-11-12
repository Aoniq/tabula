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

        guard let config = ConnectionStore.shared.connections.first(where: { $0.name == name }) else {
            print("no connection named \(name)")
            exit(1)
        }
        let ws = WorkspaceState(config: config)
        await ws.start()
        guard ws.isConnected else {
            print("connect failed: \(ws.status)")
            exit(1)
        }
        let win = host(WorkspaceView(ws: ws).frame(width: 1360, height: 860), size: NSSize(width: 1360, height: 860))
        await pause(1.0)
        snap(win, "\(out)/02-workspace.png")
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
