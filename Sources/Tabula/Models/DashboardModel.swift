import Foundation

// Pure-Foundation model layer for the metrics board: tile definitions, persistence,
// value parsing/formatting and the result -> chart data transformation.
// Kept free of SwiftUI/AppKit so it can be exercised in isolation.

// MARK: - Tile definition

enum DashboardTileKind: String, Codable, CaseIterable, Identifiable {
    case number, table, bar, line, area, pie

    var id: String { rawValue }

    var label: String {
        switch self {
        case .number: return "Number"
        case .table: return "Table"
        case .bar: return "Bar"
        case .line: return "Line"
        case .area: return "Area"
        case .pie: return "Donut"
        }
    }

    var symbol: String {
        switch self {
        case .number: return "number"
        case .table: return "tablecells"
        case .bar: return "chart.bar.xaxis"
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.line.uptrend.xyaxis"
        case .pie: return "chart.pie"
        }
    }

    var isChart: Bool { [.bar, .line, .area, .pie].contains(self) }
    /// Kinds whose mapping supports several y columns / a series column.
    var supportsSeries: Bool { [.bar, .line, .area].contains(self) }
}

enum DashboardValueFormat: String, Codable, CaseIterable, Identifiable {
    case auto, number, bytes, percent, seconds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .number: return "Number (full)"
        case .bytes: return "Bytes"
        case .percent: return "Percent (0–100)"
        case .seconds: return "Duration (seconds)"
        }
    }
}

struct DashboardTile: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var sql: String
    var kind: DashboardTileKind
    /// Grid columns spanned: 1 (normal) or 2 (wide).
    var width: Int = 1
    /// x / label column; nil = auto-detect.
    var xColumn: String?
    /// y / value columns; empty = auto-detect (all numeric columns).
    var yColumns: [String] = []
    /// Optional column whose values split the data into series (long format).
    var seriesColumn: String?
    var format: DashboardValueFormat = .auto

    init(id: UUID = UUID(), title: String, sql: String, kind: DashboardTileKind, width: Int = 1,
         xColumn: String? = nil, yColumns: [String] = [], seriesColumn: String? = nil, format: DashboardValueFormat = .auto) {
        self.id = id
        self.title = title
        self.sql = sql
        self.kind = kind
        self.width = width
        self.xColumn = xColumn
        self.yColumns = yColumns
        self.seriesColumn = seriesColumn
        self.format = format
    }

    // Tolerant decoding so older/hand-edited files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        sql = try c.decodeIfPresent(String.self, forKey: .sql) ?? ""
        kind = (try? c.decodeIfPresent(DashboardTileKind.self, forKey: .kind)) ?? .table
        width = min(2, max(1, try c.decodeIfPresent(Int.self, forKey: .width) ?? 1))
        xColumn = try c.decodeIfPresent(String.self, forKey: .xColumn)
        yColumns = try c.decodeIfPresent([String].self, forKey: .yColumns) ?? []
        seriesColumn = try c.decodeIfPresent(String.self, forKey: .seriesColumn)
        format = (try? c.decodeIfPresent(DashboardValueFormat.self, forKey: .format)) ?? .auto
    }
}

enum DashboardRefreshInterval: Int, Codable, CaseIterable, Identifiable {
    case off = 0, s10 = 10, s30 = 30, m1 = 60, m5 = 300

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .s10: return "10s"
        case .s30: return "30s"
        case .m1: return "1m"
        case .m5: return "5m"
        }
    }
}

/// On-disk document: one per connection.
struct DashboardDocument: Codable, Equatable {
    var version = 1
    var refreshInterval: DashboardRefreshInterval = .off
    var tiles: [DashboardTile] = []

    init(refreshInterval: DashboardRefreshInterval = .off, tiles: [DashboardTile] = []) {
        self.refreshInterval = refreshInterval
        self.tiles = tiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        refreshInterval = (try? c.decodeIfPresent(DashboardRefreshInterval.self, forKey: .refreshInterval)) ?? .off
        tiles = try c.decodeIfPresent([DashboardTile].self, forKey: .tiles) ?? []
    }
}

// MARK: - Persistence

enum DashboardStore {
    /// `<base>/dashboards/<connection-uuid>.json`
    static func fileURL(connectionID: UUID, base: URL) -> URL {
        base.appendingPathComponent("dashboards", isDirectory: true)
            .appendingPathComponent(connectionID.uuidString.lowercased() + ".json")
    }

    static func load(connectionID: UUID, base: URL) -> DashboardDocument? {
        guard let data = try? Data(contentsOf: fileURL(connectionID: connectionID, base: base)) else { return nil }
        return try? JSONDecoder().decode(DashboardDocument.self, from: data)
    }

    static func save(_ doc: DashboardDocument, connectionID: UUID, base: URL) throws {
        let url = fileURL(connectionID: connectionID, base: base)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(doc).write(to: url, options: .atomic)
    }
}

// MARK: - Parsing

enum DashboardParse {
    /// Lenient number parsing: plain numbers, grouping commas, leading currency and trailing %.
    static func number(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = Double(s), d.isFinite { return d }
        if s.hasSuffix("%") { s.removeLast() }
        if let f = s.first, "$€£¥".contains(f) { s.removeFirst() }
        s = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if s.lowercased() == "nan" || s.lowercased().contains("inf") { return nil }
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }

    private static let dateRegex = try! NSRegularExpression(pattern:
        #"^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#)

    /// Parses ISO-8601-ish database timestamps: `2024-01-05`, `2024-01`, `2024-01-05 12:34:56.123+00`,
    /// `2024-01-05T12:34:56Z`. Values without an offset are interpreted in the local time zone.
    static func date(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), s.count >= 7, s.count <= 40,
              s.first?.isNumber == true else { return nil }
        let ns = s as NSString
        guard let m = dateRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func part(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        var dc = DateComponents()
        dc.year = Int(part(1)!)
        dc.month = Int(part(2)!)
        dc.day = part(3).flatMap(Int.init) ?? 1
        dc.hour = part(4).flatMap(Int.init) ?? 0
        dc.minute = part(5).flatMap(Int.init) ?? 0
        dc.second = part(6).flatMap(Int.init) ?? 0
        guard let mo = dc.month, (1...12).contains(mo), let d = dc.day, (1...31).contains(d),
              let h = dc.hour, h < 24, let mi = dc.minute, mi < 60 else { return nil }
        if let frac = part(7) {
            let digits = String(frac.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            dc.nanosecond = Int(digits)
        }
        var cal = Calendar(identifier: .gregorian)
        if let tz = part(8) {
            if tz == "Z" {
                cal.timeZone = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = tz.hasPrefix("-") ? -1 : 1
                let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
                let hh = Int(digits.prefix(2)) ?? 0
                let mm = digits.count >= 4 ? Int(digits.suffix(2)) ?? 0 : 0
                cal.timeZone = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60)) ?? .current
            }
        } else {
            cal.timeZone = .current
        }
        return cal.date(from: dc)
    }
}

// MARK: - Formatting

enum DashboardFormatter {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    private static let oneDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()

    /// Format a value for display. `compact` abbreviates large numbers (12.9K, 4.2M).
    static func string(_ v: Double, format: DashboardValueFormat, compact: Bool = true) -> String {
        switch format {
        case .bytes:
            return bytes(v)
        case .percent:
            return (oneDecimal.string(from: NSNumber(value: v)) ?? "\(v)") + "%"
        case .seconds:
            return duration(v)
        case .number:
            return grouped.string(from: NSNumber(value: v)) ?? "\(v)"
        case .auto:
            return compact ? compactNumber(v) : (grouped.string(from: NSNumber(value: v)) ?? "\(v)")
        }
    }

    /// 1,284 · 12.9K · 4.2M · 1.1B — full figures under 10,000.
    static func compactNumber(_ v: Double) -> String {
        let a = abs(v)
        if a < 10_000 { return grouped.string(from: NSNumber(value: v)) ?? "\(v)" }
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where a >= scale {
            return (oneDecimal.string(from: NSNumber(value: v / scale)) ?? "\(v / scale)") + suffix
        }
        return grouped.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var x = abs(v)
        var i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        let sign = v < 0 ? "-" : ""
        if i == 0 { return "\(sign)\(Int(x)) B" }
        return sign + (oneDecimal.string(from: NSNumber(value: x)) ?? "\(x)") + " " + units[i]
    }

    static func duration(_ s: Double) -> String {
        let a = abs(s)
        if a < 1 { return "\(Int((s * 1000).rounded())) ms" }
        if a < 60 { return (oneDecimal.string(from: NSNumber(value: s)) ?? "\(s)") + " s" }
        let total = Int(a.rounded())
        let (h, m, sec) = (total / 3600, (total % 3600) / 60, total % 60)
        let sign = s < 0 ? "-" : ""
        if h >= 24 { return "\(sign)\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(sign)\(h)h \(m)m" }
        return "\(sign)\(m)m \(sec)s"
    }
}

// MARK: - Column profiling

enum DashboardColumnType: Equatable {
    case number, date, text, empty
}

enum DashboardProfiler {
    /// Classify a column by sampling up to `sample` non-null values.
    static func type(ofColumn index: Int, rows: [[String?]], sample: Int = 200) -> DashboardColumnType {
        var seen = 0
        var allNumber = true
        var allDate = true
        for r in rows {
            guard index < r.count, let v = r[index], !v.isEmpty else { continue }
            seen += 1
            if allNumber && DashboardParse.number(v) == nil { allNumber = false }
            if allDate && DashboardParse.date(v) == nil { allDate = false }
            if (!allNumber && !allDate) || seen >= sample { break }
        }
        if seen == 0 { return .empty }
        // Dates first: "2024-01" is not a number anyway, and year-only values stay numeric.
        if allDate { return .date }
        if allNumber { return .number }
        return .text
    }

    static func types(columns: [String], rows: [[String?]]) -> [DashboardColumnType] {
        columns.indices.map { type(ofColumn: $0, rows: rows) }
    }
}

// MARK: - KPI

struct DashboardKPI: Equatable {
    var value: String
    var numeric: Double?
    var caption: String?

    static func make(columns: [String], rows: [[String?]], format: DashboardValueFormat) -> DashboardKPI {
        guard let first = rows.first, !first.isEmpty else { return DashboardKPI(value: "—", numeric: nil, caption: "No rows") }
        let raw = first[0]
        let caption: String? = first.count > 1 ? (first[1] ?? nil) : nil
        guard let raw else { return DashboardKPI(value: "NULL", numeric: nil, caption: caption) }
        if let n = DashboardParse.number(raw) {
            return DashboardKPI(value: DashboardFormatter.string(n, format: format), numeric: n, caption: caption)
        }
        return DashboardKPI(value: raw, numeric: nil, caption: caption)
    }
}

// MARK: - Chart data

enum DashboardXKind: Equatable { case date, number, text }

struct DashboardPoint: Identifiable, Equatable {
    let id: Int
    let xText: String
    let xDate: Date?
    let xNumber: Double?
    let y: Double
    let series: String
}

struct DashboardChartData {
    var xColumn: String?
    var yColumns: [String] = []
    var seriesColumn: String?
    var xKind: DashboardXKind = .text
    var points: [DashboardPoint] = []
    /// Series names in colour-slot order (stable: column order, or alphabetical for a series column).
    var series: [String] = []
    /// Category order for text x values (query order).
    var categories: [String] = []
    var totalRows = 0
    /// Rows dropped/sampled because of the point cap.
    var truncated = false
    var droppedSeries = 0
    var skippedValues = 0
    var error: String?

    var isMultiSeries: Bool { series.count > 1 }

    static let maxPoints = 500
    static let maxBarCategories = 50
    static let maxSeries = 8
    static let maxSlices = 6

    /// Resolve the effective mapping for a tile against a result, applying auto-detection.
    static func resolveMapping(columns: [String], types: [DashboardColumnType], tile: DashboardTile)
        -> (x: Int?, ys: [Int], series: Int?) {
        func idx(_ name: String?) -> Int? { name.flatMap { n in columns.firstIndex(of: n) } }
        var x = idx(tile.xColumn)
        if x == nil {
            x = types.firstIndex { $0 == .text || $0 == .date }
            if x == nil && columns.count >= 2 { x = 0 }
        }
        var series = tile.kind.supportsSeries ? idx(tile.seriesColumn) : nil
        if series == x { series = nil }
        var ys = tile.yColumns.compactMap { idx($0) }.filter { $0 != x && $0 != series }
        if ys.isEmpty {
            ys = types.indices.filter { types[$0] == .number && $0 != x && $0 != series }
        }
        if series != nil || tile.kind == .pie { ys = Array(ys.prefix(1)) }
        return (x, ys, series)
    }

    static func make(columns: [String], rows: [[String?]], tile: DashboardTile) -> DashboardChartData {
        var out = DashboardChartData()
        out.totalRows = rows.count
        let types = DashboardProfiler.types(columns: columns, rows: rows)
        let map = resolveMapping(columns: columns, types: types, tile: tile)
        out.xColumn = map.x.map { columns[$0] }
        out.yColumns = map.ys.map { columns[$0] }
        out.seriesColumn = map.series.map { columns[$0] }
        guard !map.ys.isEmpty else {
            out.error = "No numeric column to plot. Return at least one numeric column, or pick a value column."
            return out
        }

        switch tile.kind {
        case .line, .area:
            if let x = map.x { out.xKind = types[x] == .date ? .date : (types[x] == .number ? .number : .text) }
        default:
            out.xKind = .text
        }

        // Cap the rows considered.
        var work = rows
        let rowCap: Int
        switch tile.kind {
        case .bar: rowCap = map.series == nil ? maxBarCategories : maxPoints
        case .pie: rowCap = 10_000
        default: rowCap = maxPoints
        }
        if tile.kind == .line || tile.kind == .area, work.count > rowCap, map.series == nil {
            // Even down-sampling keeps the shape of a long time series; always keep the last row.
            let step = Double(work.count - 1) / Double(rowCap - 1)
            work = (0..<rowCap).map { rows[Int((Double($0) * step).rounded())] }
            out.truncated = true
        } else if work.count > rowCap {
            work = Array(work.prefix(rowCap))
            out.truncated = true
        }

        func cell(_ r: [String?], _ i: Int?) -> String? {
            guard let i, i < r.count else { return nil }
            return r[i]
        }

        var raw: [(xText: String, xDate: Date?, xNum: Double?, y: Double, series: String)] = []
        raw.reserveCapacity(work.count * map.ys.count)
        var categories: [String] = []
        var seenCat = Set<String>()
        for (rowIndex, r) in work.enumerated() {
            let xs: String
            var xd: Date?
            var xn: Double?
            if let x = map.x {
                let v = cell(r, x)
                switch out.xKind {
                case .date:
                    guard let d = DashboardParse.date(v) else { out.skippedValues += 1; continue }
                    xd = d
                    xs = v ?? ""
                case .number:
                    guard let n = DashboardParse.number(v) else { out.skippedValues += 1; continue }
                    xn = n
                    xs = v ?? ""
                case .text:
                    xs = v ?? "NULL"
                }
            } else {
                xs = "\(rowIndex + 1)"
                if out.xKind == .number { xn = Double(rowIndex + 1) }
            }
            if seenCat.insert(xs).inserted { categories.append(xs) }
            if let s = map.series {
                guard let y = DashboardParse.number(cell(r, map.ys[0])) else { out.skippedValues += 1; continue }
                raw.append((xs, xd, xn, y, cell(r, s) ?? "NULL"))
            } else {
                for yi in map.ys {
                    guard let y = DashboardParse.number(cell(r, yi)) else { out.skippedValues += 1; continue }
                    raw.append((xs, xd, xn, y, columns[yi]))
                }
            }
        }

        if tile.kind == .pie {
            // Aggregate by label, rank, fold the tail into "Other".
            var sums: [String: Double] = [:]
            for p in raw where p.y > 0 { sums[p.xText, default: 0] += p.y }
            var ranked = categories.filter { sums[$0] != nil }.map { ($0, sums[$0]!) }
            ranked.sort { $0.1 > $1.1 }
            if ranked.count > maxSlices {
                let head = ranked.prefix(maxSlices - 1)
                let tail = ranked.dropFirst(maxSlices - 1).reduce(0) { $0 + $1.1 }
                ranked = Array(head) + [("Other", tail)]
            }
            out.points = ranked.enumerated().map { i, e in
                DashboardPoint(id: i, xText: e.0, xDate: nil, xNumber: nil, y: e.1, series: e.0)
            }
            out.categories = ranked.map(\.0)
            // Colour follows the entity: slots in alphabetical order, "Other" last.
            out.series = ranked.map(\.0).filter { $0 != "Other" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                + (ranked.contains { $0.0 == "Other" } ? ["Other"] : [])
            if out.points.isEmpty { out.error = "No positive values to show." }
            return out
        }

        // Series order and cap.
        var seriesNames: [String]
        if map.series != nil {
            seriesNames = Array(Set(raw.map(\.series))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } else {
            seriesNames = map.ys.map { columns[$0] }
        }
        if seriesNames.count > maxSeries {
            var totals: [String: Double] = [:]
            for p in raw { totals[p.series, default: 0] += abs(p.y) }
            let keep = Set(seriesNames.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }.prefix(maxSeries))
            out.droppedSeries = seriesNames.count - keep.count
            seriesNames = seriesNames.filter { keep.contains($0) }
            raw = raw.filter { keep.contains($0.series) }
        }
        if map.series != nil && raw.count > maxPoints {
            raw = Array(raw.prefix(maxPoints))
            out.truncated = true
        }

        if out.xKind == .date {
            raw.sort { ($0.xDate ?? .distantPast) < ($1.xDate ?? .distantPast) }
        } else if out.xKind == .number {
            raw.sort { ($0.xNum ?? 0) < ($1.xNum ?? 0) }
        }

        out.series = seriesNames
        out.categories = categories
        out.points = raw.enumerated().map { i, p in
            DashboardPoint(id: i, xText: p.xText, xDate: p.xDate, xNumber: p.xNum, y: p.y, series: p.series)
        }
        if out.points.isEmpty { out.error = out.totalRows == 0 ? "The query returned no rows." : "No plottable values (all NULL?)." }
        return out
    }
}

// MARK: - Read-only guard

enum DashboardSQLGuard {
    /// Returns a user-facing reason when the SQL may not be used on a dashboard.
    static func problem(with sql: String, statements: [String], isWrite: (String) -> Bool) -> String? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a SELECT query." }
        if statements.contains(where: isWrite) {
            return "Dashboards are read-only: INSERT, UPDATE, DELETE, DDL and other write statements are not allowed. Use a SELECT query."
        }
        return nil
    }
}
