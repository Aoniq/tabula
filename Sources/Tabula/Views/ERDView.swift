import SwiftUI
import AppKit

struct ERDView: View {
    @Bindable var state: ERDState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if state.graph != nil {
                    ERDCanvasRepresentable(state: state)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
                if state.loading {
                    ProgressView("Reading schema…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if let e = state.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(e).multilineTextAlignment(.center).textSelection(.enabled)
                        Button("Retry") { Task { await state.load() } }
                    }
                    .padding(24)
                } else if let g = state.graph, g.tables.isEmpty {
                    ContentUnavailableView("No tables", systemImage: "tablecells", description: Text("This schema has no tables to diagram."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .task { if state.graph == nil { await state.load() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.options.detail) {
                ForEach(ERDDetail.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Show all columns, only key columns, or table names only")
            Toggle("Types", isOn: $state.options.showTypes).toggleStyle(.checkbox)
                .disabled(state.options.detail == .names)
            Toggle("Views", isOn: Binding(get: { state.includeViews }, set: { state.setIncludeViews($0) })).toggleStyle(.checkbox)
            Divider().frame(height: 16)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find table", text: $state.search)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                    .onSubmit { state.find() }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Toggle(isOn: Binding(get: { state.focusMode }, set: { state.setFocus($0) })) {
                Label("Focus", systemImage: "scope")
            }
            .toggleStyle(.button)
            .disabled(state.selected == nil)
            .help("Show only the selected table and the tables it is related to")
            Button { state.autoArrange() } label: { Label("Arrange", systemImage: "rectangle.3.group") }
                .help("Automatically arrange tables")
            Spacer()
            HStack(spacing: 2) {
                Button { state.request(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Button { state.request(.fit) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Zoom to fit")
                Button { state.request(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            }
            exportMenu
            Button { Task { await state.load() } } label: { Image(systemName: "arrow.clockwise") }.help("Reload schema")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var exportMenu: some View {
        Menu {
            Section("Image") {
                Button("PNG Image…") { state.exportImage(.png) }
                Button("PDF Document…") { state.exportImage(.pdf) }
                Button("SVG Vector…") { state.exportImage(.svg) }
                Button("Copy Image") { state.copyImage() }
                Picker("Image Theme", selection: $state.imageTheme) {
                    ForEach(ERDState.ImageTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Include Caption", isOn: $state.includeCaption)
            }
            Section("Diagram as Code") {
                ForEach([ERDState.TextFormat.mermaid, .dbml, .plantUML, .dot]) { f in
                    Menu(f.rawValue) {
                        Button("Save \(f.rawValue)…") { state.exportText(f) }
                        Button("Copy \(f.rawValue)") { state.copyText(f) }
                        Divider()
                        Text(f.hint)
                    }
                }
            }
            Section("Documentation") {
                Button("Markdown Data Dictionary…") { state.exportText(.markdown) }
                Button("Copy Markdown Data Dictionary") { state.copyText(.markdown) }
                Button("SQL DDL…") { state.exportDDL(copy: false) }
                Button("Copy SQL DDL") { state.exportDDL(copy: true) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state.graph == nil)
        .help(state.focusMode ? "Exports the focused tables" : "Exports the whole diagram")
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let g = state.graph {
                let shown = state.shownGraph
                Text("\(shown?.tables.count ?? 0) tables · \(shown?.relations.count ?? 0) relationships")
                if state.focusMode { Text("(focus of \(g.tables.count))").foregroundStyle(.tertiary) }
                if let s = state.selected, let t = g.table(s) {
                    Divider().frame(height: 12)
                    let refs = g.relations.filter { $0.fromTable == s }.map { g.table($0.toTable)?.name ?? $0.toTable }
                    let refBy = g.relations.filter { $0.toTable == s && $0.fromTable != s }.map { g.table($0.fromTable)?.name ?? $0.fromTable }
                    Text(t.name).fontWeight(.medium)
                    if !refs.isEmpty { Text("→ " + Array(Set(refs)).sorted().joined(separator: ", ")).lineLimit(1) }
                    if !refBy.isEmpty { Text("← " + Array(Set(refBy)).sorted().joined(separator: ", ")).lineLimit(1) }
                    if !t.comment.isEmpty { Text("— \(t.comment)").foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            Text("Drag tables to arrange · double-click to open · pinch or ⌘-scroll to zoom")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

// MARK: - Canvas

struct ERDCanvasRepresentable: NSViewRepresentable {
    let state: ERDState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ERDScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.08
        scroll.maxMagnification = 3
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        let canvas = ERDCanvasView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1500))
        scroll.documentView = canvas
        context.coordinator.canvas = canvas
        context.coordinator.scroll = scroll
        wire(canvas)
        return scroll
    }

    private func wire(_ canvas: ERDCanvasView) {
        let state = self.state
        canvas.onSelect = { id in state.select(id) }
        canvas.onMove = { id, p in state.moved(id, to: p) }
        canvas.onOpen = { id in state.open(id) }
        canvas.menuProvider = { id in
            let menu = NSMenu()
            guard let id, let t = state.graph?.table(id) else {
                menu.addItem(ClosureMenuItem(title: "Arrange Automatically") { state.autoArrange() })
                menu.addItem(ClosureMenuItem(title: "Zoom to Fit") { state.request(.fit) })
                return menu
            }
            if !t.isExternal {
                menu.addItem(ClosureMenuItem(title: "Open Data") { state.open(id) })
                menu.addItem(ClosureMenuItem(title: "Open Structure") { state.open(id, mode: .structure) })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(title: state.focusMode ? "Show All Tables" : "Focus on \(t.name)") {
                if state.focusMode { state.setFocus(false) } else { state.select(id); state.setFocus(true) }
            })
            menu.addItem(ClosureMenuItem(title: "Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.name, forType: .string)
            })
            return menu
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let canvas = c.canvas else { return }
        wire(canvas)
        let theme = ERDTheme.forAppearance(scroll.effectiveAppearance)
        scroll.backgroundColor = theme.canvas
        if c.lastVersion != state.version || canvas.scene == nil {
            c.lastVersion = state.version
            canvas.scene = state.scene()
        }
        canvas.renderState.selected = state.selected
        canvas.renderState.related = state.relatedToSelection
        canvas.resizeToFit(minimum: scroll.contentView.bounds.size)
        canvas.needsDisplay = true
        if c.lastZoomID != state.zoomRequestID, let z = state.zoomRequest {
            c.lastZoomID = state.zoomRequestID
            DispatchQueue.main.async { c.performZoom(z) }
        }
    }

    @MainActor
    final class Coordinator {
        weak var canvas: ERDCanvasView?
        weak var scroll: NSScrollView?
        var lastVersion = -1
        var lastZoomID = 0

        func performZoom(_ z: ERDState.ZoomRequest) {
            guard let scroll, let canvas, let scene = canvas.scene else { return }
            switch z {
            case .fit:
                guard !scene.bounds.isEmpty else { return }
                let target = scene.bounds.insetBy(dx: -40, dy: -40)
                let vis = scroll.contentView.bounds.size
                let m = scroll.magnification
                let viewport = CGSize(width: vis.width * m, height: vis.height * m)
                let mag = min(1.25, max(scroll.minMagnification, min(viewport.width / target.width, viewport.height / target.height)))
                scroll.magnification = mag
                center(on: CGPoint(x: target.midX, y: target.midY))
            case .zoomIn:
                scroll.setMagnification(min(scroll.maxMagnification, scroll.magnification * 1.25), centeredAt: visibleCenter())
            case .zoomOut:
                scroll.setMagnification(max(scroll.minMagnification, scroll.magnification / 1.25), centeredAt: visibleCenter())
            case .actualSize:
                scroll.setMagnification(1, centeredAt: visibleCenter())
            case .center(let id):
                guard let f = scene.frames[id] else { return }
                if scroll.magnification < 0.6 { scroll.magnification = 0.9 }
                center(on: CGPoint(x: f.midX, y: f.midY))
            }
        }

        private func visibleCenter() -> CGPoint {
            guard let scroll else { return .zero }
            let b = scroll.contentView.bounds
            return CGPoint(x: b.midX, y: b.midY)
        }

        private func center(on p: CGPoint) {
            guard let scroll, let canvas else { return }
            let b = scroll.contentView.bounds
            var origin = CGPoint(x: p.x - b.width / 2, y: p.y - b.height / 2)
            origin.x = max(0, min(origin.x, canvas.frame.width - b.width))
            origin.y = max(0, min(origin.y, canvas.frame.height - b.height))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

/// Scroll view where ⌘-scroll zooms (in addition to pinch).
final class ERDScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
            let p = contentView.convert(event.locationInWindow, from: nil)
            setMagnification(max(minMagnification, min(maxMagnification, magnification * (1 + delta))), centeredAt: p)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class ERDCanvasView: NSView {
    var scene: ERDScene?
    var renderState = ERDRenderState()
    var onSelect: ((String?) -> Void)?
    var onMove: ((String, CGPoint) -> Void)?
    var onOpen: ((String) -> Void)?
    var menuProvider: ((String?) -> NSMenu)?

    private var dragging: (id: String, offset: CGPoint, moved: Bool)?
    private var panStart: (window: CGPoint, origin: CGPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func resizeToFit(minimum: CGSize) {
        let b = scene?.bounds ?? .zero
        let w = max(minimum.width, b.maxX + 600)
        let h = max(minimum.height, b.maxY + 600)
        if abs(frame.width - w) > 1 || abs(frame.height - h) > 1 {
            setFrameSize(NSSize(width: w, height: h))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ERDTheme.forAppearance(effectiveAppearance)
        guard let scene else {
            theme.canvas.setFill()
            dirtyRect.fill()
            return
        }
        ERDRenderer.draw(scene, theme: theme, state: renderState, dirty: dirtyRect)
    }

    private func hit(_ p: CGPoint) -> String? {
        guard let scene else { return nil }
        // prefer the selected table when overlapping
        if let sel = renderState.selected, scene.frames[sel]?.contains(p) == true { return sel }
        return scene.frames.first { $0.value.contains(p) }?.key
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let id = hit(p), let f = scene?.frames[id] {
            if event.clickCount == 2 { onOpen?(id); return }
            renderState.selected = id
            onSelect?(id)
            dragging = (id, CGPoint(x: p.x - f.minX, y: p.y - f.minY), false)
            needsDisplay = true
        } else {
            if renderState.selected != nil {
                renderState.selected = nil
                onSelect?(nil)
                needsDisplay = true
            }
            if let clip = enclosingScrollView?.contentView {
                panStart = (event.locationInWindow, clip.bounds.origin)
                NSCursor.closedHand.push()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if var d = dragging, var scene {
            let p = convert(event.locationInWindow, from: nil)
            let origin = CGPoint(x: max(10, p.x - d.offset.x), y: max(10, p.y - d.offset.y))
            guard let old = scene.frames[d.id], let box = scene.boxes[d.id] else { return }
            let new = CGRect(origin: origin, size: old.size)
            scene.frames[d.id] = new
            // recompute only the edges attached to the moved table
            scene.edges = scene.edges.map { e in
                let r = e.relation
                guard r.fromTable == d.id || r.toTable == d.id,
                      let cf = scene.frames[r.fromTable], let pf = scene.frames[r.toTable],
                      let cb = scene.boxes[r.fromTable], let pb = scene.boxes[r.toTable] else { return e }
                return ERDScene.edgeShape(r, childFrame: cf, childBox: cb, parentFrame: pf, parentBox: pb)
            }
            scene.bounds = scene.bounds.union(new)
            _ = box
            self.scene = scene
            d.moved = true
            dragging = d
            resizeToFit(minimum: enclosingScrollView?.contentView.bounds.size ?? .zero)
            needsDisplay = true
            autoscroll(with: event)
        } else if let pan = panStart, let scroll = enclosingScrollView {
            let mag = scroll.magnification
            let dx = (event.locationInWindow.x - pan.window.x) / mag
            let dy = (event.locationInWindow.y - pan.window.y) / mag
            var o = CGPoint(x: pan.origin.x - dx, y: pan.origin.y + dy)
            let b = scroll.contentView.bounds
            o.x = max(0, min(o.x, frame.width - b.width))
            o.y = max(0, min(o.y, frame.height - b.height))
            scroll.contentView.scroll(to: o)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let d = dragging, d.moved, let f = scene?.frames[d.id] {
            onMove?(d.id, f.origin)
        }
        dragging = nil
        if panStart != nil {
            panStart = nil
            NSCursor.pop()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let id = hit(p)
        if let id {
            renderState.selected = id
            onSelect?(id)
            needsDisplay = true
        }
        return menuProvider?(id)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            renderState.selected = nil
            onSelect?(nil)
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .arrow)
    }
}
