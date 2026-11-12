import Foundation
import AppKit

// MARK: - Theme

struct ERDTheme {
    var canvas: NSColor
    var grid: NSColor
    var tableFill: NSColor
    var tableBorder: NSColor
    var headerFill: NSColor
    var title: NSColor
    var secondary: NSColor
    var text: NSColor
    var type: NSColor
    var divider: NSColor
    var edge: NSColor
    var edgeHighlight: NSColor
    var accentTable: NSColor
    var accentView: NSColor
    var accentExternal: NSColor
    var pk: NSColor
    var fk: NSColor
    var uq: NSColor
    var selection: NSColor
    var shadow: NSColor

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    static let light = ERDTheme(
        canvas: c(0xF6F7F9), grid: c(0xD9DDE3), tableFill: c(0xFFFFFF), tableBorder: c(0xD3D8E0), headerFill: c(0xF2F4F7),
        title: c(0x111827), secondary: c(0x6B7280), text: c(0x1F2937), type: c(0x6B7280), divider: c(0xE5E7EB),
        edge: c(0x8B95A7), edgeHighlight: c(0x2563EB), accentTable: c(0x2563EB), accentView: c(0x0D9488), accentExternal: c(0x9CA3AF),
        pk: c(0xB45309), fk: c(0x2563EB), uq: c(0x7C3AED), selection: c(0x2563EB), shadow: c(0x000000, 0.08))

    static let dark = ERDTheme(
        canvas: c(0x17191D), grid: c(0x2B2F36), tableFill: c(0x23262C), tableBorder: c(0x3A3F48), headerFill: c(0x2B2F36),
        title: c(0xF3F4F6), secondary: c(0x9CA3AF), text: c(0xE5E7EB), type: c(0x9CA3AF), divider: c(0x343841),
        edge: c(0x6B7385), edgeHighlight: c(0x60A5FA), accentTable: c(0x60A5FA), accentView: c(0x2DD4BF), accentExternal: c(0x6B7280),
        pk: c(0xFBBF24), fk: c(0x60A5FA), uq: c(0xA78BFA), selection: c(0x60A5FA), shadow: c(0x000000, 0.35))

    static func forAppearance(_ a: NSAppearance?) -> ERDTheme {
        let dark = a?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark : .light
    }

    func accent(for t: ERDTable) -> NSColor {
        if t.isExternal { return accentExternal }
        return t.kind == .table ? accentTable : accentView
    }
}

struct ERDRenderState {
    var selected: String?
    /// Tables related to the selection (drawn at full strength while others dim).
    var related: Set<String> = []
    var drawGrid = true
    var drawShadows = true
}

// MARK: - Core Graphics renderer (screen, PNG, PDF)

enum ERDRenderer {
    /// Draws into the current NSGraphicsContext, which must be flipped (y grows downward).
    static func draw(_ scene: ERDScene, theme: ERDTheme, state: ERDRenderState, dirty: CGRect, fillBackground: Bool = true) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if fillBackground {
            theme.canvas.setFill()
            dirty.fill()
        }
        if state.drawGrid {
            theme.grid.setFill()
            let step: CGFloat = 24
            var y = floor(dirty.minY / step) * step
            while y <= dirty.maxY {
                var x = floor(dirty.minX / step) * step
                while x <= dirty.maxX {
                    NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5).fill()
                    x += step
                }
                y += step
            }
        }
        let hasSelection = state.selected != nil
        // edges behind tables; highlighted ones last
        let sorted = scene.edges.sorted { a, b in
            isHighlighted(a, state) == isHighlighted(b, state) ? false : !isHighlighted(a, state)
        }
        for e in sorted where e.bounds.intersects(dirty) {
            let hi = isHighlighted(e, state)
            let color = hi ? theme.edgeHighlight : theme.edge.withAlphaComponent(hasSelection ? 0.25 : 1)
            drawEdge(e, color: color, width: hi ? 2 : 1.25, cg: cg)
        }
        for (id, frame) in scene.frames where frame.insetBy(dx: -12, dy: -12).intersects(dirty) {
            guard let box = scene.boxes[id] else { continue }
            let dim = hasSelection && !state.related.contains(id)
            drawTable(box, frame: frame, theme: theme, selected: state.selected == id, dimmed: dim, shadow: state.drawShadows, cg: cg)
        }
    }

    private static func isHighlighted(_ e: ERDEdgeShape, _ s: ERDRenderState) -> Bool {
        guard let sel = s.selected else { return false }
        return e.relation.fromTable == sel || e.relation.toTable == sel
    }

    static func drawEdge(_ e: ERDEdgeShape, color: NSColor, width: CGFloat, cg: CGContext) {
        let p = NSBezierPath()
        p.move(to: e.start)
        p.line(to: e.startStub)
        p.curve(to: e.endStub, controlPoint1: e.c1, controlPoint2: e.c2)
        p.line(to: e.end)
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
        for s in e.symbols {
            switch s {
            case .line(let a, let b):
                let l = NSBezierPath()
                l.move(to: a)
                l.line(to: b)
                l.lineWidth = width
                l.lineCapStyle = .round
                l.stroke()
            case .circle(let c, let r):
                let o = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                NSColor.clear.setFill()
                o.lineWidth = width
                o.stroke()
            }
        }
    }

    static func badge(for c: ERDColumn) -> (String, KeyPath<ERDTheme, NSColor>)? {
        if c.isPrimaryKey { return ("PK", \.pk) }
        if c.isForeignKey { return ("FK", \.fk) }
        if c.isUnique { return ("UQ", \.uq) }
        return nil
    }

    static func drawTable(_ box: ERDTableBox, frame: CGRect, theme: ERDTheme, selected: Bool, dimmed: Bool, shadow: Bool, cg: CGContext) {
        let t = box.table
        let alpha: CGFloat = dimmed ? 0.35 : 1
        cg.saveGState()
        cg.setAlpha(alpha)
        let body = NSBezierPath(roundedRect: frame, xRadius: ERDMetrics.corner, yRadius: ERDMetrics.corner)
        if shadow && !dimmed {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: theme.shadow.cgColor)
            theme.tableFill.setFill()
            body.fill()
            cg.restoreGState()
        } else {
            theme.tableFill.setFill()
            body.fill()
        }
        // header
        cg.saveGState()
        body.addClip()
        theme.headerFill.setFill()
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: ERDMetrics.headerHeight).fill()
        theme.accent(for: t).setFill()
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 3).fill()
        theme.divider.setFill()
        CGRect(x: frame.minX, y: frame.minY + ERDMetrics.headerHeight - 0.5, width: frame.width, height: 1).fill()
        cg.restoreGState()

        // title + kind tag
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: ERDMetrics.titleFont, .foregroundColor: theme.title]
        let tag: String? = t.isExternal ? "external" : (t.kind == .table ? nil : (t.kind == .materializedView ? "mat. view" : (t.kind == .foreignTable ? "foreign" : "view")))
        let tagW = tag.map { ERDMetrics.textWidth($0, ERDMetrics.schemaFont) + 8 } ?? 0
        let titleRect = CGRect(x: frame.minX + ERDMetrics.hPad, y: frame.minY + 3 + (ERDMetrics.headerHeight - 3 - 17) / 2,
                               width: frame.width - ERDMetrics.hPad * 2 - tagW, height: 17)
        (t.displayName as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
        if let tag {
            let attrs: [NSAttributedString.Key: Any] = [.font: ERDMetrics.schemaFont, .foregroundColor: theme.secondary]
            (tag as NSString).draw(at: CGPoint(x: frame.maxX - ERDMetrics.hPad - tagW + 8, y: frame.minY + 3 + (ERDMetrics.headerHeight - 3 - 13) / 2), withAttributes: attrs)
        }

        // rows
        var y = frame.minY + ERDMetrics.headerHeight + 2
        for c in box.shownColumns {
            let midY = y + ERDMetrics.rowHeight / 2
            if case let (label, color)? = badge(for: c) {
                let br = CGRect(x: frame.minX + ERDMetrics.hPad, y: midY - 7, width: ERDMetrics.badgeWidth - 2, height: 14)
                theme[keyPath: color].withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: br, xRadius: 3, yRadius: 3).fill()
                let la: [NSAttributedString.Key: Any] = [.font: ERDMetrics.badgeFont, .foregroundColor: theme[keyPath: color]]
                let lw = ERDMetrics.textWidth(label, ERDMetrics.badgeFont)
                (label as NSString).draw(at: CGPoint(x: br.midX - lw / 2, y: br.minY + 1.5), withAttributes: la)
            }
            let nameX = frame.minX + ERDMetrics.hPad + ERDMetrics.badgeWidth + 6
            let typeW = c.type.isEmpty ? 0 : min(frame.width * 0.5, ERDMetrics.textWidth(c.type, ERDMetrics.typeFont))
            let showType = typeW > 0 && box.typeColumnX > 0 && !c.type.isEmpty && frame.width > 0
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: c.isPrimaryKey ? ERDMetrics.columnKeyFont : ERDMetrics.columnFont, .foregroundColor: theme.text]
            let nameRect = CGRect(x: nameX, y: midY - 8, width: frame.maxX - ERDMetrics.hPad - nameX - (showType ? typeW + 10 : 0), height: 16)
            (c.name as NSString).draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttrs)
            if showType {
                let typeAttrs: [NSAttributedString.Key: Any] = [.font: ERDMetrics.typeFont, .foregroundColor: theme.type]
                let tr = CGRect(x: frame.maxX - ERDMetrics.hPad - typeW, y: midY - 7, width: typeW, height: 14)
                (c.type as NSString).draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: typeAttrs)
            }
            if !c.nullable && !c.isPrimaryKey {
                // tiny dot marks NOT NULL columns
                theme.secondary.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: CGRect(x: frame.minX + 5, y: midY - 1.5, width: 3, height: 3)).fill()
            }
            y += ERDMetrics.rowHeight
        }
        if box.hiddenCount > 0 {
            let attrs: [NSAttributedString.Key: Any] = [.font: ERDMetrics.schemaFont, .foregroundColor: theme.secondary]
            ("+ \(box.hiddenCount) more column\(box.hiddenCount == 1 ? "" : "s")" as NSString)
                .draw(at: CGPoint(x: frame.minX + ERDMetrics.hPad, y: y + 3), withAttributes: attrs)
        }

        // border
        if selected {
            theme.selection.setStroke()
            body.lineWidth = 2
        } else {
            (t.isExternal ? theme.tableBorder.withAlphaComponent(0.8) : theme.tableBorder).setStroke()
            body.lineWidth = 1
        }
        if t.isExternal { body.setLineDash([4, 3], count: 2, phase: 0) }
        body.stroke()
        cg.restoreGState()
    }
}

// MARK: - Image / PDF / SVG export

enum ERDImageExport {
    static let padding: CGFloat = 40
    static let captionHeight: CGFloat = 30

    static func exportBounds(_ scene: ERDScene, caption: String?) -> CGRect {
        var b = scene.bounds.insetBy(dx: -padding, dy: -padding)
        if caption != nil { b.size.height += captionHeight }
        return b.integral
    }

    private static func drawExport(_ scene: ERDScene, theme: ERDTheme, caption: String?, bounds: CGRect) {
        theme.canvas.setFill()
        bounds.fill()
        ERDRenderer.draw(scene, theme: theme, state: ERDRenderState(drawGrid: false, drawShadows: true), dirty: bounds, fillBackground: false)
        if let caption {
            let attrs: [NSAttributedString.Key: Any] = [.font: ERDMetrics.captionFont, .foregroundColor: theme.secondary]
            (caption as NSString).draw(at: CGPoint(x: bounds.minX + padding, y: bounds.maxY - captionHeight - 4), withAttributes: attrs)
        }
    }

    /// Run `body` with a flipped NSGraphicsContext over `cg` whose origin is `bounds.origin`.
    private static func withFlippedContext(_ cg: CGContext, bounds: CGRect, scale: CGFloat, _ body: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: 0, y: bounds.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -bounds.minX, y: -bounds.minY)
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body()
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    static func png(_ scene: ERDScene, theme: ERDTheme, caption: String?, scale: CGFloat = 2) -> Data? {
        let b = exportBounds(scene, caption: caption)
        // keep within a sane pixel budget for giant schemas
        let maxSide: CGFloat = 16000
        let s = min(scale, maxSide / max(b.width, b.height))
        let w = Int(ceil(b.width * s)), h = Int(ceil(b.height * s))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        withFlippedContext(ctx.cgContext, bounds: b, scale: s) { drawExport(scene, theme: theme, caption: caption, bounds: b) }
        rep.size = b.size   // 72-dpi point size → retina-aware
        return rep.representation(using: .png, properties: [:])
    }

    static func pdf(_ scene: ERDScene, theme: ERDTheme, caption: String?, title: String) -> Data? {
        let b = exportBounds(scene, caption: caption)
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: b.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Tabula"] as CFDictionary) else { return nil }
        cg.beginPDFPage(nil)
        withFlippedContext(cg, bounds: b, scale: 1) { drawExport(scene, theme: theme, caption: caption, bounds: b) }
        cg.endPDFPage()
        cg.closePDF()
        return data as Data
    }

    // MARK: SVG

    private static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func f(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// Truncate text to fit `width` using the same fonts as the canvas.
    private static func fit(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        if ERDMetrics.textWidth(s, font) <= width { return s }
        var t = s
        while !t.isEmpty && ERDMetrics.textWidth(t + "…", font) > width { t.removeLast() }
        return t + "…"
    }

    static func svg(_ scene: ERDScene, theme: ERDTheme, caption: String?) -> String {
        let b = exportBounds(scene, caption: caption)
        let sans = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
        let mono = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
        var o = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(b.width))" height="\(f(b.height))" viewBox="\(f(b.minX)) \(f(b.minY)) \(f(b.width)) \(f(b.height))" font-family="\(sans)">
        <defs><filter id="sh" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#000" flood-opacity="\((theme.shadow.usingColorSpace(.sRGB) ?? theme.shadow).alphaComponent)"/></filter></defs>
        <rect x="\(f(b.minX))" y="\(f(b.minY))" width="\(f(b.width))" height="\(f(b.height))" fill="\(hex(theme.canvas))"/>

        """
        // edges
        o += "<g fill=\"none\" stroke=\"\(hex(theme.edge))\" stroke-width=\"1.25\" stroke-linecap=\"round\">\n"
        for e in scene.edges {
            o += "<path d=\"M\(f(e.start.x)),\(f(e.start.y)) L\(f(e.startStub.x)),\(f(e.startStub.y)) C\(f(e.c1.x)),\(f(e.c1.y)) \(f(e.c2.x)),\(f(e.c2.y)) \(f(e.endStub.x)),\(f(e.endStub.y)) L\(f(e.end.x)),\(f(e.end.y))\"><title>\(esc(e.relation.name))</title></path>\n"
            for s in e.symbols {
                switch s {
                case .line(let a, let c): o += "<line x1=\"\(f(a.x))\" y1=\"\(f(a.y))\" x2=\"\(f(c.x))\" y2=\"\(f(c.y))\"/>\n"
                case .circle(let c, let r): o += "<circle cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" r=\"\(f(r))\" fill=\"\(hex(theme.canvas))\"/>\n"
                }
            }
        }
        o += "</g>\n"
        // tables (stable order)
        for id in scene.frames.keys.sorted() {
            guard let fr = scene.frames[id], let box = scene.boxes[id] else { continue }
            let t = box.table
            let clip = "clip-\(abs(id.hashValue))"
            o += "<g>\n<title>\(esc(t.id))\(t.comment.isEmpty ? "" : " — " + esc(t.comment))</title>\n"
            o += "<clipPath id=\"\(clip)\"><rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"\(f(fr.height))\" rx=\"\(f(ERDMetrics.corner))\"/></clipPath>\n"
            o += "<rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"\(f(fr.height))\" rx=\"\(f(ERDMetrics.corner))\" fill=\"\(hex(theme.tableFill))\" filter=\"url(#sh)\"/>\n"
            o += "<g clip-path=\"url(#\(clip))\"><rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"\(f(ERDMetrics.headerHeight))\" fill=\"\(hex(theme.headerFill))\"/>"
            o += "<rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"3\" fill=\"\(hex(theme.accent(for: t)))\"/>"
            o += "<rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY + ERDMetrics.headerHeight - 0.5))\" width=\"\(f(fr.width))\" height=\"1\" fill=\"\(hex(theme.divider))\"/></g>\n"
            let tag: String? = t.isExternal ? "external" : (t.kind == .table ? nil : (t.kind == .materializedView ? "mat. view" : (t.kind == .foreignTable ? "foreign" : "view")))
            let tagW = tag.map { ERDMetrics.textWidth($0, ERDMetrics.schemaFont) + 8 } ?? 0
            let titleY = fr.minY + 3 + (ERDMetrics.headerHeight - 3) / 2 + 4.5
            o += "<text x=\"\(f(fr.minX + ERDMetrics.hPad))\" y=\"\(f(titleY))\" font-size=\"13\" font-weight=\"600\" fill=\"\(hex(theme.title))\">\(esc(fit(t.displayName, ERDMetrics.titleFont, fr.width - ERDMetrics.hPad * 2 - tagW)))</text>\n"
            if let tag {
                o += "<text x=\"\(f(fr.maxX - ERDMetrics.hPad))\" y=\"\(f(titleY - 1))\" font-size=\"10\" text-anchor=\"end\" fill=\"\(hex(theme.secondary))\">\(tag)</text>\n"
            }
            var y = fr.minY + ERDMetrics.headerHeight + 2
            for c in box.shownColumns {
                let mid = y + ERDMetrics.rowHeight / 2
                if case let (label, kp)? = ERDRenderer.badge(for: c) {
                    let col = theme[keyPath: kp]
                    o += "<rect x=\"\(f(fr.minX + ERDMetrics.hPad))\" y=\"\(f(mid - 7))\" width=\"\(f(ERDMetrics.badgeWidth - 2))\" height=\"14\" rx=\"3\" fill=\"\(hex(col))\" fill-opacity=\"0.14\"/>"
                    o += "<text x=\"\(f(fr.minX + ERDMetrics.hPad + (ERDMetrics.badgeWidth - 2) / 2))\" y=\"\(f(mid + 3))\" font-size=\"8.5\" font-weight=\"700\" text-anchor=\"middle\" fill=\"\(hex(col))\">\(label)</text>\n"
                }
                let nameX = fr.minX + ERDMetrics.hPad + ERDMetrics.badgeWidth + 6
                let typeW = c.type.isEmpty ? 0 : min(fr.width * 0.5, ERDMetrics.textWidth(c.type, ERDMetrics.typeFont))
                let nameFont = c.isPrimaryKey ? ERDMetrics.columnKeyFont : ERDMetrics.columnFont
                let nameMax = fr.maxX - ERDMetrics.hPad - nameX - (typeW > 0 ? typeW + 10 : 0)
                o += "<text x=\"\(f(nameX))\" y=\"\(f(mid + 4))\" font-size=\"12\"\(c.isPrimaryKey ? " font-weight=\"500\"" : "") fill=\"\(hex(theme.text))\">\(esc(fit(c.name, nameFont, nameMax)))</text>"
                if typeW > 0 {
                    o += "<text x=\"\(f(fr.maxX - ERDMetrics.hPad))\" y=\"\(f(mid + 3.5))\" font-size=\"10.5\" font-family=\"\(mono)\" text-anchor=\"end\" fill=\"\(hex(theme.type))\">\(esc(fit(c.type, ERDMetrics.typeFont, fr.width * 0.5)))</text>"
                }
                if !c.nullable && !c.isPrimaryKey {
                    o += "<circle cx=\"\(f(fr.minX + 6.5))\" cy=\"\(f(mid))\" r=\"1.5\" fill=\"\(hex(theme.secondary))\" fill-opacity=\"0.6\"/>"
                }
                o += "\n"
                y += ERDMetrics.rowHeight
            }
            if box.hiddenCount > 0 {
                o += "<text x=\"\(f(fr.minX + ERDMetrics.hPad))\" y=\"\(f(y + 13))\" font-size=\"10\" fill=\"\(hex(theme.secondary))\">+ \(box.hiddenCount) more column\(box.hiddenCount == 1 ? "" : "s")</text>\n"
            }
            o += "<rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"\(f(fr.height))\" rx=\"\(f(ERDMetrics.corner))\" fill=\"none\" stroke=\"\(hex(theme.tableBorder))\"\(t.isExternal ? " stroke-dasharray=\"4 3\"" : "")/>\n</g>\n"
        }
        if let caption {
            o += "<text x=\"\(f(b.minX + padding))\" y=\"\(f(b.maxY - captionHeight + 10))\" font-size=\"11\" fill=\"\(hex(theme.secondary))\">\(esc(caption))</text>\n"
        }
        o += "</svg>\n"
        return o
    }
}
