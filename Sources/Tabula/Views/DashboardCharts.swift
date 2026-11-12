import SwiftUI
import AppKit
import Charts

// MARK: - Theme

/// Chart palette and chrome for the metrics board. Light and dark steps are selected
/// separately (validated: adjacent CVD ΔE ≥ 8.4, normal-vision ΔE ≥ 19.3 in both modes).
enum DashboardTheme {
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: alpha)
        })
    }

    /// Categorical slots, assigned in fixed order — never cycled.
    static let series: [Color] = [
        dynamic(0x2a78d6, 0x3987e5), // blue
        dynamic(0xeb6834, 0xd95926), // orange
        dynamic(0x1baf7a, 0x199e70), // aqua
        dynamic(0xeda100, 0xc98500), // yellow
        dynamic(0xe87ba4, 0xd55181), // magenta
        dynamic(0x008300, 0x008300), // green
        dynamic(0x6250d6, 0x9085e9), // violet
        dynamic(0xe34948, 0xe66767), // red
    ]
    /// "Other" / folded tail.
    static let other = dynamic(0xb5b4ad, 0x5c5b56)

    static let surface = dynamic(0xfcfcfb, 0x1a1a19)
    static let plane = dynamic(0xf4f4f1, 0x0d0d0d)
    static let ink = dynamic(0x0b0b0b, 0xf0efec)
    static let inkSecondary = dynamic(0x52514e, 0xc3c2b7)
    static let muted = dynamic(0x898781, 0x898781)
    static let grid = dynamic(0xe1e0d9, 0x2c2c2a)
    static let baseline = dynamic(0xc3c2b7, 0x383835)
    static let border = dynamic(0x0b0b0b, 0xffffff, alpha: 0.10)
    static let critical = dynamic(0xd03b3b, 0xe66767)

    static func color(forSeries index: Int, name: String) -> Color {
        if name == "Other" { return other }
        return series[min(index, series.count - 1)]
    }

    static func colors(for names: [String]) -> [Color] {
        names.enumerated().map { color(forSeries: $0.offset, name: $0.element) }
    }
}

// MARK: - Shared pieces

struct DashboardLegend: View {
    let names: [String]
    var body: some View {
        DashboardFlowRow(spacing: 12) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DashboardTheme.color(forSeries: i, name: n))
                        .frame(width: 10, height: 10)
                    Text(n).font(.caption).foregroundStyle(DashboardTheme.inkSecondary).lineLimit(1)
                }
            }
        }
    }
}

/// Minimal wrapping row for legends.
struct DashboardFlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += sz.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

struct DashboardTooltip: View {
    let title: String
    let rows: [(name: String, color: Color, value: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(DashboardTheme.ink)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Circle().fill(r.color).frame(width: 8, height: 8)
                    Text(r.name).foregroundStyle(DashboardTheme.inkSecondary)
                    Spacer(minLength: 8)
                    Text(r.value).monospacedDigit().foregroundStyle(DashboardTheme.ink)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 120)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DashboardTheme.border))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

private func valueAxisMarks(_ format: DashboardValueFormat) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(DashboardTheme.grid)
        AxisValueLabel {
            if let d = value.as(Double.self) {
                Text(DashboardFormatter.string(d, format: format == .number ? .auto : format)).monospacedDigit()
                    .foregroundStyle(DashboardTheme.muted)
            }
        }
    }
}

// MARK: - Chart dispatcher

struct DashboardChart: View {
    let tile: DashboardTile
    let data: DashboardChartData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = data.error {
                DashboardMessage(symbol: "chart.bar.xaxis", text: err)
            } else {
                switch tile.kind {
                case .pie:
                    DashboardDonutChart(tile: tile, data: data)
                case .bar:
                    if data.isMultiSeries { DashboardLegend(names: data.series) }
                    DashboardBarChart(tile: tile, data: data)
                default:
                    if data.isMultiSeries { DashboardLegend(names: data.series) }
                    switch data.xKind {
                    case .date:
                        DashboardXYChart(tile: tile, data: data, xOf: { $0.xDate ?? .distantPast },
                                         distance: { abs($0.timeIntervalSince($1)) },
                                         label: { $0.formatted(date: .abbreviated, time: .shortened) })
                    case .number:
                        DashboardXYChart(tile: tile, data: data, xOf: { $0.xNumber ?? 0 },
                                         distance: { abs($0 - $1) },
                                         label: { DashboardFormatter.string($0, format: .number) })
                    case .text:
                        DashboardXYChart(tile: tile, data: data, xOf: { $0.xText },
                                         distance: { $0 == $1 ? 0 : 1 },
                                         label: { $0 })
                    }
                }
                footnote
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        let notes = footnotes
        if !notes.isEmpty {
            Text(notes.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(DashboardTheme.muted)
                .lineLimit(1)
        }
    }

    private var footnotes: [String] {
        var n: [String] = []
        if data.truncated {
            switch tile.kind {
            case .line, .area: n.append("Sampled to \(DashboardChartData.maxPoints) of \(data.totalRows.formatted()) rows")
            default: n.append("First \(data.categories.count) of \(data.totalRows.formatted()) rows")
            }
        }
        if data.droppedSeries > 0 { n.append("\(data.droppedSeries) smaller series hidden") }
        if data.skippedValues > 0 { n.append("\(data.skippedValues) NULL/non-numeric values skipped") }
        return n
    }
}

struct DashboardMessage: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(DashboardTheme.muted)
            Text(text).font(.callout).foregroundStyle(DashboardTheme.inkSecondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bar

/// Ranked horizontal bars; grouped by series when there are several.
struct DashboardBarChart: View {
    let tile: DashboardTile
    let data: DashboardChartData
    @State private var selected: String?

    private var xLabel: String { data.xColumn ?? "Row" }

    var body: some View {
        GeometryReader { geo in
            let bands = max(1, data.categories.count * (data.isMultiSeries ? data.series.count : 1))
            let thickness = min(20, max(2, (geo.size.height - 24) / CGFloat(bands) * 0.72))
            let labelValues = !data.isMultiSeries && data.categories.count <= 12
            let groupSpan = thickness * CGFloat(max(1, data.series.count)) + 2 * CGFloat(max(0, data.series.count - 1))
            Chart {
                ForEach(data.points) { p in
                    if data.isMultiSeries {
                        // Grouped: the group takes a share of the band; bars split it evenly.
                        BarMark(x: .value("Value", p.y), y: .value(xLabel, p.xText))
                            .foregroundStyle(by: .value("Series", p.series))
                            .position(by: .value("Series", p.series), axis: .vertical, span: .fixed(groupSpan))
                            .cornerRadius(3)
                            .opacity(selected == nil || selected == p.xText ? 1 : 0.45)
                    } else {
                        BarMark(x: .value("Value", p.y), y: .value(xLabel, p.xText), height: .fixed(thickness))
                            .foregroundStyle(by: .value("Series", p.series))
                            .cornerRadius(3)
                            .opacity(selected == nil || selected == p.xText ? 1 : 0.45)
                            .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                                if labelValues {
                                    Text(DashboardFormatter.string(p.y, format: tile.format))
                                        .font(.caption2).monospacedDigit()
                                        .foregroundStyle(DashboardTheme.inkSecondary)
                                }
                            }
                    }
                }
                if let s = selected, let rows = tooltipRows(s), !rows.isEmpty {
                    RuleMark(y: .value(xLabel, s))
                        .foregroundStyle(.clear)
                        .annotation(position: .automatic, alignment: .center, spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            DashboardTooltip(title: s, rows: rows)
                        }
                }
            }
            .chartForegroundStyleScale(domain: data.series, range: DashboardTheme.colors(for: data.series))
            .chartLegend(.hidden)
            .chartYScale(domain: data.categories)
            .chartXAxis { valueAxisMarks(tile.format) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let s = value.as(String.self) {
                            Text(s)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: geo.size.width * 0.32, alignment: .trailing)
                                .foregroundStyle(DashboardTheme.inkSecondary)
                        }
                    }
                }
            }
            .chartYSelection(value: $selected)
            .chartPlotStyle { $0.padding(.trailing, labelValues ? 44 : 0) }
        }
    }

    private func tooltipRows(_ category: String) -> [(name: String, color: Color, value: String)]? {
        let pts = data.points.filter { $0.xText == category }
        return pts.map { p in
            let i = data.series.firstIndex(of: p.series) ?? 0
            return (p.series, DashboardTheme.color(forSeries: i, name: p.series), DashboardFormatter.string(p.y, format: tile.format, compact: false))
        }
    }
}

// MARK: - Line / Area

struct DashboardXYChart<X: Plottable & Equatable>: View {
    let tile: DashboardTile
    let data: DashboardChartData
    let xOf: (DashboardPoint) -> X
    let distance: (X, X) -> Double
    let label: (X) -> String
    @State private var raw: X?

    private var xLabel: String { data.xColumn ?? "Row" }
    private var stacked: Bool { tile.kind == .area && data.isMultiSeries }

    /// Nearest real x to the hover position.
    private var snapped: X? {
        guard let raw else { return nil }
        var best: (X, Double)?
        for p in data.points {
            let x = xOf(p)
            let d = distance(x, raw)
            if best == nil || d < best!.1 { best = (x, d) }
            if d == 0 { break }
        }
        return best?.0
    }

    var body: some View {
        let sel = snapped
        Chart {
            ForEach(data.points) { p in
                if tile.kind == .area {
                    AreaMark(x: .value(xLabel, xOf(p)), y: .value("Value", p.y), stacking: stacked ? .standard : .unstacked)
                        .foregroundStyle(by: .value("Series", p.series))
                        .opacity(stacked ? 0.85 : 0.12)
                }
                if !stacked {
                    LineMark(x: .value(xLabel, xOf(p)), y: .value("Value", p.y))
                        .foregroundStyle(by: .value("Series", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            if let sel {
                RuleMark(x: .value(xLabel, sel))
                    .foregroundStyle(DashboardTheme.baseline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DashboardTooltip(title: label(sel), rows: rows(at: sel))
                    }
                if !stacked {
                    ForEach(data.points.filter { xOf($0) == sel }) { p in
                        PointMark(x: .value(xLabel, xOf(p)), y: .value("Value", p.y))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbolSize(70)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: data.series, range: DashboardTheme.colors(for: data.series))
        .chartLegend(.hidden)
        .chartYAxis { valueAxisMarks(tile.format) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisTick().foregroundStyle(DashboardTheme.baseline)
                AxisValueLabel().foregroundStyle(DashboardTheme.muted)
            }
        }
        .chartXSelection(value: $raw)
    }

    private func rows(at x: X) -> [(name: String, color: Color, value: String)] {
        data.points.filter { xOf($0) == x }.map { p in
            let i = data.series.firstIndex(of: p.series) ?? 0
            return (p.series, DashboardTheme.color(forSeries: i, name: p.series), DashboardFormatter.string(p.y, format: tile.format, compact: false))
        }
    }
}

// MARK: - Donut

struct DashboardDonutChart: View {
    let tile: DashboardTile
    let data: DashboardChartData
    @State private var angle: Double?

    private var total: Double { data.points.reduce(0) { $0 + $1.y } }

    private var selected: DashboardPoint? {
        guard let angle else { return nil }
        var acc = 0.0
        for p in data.points {
            acc += p.y
            if angle <= acc { return p }
        }
        return nil
    }

    private func color(_ p: DashboardPoint) -> Color {
        DashboardTheme.color(forSeries: data.series.firstIndex(of: p.series) ?? 0, name: p.series)
    }

    var body: some View {
        let sel = selected
        HStack(alignment: .center, spacing: 16) {
            Chart(data.points) { p in
                SectorMark(angle: .value("Value", p.y), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Slice", p.series))
                    .opacity(sel == nil || sel?.id == p.id ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: data.series, range: DashboardTheme.colors(for: data.series))
            .chartLegend(.hidden)
            .chartAngleSelection(value: $angle)
            .chartBackground { proxy in
                GeometryReader { geo in
                    if let anchor = proxy.plotFrame {
                        let frame = geo[anchor]
                        VStack(spacing: 1) {
                            Text(sel.map { DashboardFormatter.string($0.y, format: tile.format) } ?? DashboardFormatter.string(total, format: tile.format))
                                .font(.title3.weight(.semibold)).foregroundStyle(DashboardTheme.ink)
                            Text(sel?.xText ?? "Total")
                                .font(.caption).foregroundStyle(DashboardTheme.inkSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: frame.width * 0.55)
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.points) { p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(color(p)).frame(width: 10, height: 10)
                        Text(p.xText).foregroundStyle(DashboardTheme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(DashboardFormatter.string(p.y, format: tile.format)).monospacedDigit()
                            .foregroundStyle(DashboardTheme.inkSecondary)
                        Text(total > 0 ? (p.y / total).formatted(.percent.precision(.fractionLength(0))) : "")
                            .monospacedDigit().foregroundStyle(DashboardTheme.muted)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.caption)
                    .fontWeight(sel?.id == p.id ? .semibold : .regular)
                }
            }
            .frame(minWidth: 140, maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Number

struct DashboardNumberView: View {
    let kpi: DashboardKPI
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kpi.value)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(DashboardTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .textSelection(.enabled)
            if let c = kpi.caption, !c.isEmpty {
                Text(c).font(.callout).foregroundStyle(DashboardTheme.inkSecondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
