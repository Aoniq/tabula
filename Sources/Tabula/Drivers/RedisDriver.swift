import Foundation

/// Minimal RESP2 client. Keys appear as browsable objects; the query editor accepts
/// one Redis command per line (e.g. `HGETALL user:1`).
final class RedisDriver: DatabaseDriver {
    indirect enum Reply {
        case simple(String)
        case error(String)
        case integer(Int)
        case bulk(Data?)
        case array([Reply]?)

        var text: String? {
            switch self {
            case .simple(let s): return s
            case .error(let s): return "(error) " + s
            case .integer(let i): return String(i)
            case .bulk(let d): return d.map { String(data: $0, encoding: .utf8) ?? $0.hexString }
            case .array(let a): return a.map { "[" + $0.map { $0.text ?? "(nil)" }.joined(separator: ", ") + "]" }
            }
        }
        var strings: [String?] {
            if case .array(let a) = self { return (a ?? []).map { $0.text } }
            return [text]
        }
    }

    let dialect = SQLDialect(family: .redis)
    private let config: ConnectionConfig
    private let password: String
    private let host: String
    private let port: Int
    private var fd: Int32 = -1
    private var buffer = [UInt8]()
    private var bufferPos = 0
    private(set) var currentDatabase = "0"

    init(config: ConnectionConfig, password: String, host: String, port: Int) {
        self.config = config
        self.password = password
        self.host = host
        self.port = port
        if let n = Int(config.database) { currentDatabase = String(n) }
    }

    deinit { close() }

    func connect() throws {
        close()
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw DBError("Cannot resolve host \(host)")
        }
        defer { freeaddrinfo(res) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        var lastErr = "Connection refused"
        while let ai = ptr {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    fd = s
                    break
                }
                lastErr = String(cString: strerror(errno))
                Darwin.close(s)
            }
            ptr = ai.pointee.ai_next
        }
        guard fd >= 0 else { throw DBError("Redis: \(lastErr)") }
        if !password.isEmpty {
            let args = config.user.isEmpty ? ["AUTH", password] : ["AUTH", config.user, password]
            if case .error(let e) = try command(args) { throw DBError(e) }
        }
        if currentDatabase != "0" {
            if case .error(let e) = try command(["SELECT", currentDatabase]) { throw DBError(e) }
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buffer.removeAll()
        bufferPos = 0
    }

    func cancel() {}

    // MARK: RESP

    func command(_ args: [String]) throws -> Reply {
        guard fd >= 0 else { throw DBError("Not connected") }
        var out = "*\(args.count)\r\n"
        for a in args { out += "$\(a.utf8.count)\r\n\(a)\r\n" }
        let bytes = Array(out.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { close(); throw DBError("Redis connection lost") }
            sent += n
        }
        return try readReply()
    }

    private func fill() throws {
        if bufferPos > 0 && bufferPos == buffer.count { buffer.removeAll(keepingCapacity: true); bufferPos = 0 }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 65536, 0) }
        if n <= 0 { close(); throw DBError("Redis connection lost") }
        buffer.append(contentsOf: chunk[0..<n])
    }

    private func readLine() throws -> String {
        while true {
            if let idx = buffer[bufferPos...].firstIndex(of: 13), idx + 1 < buffer.count, buffer[idx + 1] == 10 {
                let line = String(decoding: buffer[bufferPos..<idx], as: UTF8.self)
                bufferPos = idx + 2
                return line
            }
            try fill()
        }
    }

    private func readBytes(_ count: Int) throws -> Data {
        while buffer.count - bufferPos < count + 2 { try fill() }
        let d = Data(buffer[bufferPos..<(bufferPos + count)])
        bufferPos += count + 2
        return d
    }

    private func readReply() throws -> Reply {
        let line = try readLine()
        guard let prefix = line.first else { throw DBError("Bad Redis reply") }
        let rest = String(line.dropFirst())
        switch prefix {
        case "+": return .simple(rest)
        case "-": return .error(rest)
        case ":": return .integer(Int(rest) ?? 0)
        case "$":
            let len = Int(rest) ?? -1
            return len < 0 ? .bulk(nil) : .bulk(try readBytes(len))
        case "*":
            let len = Int(rest) ?? -1
            if len < 0 { return .array(nil) }
            var items: [Reply] = []
            items.reserveCapacity(len)
            for _ in 0..<len { items.append(try readReply()) }
            return .array(items)
        default:
            throw DBError("Unexpected Redis reply: \(line)")
        }
    }

    /// Split a command line into arguments, honouring single/double quotes.
    static func parseArgs(_ line: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var quote: Character?
        var hasToken = false
        var escape = false
        for ch in line {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" && quote == "\"" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { args.append(cur); cur = ""; hasToken = false }
            } else {
                cur.append(ch); hasToken = true
            }
        }
        if hasToken { args.append(cur) }
        return args
    }

    // MARK: DatabaseDriver

    func serverVersion() -> String {
        guard let info = try? command(["INFO", "server"]).text else { return "Redis" }
        let v = info.split(whereSeparator: \.isNewline).first { $0.hasPrefix("redis_version:") }
        return "Redis " + (v.map { String($0.dropFirst("redis_version:".count)) } ?? "")
    }

    func execute(_ sql: String) throws -> [QueryResult] {
        var results: [QueryResult] = []
        for raw in sql.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("--") { continue }
            let args = RedisDriver.parseArgs(line.hasSuffix(";") ? String(line.dropLast()) : line)
            guard !args.isEmpty else { continue }
            let start = Date()
            let reply = try command(args)
            var r = QueryResult()
            r.statement = line
            switch reply {
            case .error(let e):
                throw DBError(e)
            case .array(let items):
                r.columns = [ResultColumn(name: "#", typeName: "int"), ResultColumn(name: "value", typeName: "")]
                r.rows = (items ?? []).enumerated().map { [String($0.offset + 1), $0.element.text] }
            case .integer(let i):
                r.columns = [ResultColumn(name: "integer", typeName: "int")]
                r.rows = [[String(i)]]
            default:
                r.columns = [ResultColumn(name: "result", typeName: "")]
                r.rows = [[reply.text]]
            }
            if args[0].uppercased() == "SELECT", args.count > 1 { currentDatabase = args[1] }
            r.duration = Date().timeIntervalSince(start)
            results.append(r)
        }
        return results
    }

    func listDatabases() throws -> [String] {
        if case .array(let a) = try command(["CONFIG", "GET", "databases"]), let a, a.count == 2, let n = Int(a[1].text ?? "") {
            return (0..<n).map(String.init)
        }
        return ["0"]
    }

    func useDatabase(_ name: String) throws {
        if case .error(let e) = try command(["SELECT", name]) { throw DBError(e) }
        currentDatabase = name
    }

    func listSchemas() throws -> [String] { [] }
    func defaultSchema() -> String? { nil }

    func listObjects(schema: String?) throws -> [DBObject] {
        var keys: [String] = []
        var cursor = "0"
        repeat {
            guard case .array(let a) = try command(["SCAN", cursor, "COUNT", "1000"]), let a, a.count == 2 else { break }
            cursor = a[0].text ?? "0"
            keys += a[1].strings.compactMap { $0 }
        } while cursor != "0" && keys.count < 20000
        return keys.sorted().map { DBObject(schema: nil, name: $0, kind: .table) }
    }

    private func type(of key: String) throws -> String {
        try command(["TYPE", key]).text ?? "none"
    }

    func columns(of o: DBObject) throws -> [ColumnInfo] {
        let names: [String]
        switch try type(of: o.name) {
        case "hash": names = ["field", "value"]
        case "list": names = ["index", "value"]
        case "set": names = ["member"]
        case "zset": names = ["member", "score"]
        case "stream": names = ["id", "fields"]
        default: names = ["value"]
        }
        return names.enumerated().map { ColumnInfo(name: $0.element, type: "", nullable: true, defaultValue: nil, isPrimaryKey: $0.offset == 0) }
    }

    func indexes(of o: DBObject) throws -> [IndexInfo] { [] }
    func foreignKeys(of o: DBObject) throws -> [ForeignKeyInfo] { [] }

    func ddl(of o: DBObject) throws -> String {
        let t = try type(of: o.name)
        let ttl = try command(["TTL", o.name]).text ?? "-1"
        let mem = (try? command(["MEMORY", "USAGE", o.name]).text) ?? nil
        return "# key: \(o.name)\n# type: \(t)\n# ttl: \(ttl == "-1" ? "none" : ttl + "s")\(mem.map { "\n# memory: \($0) bytes" } ?? "")"
    }

    func browse(_ o: DBObject, columns: [String], filters: [FilterRule], sort: [SortKey], limit: Int, offset: Int) throws -> QueryResult {
        var r = QueryResult()
        let key = o.name
        let t = try type(of: key)
        var rows: [[String?]] = []
        switch t {
        case "string":
            rows = [[try command(["GET", key]).text]]
        case "hash":
            let flat = try command(["HGETALL", key]).strings
            rows = stride(from: 0, to: flat.count - 1, by: 2).map { [flat[$0], flat[$0 + 1]] }
        case "list":
            rows = try command(["LRANGE", key, "0", "-1"]).strings.enumerated().map { [String($0.offset), $0.element] }
        case "set":
            rows = try command(["SMEMBERS", key]).strings.map { [$0] }
        case "zset":
            let flat = try command(["ZRANGE", key, "0", "-1", "WITHSCORES"]).strings
            rows = stride(from: 0, to: flat.count - 1, by: 2).map { [flat[$0], flat[$0 + 1]] }
        case "stream":
            if case .array(let entries) = try command(["XRANGE", key, "-", "+", "COUNT", "10000"]) {
                rows = (entries ?? []).map { e in
                    if case .array(let parts) = e, let parts, parts.count == 2 {
                        return [parts[0].text, parts[1].text]
                    }
                    return [e.text, nil]
                }
            }
        default:
            rows = []
        }
        let cols = try self.columns(of: o).map(\.name)
        r.columns = cols.map { ResultColumn(name: $0, typeName: t) }
        // local filtering / sorting
        for f in filters where f.enabled && !f.value.isEmpty {
            let idxs = f.column.isEmpty ? Array(cols.indices) : cols.indices.filter { cols[$0] == f.column }
            rows = rows.filter { row in idxs.contains { (row[$0] ?? "").localizedCaseInsensitiveContains(f.value) } }
        }
        if let s = sort.first, let ci = cols.firstIndex(of: s.column) {
            rows.sort { a, b in
                let x = a[ci] ?? "", y = b[ci] ?? ""
                if let dx = Double(x), let dy = Double(y) { return s.ascending ? dx < dy : dx > dy }
                return s.ascending ? x < y : x > y
            }
        }
        r.rows = Array(rows.dropFirst(offset).prefix(limit))
        r.statement = "\(t.uppercased()) \(key)"
        return r
    }

    func count(_ o: DBObject, columns: [String], filters: [FilterRule]) throws -> Int? {
        if filters.contains(where: { $0.enabled && !$0.value.isEmpty }) {
            return try browse(o, columns: columns, filters: filters, sort: [], limit: Int.max, offset: 0).rows.count
        }
        let cmd: [String]
        switch try type(of: o.name) {
        case "hash": cmd = ["HLEN", o.name]
        case "list": cmd = ["LLEN", o.name]
        case "set": cmd = ["SCARD", o.name]
        case "zset": cmd = ["ZCARD", o.name]
        case "stream": cmd = ["XLEN", o.name]
        default: return 1
        }
        return Int(try command(cmd).text ?? "")
    }
}
