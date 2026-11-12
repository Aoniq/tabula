import Foundation
import AppKit

enum ERDDetail: String, CaseIterable, Identifiable, Codable {
    case all = "Columns", keys = "Keys", names = "Names"
    var id: String { rawValue }
}

struct ERDOptions: Equatable {
    var detail: ERDDetail = .all
    var showTypes = true
}

// MARK: - Metrics

enum ERDMetrics {
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 22
    static let footerHeight: CGFloat = 20
    static let minWidth: CGFloat = 170
    static let maxWidth: CGFloat = 380
    static let hPad: CGFloat = 12
    static let badgeWidth: CGFloat = 24
    static let corner: CGFloat = 8

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let schemaFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let columnFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let columnKeyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let badgeFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }
}

// MARK: - Per-table geometry

struct ERDTableBox {
    let table: ERDTable
    /// Columns shown for the current detail level.
    let shownColumns: [ERDColumn]
    let hiddenCount: Int
    let size: CGSize
    let typeColumnX: CGFloat   // x offset where type text is right-aligned against

    static func make(_ t: ERDTable, options: ERDOptions) -> ERDTableBox {
        let shown: [ERDColumn]
        switch options.detail {
        case .all: shown = t.columns
        case .keys: shown = t.columns.filter { $0.isPrimaryKey || $0.isForeignKey || $0.isUnique }
        case .names: shown = []
        }
        let hidden = t.columns.count - shown.count
        var nameW: CGFloat = 0
        var typeW: CGFloat = 0
        for c in shown {
            nameW = max(nameW, ERDMetrics.textWidth(c.name, c.isPrimaryKey ? ERDMetrics.columnKeyFont : ERDMetrics.columnFont))
            if options.showTypes { typeW = max(typeW, ERDMetrics.textWidth(c.type, ERDMetrics.typeFont)) }
        }
        let titleW = ERDMetrics.textWidth(t.displayName, ERDMetrics.titleFont) + 40
        var width = ERDMetrics.hPad * 2 + ERDMetrics.badgeWidth + 6 + nameW + (typeW > 0 ? 18 + typeW : 0)
        width = min(ERDMetrics.maxWidth, max(ERDMetrics.minWidth, max(width, titleW)))
        var height = ERDMetrics.headerHeight + CGFloat(shown.count) * ERDMetrics.rowHeight
        if hidden > 0 && options.detail != .names { height += ERDMetrics.footerHeight }
        if !shown.isEmpty || hidden > 0 && options.detail != .names { height += 4 }
        return ERDTableBox(table: t, shownColumns: shown, hiddenCount: options.detail == .names ? 0 : hidden,
                           size: CGSize(width: width, height: height), typeColumnX: width - ERDMetrics.hPad)
    }

    /// Y (relative to table top) of the row for `column`, or the header center when not shown.
    func anchorY(_ column: String?) -> CGFloat {
        if let column, let i = shownColumns.firstIndex(where: { $0.name == column }) {
            return ERDMetrics.headerHeight + 2 + CGFloat(i) * ERDMetrics.rowHeight + ERDMetrics.rowHeight / 2
        }
        return ERDMetrics.headerHeight / 2
    }
}

// MARK: - Edge geometry (shared by canvas, PDF/PNG and SVG)

enum ERDPrimitive {
    case line(CGPoint, CGPoint)
    case circle(CGPoint, CGFloat)
}

struct ERDEdgeShape {
    let relation: ERDRelation
    /// Polyline start → stub → cubic → stub → end.
    let start: CGPoint
    let startStub: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let endStub: CGPoint
    let end: CGPoint
    let symbols: [ERDPrimitive]
    var bounds: CGRect {
        let xs = [start.x, startStub.x, c1.x, c2.x, endStub.x, end.x]
        let ys = [start.y, startStub.y, c1.y, c2.y, endStub.y, end.y]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -12, dy: -12)
    }
}

struct ERDScene {
    var boxes: [String: ERDTableBox]
    var frames: [String: CGRect]
    var edges: [ERDEdgeShape]
    var bounds: CGRect

    static func build(graph: ERDGraph, positions: [String: CGPoint], options: ERDOptions) -> ERDScene {
        var boxes: [String: ERDTableBox] = [:]
        var frames: [String: CGRect] = [:]
        for t in graph.tables {
            let b = ERDTableBox.make(t, options: options)
            boxes[t.id] = b
            frames[t.id] = CGRect(origin: positions[t.id] ?? .zero, size: b.size)
        }
        var edges: [ERDEdgeShape] = []
        // Spread multiple edges hitting the same header anchor
        for r in graph.relations {
            guard let cf = frames[r.fromTable], let pf = frames[r.toTable], let cb = boxes[r.fromTable], let pb = boxes[r.toTable] else { continue }
            edges.append(edgeShape(r, childFrame: cf, childBox: cb, parentFrame: pf, parentBox: pb))
        }
        var bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
        for e in edges { bounds = bounds.union(e.bounds) }
        if bounds.isNull { bounds = .zero }
        return ERDScene(boxes: boxes, frames: frames, edges: edges, bounds: bounds)
    }

    static func edgeShape(_ r: ERDRelation, childFrame cf: CGRect, childBox cb: ERDTableBox, parentFrame pf: CGRect, parentBox pb: ERDTableBox) -> ERDEdgeShape {
        let cy = cf.minY + cb.anchorY(r.fromColumns.first)
        let py = pf.minY + pb.anchorY(r.toColumns.first)
        let stub: CGFloat = 18
        let start: CGPoint, end: CGPoint, sDir: CGFloat, eDir: CGFloat
        if r.fromTable == r.toTable {
            // self reference: loop on the right side
            start = CGPoint(x: cf.maxX, y: cy)
            end = CGPoint(x: cf.maxX, y: py == cy ? cy + ERDMetrics.rowHeight : py)
            sDir = 1; eDir = 1
            let loop: CGFloat = 60
            let ss = CGPoint(x: start.x + stub, y: start.y)
            let es = CGPoint(x: end.x + stub, y: end.y)
            return ERDEdgeShape(relation: r, start: start, startStub: ss, c1: CGPoint(x: ss.x + loop, y: ss.y), c2: CGPoint(x: es.x + loop, y: es.y),
                                endStub: es, end: end, symbols: symbols(r, start: start, sDir: sDir, end: end, eDir: eDir))
        }
        if pf.minX > cf.maxX + 2 * stub {
            start = CGPoint(x: cf.maxX, y: cy); sDir = 1
            end = CGPoint(x: pf.minX, y: py); eDir = -1
        } else if cf.minX > pf.maxX + 2 * stub {
            start = CGPoint(x: cf.minX, y: cy); sDir = -1
            end = CGPoint(x: pf.maxX, y: py); eDir = 1
        } else {
            // horizontally overlapping: leave from the same side (whichever is closer), loop around
            let rightSide = cf.midX >= pf.midX
            if rightSide {
                start = CGPoint(x: cf.maxX, y: cy); sDir = 1
                end = CGPoint(x: pf.maxX, y: py); eDir = 1
            } else {
                start = CGPoint(x: cf.minX, y: cy); sDir = -1
                end = CGPoint(x: pf.minX, y: py); eDir = -1
            }
        }
        let ss = CGPoint(x: start.x + sDir * stub, y: start.y)
        let es = CGPoint(x: end.x + eDir * stub, y: end.y)
        let dx = abs(es.x - ss.x)
        let pull = max(50, min(220, dx * 0.5 + (sDir == eDir ? 60 : 0)))
        return ERDEdgeShape(relation: r, start: start, startStub: ss,
                            c1: CGPoint(x: ss.x + sDir * pull, y: ss.y), c2: CGPoint(x: es.x + eDir * pull, y: es.y),
                            endStub: es, end: end, symbols: symbols(r, start: start, sDir: sDir, end: end, eDir: eDir))
    }

    /// Crow's-foot notation. Child end: "many" (crow's foot) or "one" (bar) plus optionality circle;
    /// parent end: "one" (double bar) or "zero or one" (bar + circle) when the FK is nullable.
    static func symbols(_ r: ERDRelation, start: CGPoint, sDir: CGFloat, end: CGPoint, eDir: CGFloat) -> [ERDPrimitive] {
        var out: [ERDPrimitive] = []
        func bar(_ p: CGPoint, _ dir: CGFloat, at d: CGFloat) {
            out.append(.line(CGPoint(x: p.x + dir * d, y: p.y - 6), CGPoint(x: p.x + dir * d, y: p.y + 6)))
        }
        func circle(_ p: CGPoint, _ dir: CGFloat, at d: CGFloat) {
            out.append(.circle(CGPoint(x: p.x + dir * d, y: p.y), 3.5))
        }
        // child side
        if r.oneToOne {
            bar(start, sDir, at: 7)
            circle(start, sDir, at: 14)
        } else {
            let foot = CGPoint(x: start.x + sDir * 10, y: start.y)
            out.append(.line(foot, CGPoint(x: start.x, y: start.y - 6)))
            out.append(.line(foot, CGPoint(x: start.x, y: start.y + 6)))
            out.append(.line(foot, start))
            circle(start, sDir, at: 14.5)
        }
        // parent side
        bar(end, eDir, at: 7)
        if r.optional { circle(end, eDir, at: 13.5) } else { bar(end, eDir, at: 12) }
        return out
    }
}

// MARK: - Automatic layout

enum ERDAutoLayout {
    /// Layered left-to-right layout: referenced (parent) tables to the left of the tables that reference them,
    /// barycentric ordering to reduce crossings, components packed into shelves, isolated tables in a grid.
    static func layout(_ g: ERDGraph, options: ERDOptions) -> [String: CGPoint] {
        let sizes = Dictionary(uniqueKeysWithValues: g.tables.map { ($0.id, ERDTableBox.make($0, options: options).size) })
        let ids = g.tables.map(\.id)
        var parents: [String: Set<String>] = [:]
        var children: [String: Set<String>] = [:]
        for r in g.relations where r.fromTable != r.toTable && sizes[r.fromTable] != nil && sizes[r.toTable] != nil {
            parents[r.fromTable, default: []].insert(r.toTable)
            children[r.toTable, default: []].insert(r.fromTable)
        }
        // connected components
        var comp: [String: Int] = [:]
        var comps: [[String]] = []
        for id in ids where comp[id] == nil {
            var stack = [id]
            var members: [String] = []
            comp[id] = comps.count
            while let n = stack.popLast() {
                members.append(n)
                for m in parents[n, default: []].union(children[n, default: []]) where comp[m] == nil {
                    comp[m] = comps.count
                    stack.append(m)
                }
            }
            comps.append(members)
        }
        let hGap: CGFloat = 110, vGap: CGFloat = 36

        var blocks: [(size: CGSize, positions: [String: CGPoint])] = []
        var singles: [String] = []
        for members in comps {
            if members.count == 1 && parents[members[0]] == nil && children[members[0]] == nil {
                singles.append(members[0])
                continue
            }
            // depth = longest path to a root parent (cycles broken by the visiting set)
            var depth: [String: Int] = [:]
            var visiting: Set<String> = []
            func d(_ n: String) -> Int {
                if let v = depth[n] { return v }
                if visiting.contains(n) { return 0 }
                visiting.insert(n)
                let v = (parents[n] ?? []).map { d($0) + 1 }.max() ?? 0
                visiting.remove(n)
                depth[n] = v
                return v
            }
            members.forEach { _ = d($0) }
            // Pull referenced tables right, next to the tables that use them, so edges
            // don't have to cross intermediate layers (e.g. a lookup table used deep in a chain).
            for _ in 0..<3 {
                for n in members {
                    guard let kids = children[n], !kids.isEmpty else { continue }
                    let closest = kids.compactMap { depth[$0] }.min() ?? 0
                    let ownMin = (parents[n] ?? []).compactMap { depth[$0] }.max().map { $0 + 1 } ?? 0
                    let target = max(ownMin, closest - 1)
                    if target > depth[n]! { depth[n] = target }
                }
            }
            let maxDepth = depth.values.max() ?? 0
            var layers: [[String]] = Array(repeating: [], count: maxDepth + 1)
            for n in members.sorted() { layers[depth[n]!].append(n) }
            // barycenter sweeps
            for sweep in 0..<6 {
                let range: [Int] = sweep % 2 == 0 ? Array(1..<layers.count) : Array((0..<max(0, layers.count - 1)).reversed())
                for li in range where li >= 0 && li < layers.count {
                    var index: [String: Double] = [:]
                    for l in layers { for (i, n) in l.enumerated() { index[n] = Double(i) } }
                    let neighborLayer = sweep % 2 == 0 ? li - 1 : li + 1
                    guard neighborLayer >= 0, neighborLayer < layers.count else { continue }
                    let neighborSet = Set(layers[neighborLayer])
                    layers[li].sort { a, b in
                        func bary(_ n: String) -> Double {
                            let ns = parents[n, default: []].union(children[n, default: []]).filter { neighborSet.contains($0) }
                            if ns.isEmpty { return index[n] ?? 0 }
                            return ns.map { index[$0] ?? 0 }.reduce(0, +) / Double(ns.count)
                        }
                        let ba = bary(a), bb = bary(b)
                        return ba == bb ? a < b : ba < bb
                    }
                }
            }
            // coordinates
            var pos: [String: CGPoint] = [:]
            var x: CGFloat = 0
            let layerHeights = layers.map { l in l.map { sizes[$0]!.height }.reduce(0, +) + vGap * CGFloat(max(0, l.count - 1)) }
            let maxH = layerHeights.max() ?? 0
            for (li, l) in layers.enumerated() {
                let w = l.map { sizes[$0]!.width }.max() ?? 0
                var y = (maxH - layerHeights[li]) / 2
                for n in l {
                    let s = sizes[n]!
                    pos[n] = CGPoint(x: x + (w - s.width) / 2, y: y)
                    y += s.height + vGap
                }
                x += w + hGap
            }
            blocks.append((CGSize(width: x - hGap, height: maxH), pos))
        }
        // isolated tables as a grid block
        if !singles.isEmpty {
            let sorted = singles.sorted()
            let cols = max(1, Int(ceil(sqrt(Double(sorted.count) * 1.6))))
            var pos: [String: CGPoint] = [:]
            var colWidths = Array(repeating: CGFloat(0), count: cols)
            for (i, n) in sorted.enumerated() { colWidths[i % cols] = max(colWidths[i % cols], sizes[n]!.width) }
            var rowY: CGFloat = 0
            var i = 0
            while i < sorted.count {
                let row = sorted[i..<min(sorted.count, i + cols)]
                var x: CGFloat = 0
                var rowH: CGFloat = 0
                for (j, n) in row.enumerated() {
                    pos[n] = CGPoint(x: x, y: rowY)
                    x += colWidths[j] + 50
                    rowH = max(rowH, sizes[n]!.height)
                }
                rowY += rowH + 40
                i += cols
            }
            blocks.append((CGSize(width: colWidths.reduce(0, +) + 50 * CGFloat(cols - 1), height: rowY - 40), pos))
        }
        // shelf-pack blocks (largest first)
        let order = blocks.indices.sorted { blocks[$0].size.width * blocks[$0].size.height > blocks[$1].size.width * blocks[$1].size.height }
        let maxRow = max(2400, blocks.map(\.size.width).max() ?? 0)
        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, shelfH: CGFloat = 0
        let margin: CGFloat = 60, gap: CGFloat = 140
        for bi in order {
            let b = blocks[bi]
            if x > 0 && x + b.size.width > maxRow {
                x = 0
                y += shelfH + gap
                shelfH = 0
            }
            for (id, p) in b.positions { result[id] = CGPoint(x: margin + x + p.x, y: margin + y + p.y) }
            x += b.size.width + gap
            shelfH = max(shelfH, b.size.height)
        }
        return result
    }
}
