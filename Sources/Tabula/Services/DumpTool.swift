import Foundation

/// What a backup contains.
enum DumpContent: String, CaseIterable, Identifiable {
    case full = "Structure and data"
    case schema = "Structure only"
    case data = "Data only"
    var id: String { rawValue }
}

/// pg_dump output format.
enum PGDumpFormat: String, CaseIterable, Identifiable {
    case plain = "Plain SQL"
    case custom = "Custom archive (-Fc)"
    var id: String { rawValue }
    var fileExtension: String { self == .plain ? "sql" : "dump" }
}

/// Everything an external client tool needs to reach the database.
struct DumpConnection {
    var kind: DatabaseKind
    var host: String
    var port: Int
    var user: String
    var password: String
    var database: String
    var filePath: String
    var ssl: SSLConfig

    var family: DatabaseFamily { kind.family }

    /// Short human description of the target, e.g. "shop on 127.0.0.1:5432".
    var targetDescription: String {
        if family == .sqlite { return (filePath as NSString).lastPathComponent }
        return "\(database) on \(host):\(port)"
    }
}

extension DumpConnection {
    @MainActor
    init(_ ws: WorkspaceState) {
        let ep = ws.endpoint
        let db = ws.currentDatabase.isEmpty ? ws.config.database : ws.currentDatabase
        self.init(kind: ws.config.kind, host: ep.host, port: ep.port, user: ws.config.user, password: ws.connectionPassword,
                  database: db, filePath: ws.config.filePath, ssl: ws.config.ssl)
    }
}

/// A fully resolved external command.
struct ToolCommand {
    var executable: String
    var arguments: [String]
    var environment: [String: String] = [:]
    /// File fed to stdin.
    var stdinFile: URL?
    /// File that receives stdout (otherwise stdout is streamed to the log).
    var stdoutFile: URL?

    var toolName: String { (executable as NSString).lastPathComponent }

    /// Shell-like rendering for the log (passwords live only in the environment, never in args).
    var displayString: String {
        func q(_ s: String) -> String {
            s.isEmpty || s.contains(where: { " '\"$\\;&|<>()*?".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
        }
        var s = ([executable] + arguments).map(q).joined(separator: " ")
        if let i = stdinFile { s += " < " + q(i.path) }
        if let o = stdoutFile { s += " > " + q(o.path) }
        return s
    }
}

struct ToolNotFoundError: LocalizedError {
    var tool: String
    var errorDescription: String? {
        "\(tool) was not found. Set its location in Settings › Tools."
    }
}

enum DumpTool {
    // MARK: Tool lookup

    /// Path for a tool: the Settings › Tools value when it is executable, else auto-detected.
    static func path(for tool: String) -> String? {
        let key: String?
        switch tool {
        case "pg_dump": key = SettingsKey.pgDumpPath
        case "psql": key = SettingsKey.psqlPath
        case "mysqldump": key = SettingsKey.mysqldumpPath
        case "mysql": key = SettingsKey.mysqlPath
        case "sqlite3": key = SettingsKey.sqlite3Path
        default: key = nil
        }
        if let key {
            let p = Settings.path(key).trimmingCharacters(in: .whitespaces)
            if !p.isEmpty && FileManager.default.isExecutableFile(atPath: p) { return p }
            if !p.isEmpty { return nil }   // configured but broken: report rather than guess
        }
        if tool == "pg_restore" {
            // Prefer the pg_restore next to the configured pg_dump (same version).
            let dump = Settings.path(SettingsKey.pgDumpPath)
            if !dump.isEmpty {
                let sib = ((dump as NSString).deletingLastPathComponent as NSString).appendingPathComponent("pg_restore")
                if FileManager.default.isExecutableFile(atPath: sib) { return sib }
            }
        }
        return ToolLocator.find(tool)
    }

    static func requirePath(_ tool: String, lookup: (String) -> String? = path(for:)) throws -> String {
        guard let p = lookup(tool) else { throw ToolNotFoundError(tool: tool) }
        return p
    }

    /// Tools a backup/restore will need for a given family.
    static func backupTool(for family: DatabaseFamily) -> String? {
        switch family {
        case .postgres: return "pg_dump"
        case .mysql: return "mysqldump"
        case .sqlite: return "sqlite3"
        case .redis: return nil
        }
    }

    static func restoreTool(for family: DatabaseFamily, customArchive: Bool) -> String? {
        switch family {
        case .postgres: return customArchive ? "pg_restore" : "psql"
        case .mysql: return "mysql"
        case .sqlite: return "sqlite3"
        case .redis: return nil
        }
    }

    /// True when the MySQL-family client binary is MariaDB's (different SSL flags).
    static func isMariaDBClient(_ path: String) -> Bool {
        if (path as NSString).lastPathComponent.hasPrefix("mariadb") { return true }
        return clientVersionString(path).lowercased().contains("mariadb")
    }

    /// `tool --version` output (cached per path).
    static func clientVersionString(_ path: String) -> String {
        versionLock.lock()
        if let v = versionCache[path] { versionLock.unlock(); return v }
        versionLock.unlock()
        let v = runSync(ToolCommand(executable: path, arguments: ["--version"])).output
        versionLock.lock(); versionCache[path] = v; versionLock.unlock()
        return v
    }
    private static var versionCache: [String: String] = [:]
    private static let versionLock = NSLock()

    /// mysqldump 9.x queries INFORMATION_SCHEMA.LIBRARIES when dumping routines, which only exists on
    /// MySQL 9+ servers. Returns false when that combination would make the dump fail.
    static func mysqldumpCanDumpRoutines(clientVersion: String, serverVersion: String) -> Bool {
        let client = clientVersion.lowercased()
        guard !client.contains("mariadb") else { return true }
        func major(after marker: String?, in s: String) -> Int? {
            var text = Substring(s)
            if let marker, let r = s.range(of: marker) { text = s[r.upperBound...] }
            let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        guard let clientMajor = major(after: "ver ", in: client), clientMajor >= 9 else { return true }
        let server = serverVersion.lowercased()
        if server.contains("mariadb") { return false }
        guard let serverMajor = major(after: nil, in: server) else { return true }
        return serverMajor >= 9
    }

    /// pg_dump custom archives start with the magic "PGDMP".
    static func isPGCustomArchive(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 5)) ?? Data()
        return head == Data("PGDMP".utf8)
    }

    // MARK: Environment

    static func postgresEnvironment(_ c: DumpConnection) -> [String: String] {
        var env: [String: String] = ["PGPASSWORD": c.password, "PGSSLMODE": c.ssl.mode.rawValue, "PGCONNECT_TIMEOUT": "15", "PGAPPNAME": "Tabula"]
        if !c.ssl.caCertPath.isEmpty { env["PGSSLROOTCERT"] = c.ssl.caCertPath }
        if !c.ssl.clientCertPath.isEmpty { env["PGSSLCERT"] = c.ssl.clientCertPath }
        if !c.ssl.clientKeyPath.isEmpty { env["PGSSLKEY"] = c.ssl.clientKeyPath }
        return env
    }

    static func postgresConnArgs(_ c: DumpConnection) -> [String] {
        var a = ["--host=\(c.host)", "--port=\(c.port)"]
        if !c.user.isEmpty { a.append("--username=\(c.user)") }
        a.append("--no-password")
        return a
    }

    static func mysqlConnArgs(_ c: DumpConnection, mariaDBClient: Bool) -> [String] {
        var a = ["--host=\(c.host)", "--port=\(c.port)", "--protocol=TCP"]
        if !c.user.isEmpty { a.append("--user=\(c.user)") }
        if mariaDBClient {
            switch c.ssl.mode {
            case .disable: a.append("--skip-ssl")
            case .prefer: break
            case .require: a.append("--ssl")
            case .verifyCA, .verifyFull: a += ["--ssl", "--ssl-verify-server-cert"]
            }
        } else {
            switch c.ssl.mode {
            case .disable: a.append("--ssl-mode=DISABLED")
            case .prefer: break
            case .require: a.append("--ssl-mode=REQUIRED")
            case .verifyCA: a.append("--ssl-mode=VERIFY_CA")
            case .verifyFull: a.append("--ssl-mode=VERIFY_IDENTITY")
            }
        }
        if !c.ssl.caCertPath.isEmpty { a.append("--ssl-ca=\(c.ssl.caCertPath)") }
        if !c.ssl.clientCertPath.isEmpty { a.append("--ssl-cert=\(c.ssl.clientCertPath)") }
        if !c.ssl.clientKeyPath.isEmpty { a.append("--ssl-key=\(c.ssl.clientKeyPath)") }
        return a
    }

    // MARK: Command builders

    /// - Parameter includeDrop: emit DROP … IF EXISTS before each CREATE (ignored for data-only dumps).
    /// - Parameter includeRoutines: MySQL only; dump stored procedures/functions (`--routines`).
    static func backupCommand(_ c: DumpConnection, content: DumpContent, pgFormat: PGDumpFormat, includeDrop: Bool = false, includeRoutines: Bool = true, output: URL,
                              lookup: (String) -> String? = path(for:), mariaDBClient: Bool? = nil) throws -> ToolCommand {
        switch c.family {
        case .postgres:
            var args = postgresConnArgs(c) + ["--verbose", "--file=\(output.path)"]
            if pgFormat == .custom { args.append("--format=custom") }
            switch content {
            case .full: break
            case .schema: args.append("--schema-only")
            case .data: args.append("--data-only")
            }
            if includeDrop && content != .data { args += ["--clean", "--if-exists"] }
            args.append("--dbname=\(c.database)")
            return ToolCommand(executable: try requirePath("pg_dump", lookup: lookup), arguments: args, environment: postgresEnvironment(c))
        case .mysql:
            let exe = try requirePath("mysqldump", lookup: lookup)
            let maria = mariaDBClient ?? isMariaDBClient(exe)
            var args = mysqlConnArgs(c, mariaDBClient: maria) + ["--verbose", "--single-transaction", "--no-tablespaces", "--default-character-set=utf8mb4"]
            if !maria { args.append("--set-gtid-purged=OFF") }
            switch content {
            case .full: args += includeRoutines ? ["--routines", "--triggers"] : ["--triggers"]
            case .schema: args += ["--no-data"] + (includeRoutines ? ["--routines", "--triggers"] : ["--triggers"])
            case .data: args += ["--no-create-info", "--skip-triggers"]
            }
            if content != .data { args.append(includeDrop ? "--add-drop-table" : "--skip-add-drop-table") }
            // No --databases: the dump carries no CREATE DATABASE/USE, so it restores into any target.
            args += ["--result-file=\(output.path)", c.database]
            return ToolCommand(executable: exe, arguments: args, environment: ["MYSQL_PWD": c.password])
        case .sqlite:
            let exe = try requirePath("sqlite3", lookup: lookup)
            let dot: [String]
            switch content {
            case .full: dot = [".dump"]
            case .schema: dot = [".schema"]
            case .data: dot = [".dump --data-only"]
            }
            return ToolCommand(executable: exe, arguments: ["-readonly", c.filePath] + dot, stdoutFile: output)
        case .redis:
            throw DBError("Backup is not supported for Redis connections.")
        }
    }

    /// - Parameter clean: for pg_restore archives, drop existing objects before recreating them.
    static func restoreCommand(_ c: DumpConnection, input: URL, singleTransaction: Bool, clean: Bool = false,
                               lookup: (String) -> String? = path(for:), mariaDBClient: Bool? = nil) throws -> ToolCommand {
        switch c.family {
        case .postgres:
            if isPGCustomArchive(input) {
                var args = postgresConnArgs(c) + ["--verbose", "--exit-on-error", "--dbname=\(c.database)"]
                if singleTransaction { args.append("--single-transaction") }
                if clean { args += ["--clean", "--if-exists"] }
                args.append(input.path)
                return ToolCommand(executable: try requirePath("pg_restore", lookup: lookup), arguments: args, environment: postgresEnvironment(c))
            }
            var args = postgresConnArgs(c) + ["--no-psqlrc", "--set=ON_ERROR_STOP=1", "--echo-errors", "--dbname=\(c.database)"]
            if singleTransaction { args.append("--single-transaction") }
            args.append("--file=\(input.path)")
            return ToolCommand(executable: try requirePath("psql", lookup: lookup), arguments: args, environment: postgresEnvironment(c))
        case .mysql:
            let exe = try requirePath("mysql", lookup: lookup)
            let maria = mariaDBClient ?? isMariaDBClient(exe)
            let args = mysqlConnArgs(c, mariaDBClient: maria) + ["--default-character-set=utf8mb4", "--show-warnings", c.database]
            return ToolCommand(executable: exe, arguments: args, environment: ["MYSQL_PWD": c.password], stdinFile: input)
        case .sqlite:
            let exe = try requirePath("sqlite3", lookup: lookup)
            return ToolCommand(executable: exe, arguments: ["-bail", c.filePath], stdinFile: input)
        case .redis:
            throw DBError("Restore is not supported for Redis connections.")
        }
    }

    // MARK: Running

    struct SyncResult { var status: Int32; var output: String }

    /// Run to completion, collecting stdout+stderr. For tests / quick probes.
    static func runSync(_ cmd: ToolCommand) -> SyncResult {
        var out = ""
        let lock = NSLock()
        let p = ToolProcess(cmd)
        let sem = DispatchSemaphore(value: 0)
        var status: Int32 = -1
        p.start(output: { s in lock.lock(); out += s; lock.unlock() }, completion: { st, err in
            status = st
            if let err { lock.lock(); out += err; lock.unlock() }
            sem.signal()
        })
        sem.wait()
        return SyncResult(status: status, output: out)
    }
}

/// Runs an external tool, streaming stdout/stderr text as it arrives.
final class ToolProcess {
    let command: ToolCommand
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    init(_ command: ToolCommand) { self.command = command }

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// `output` and `completion` are called on background threads.
    /// `completion` receives the exit status and a launch error message, if any.
    func start(output: @escaping (String) -> Void, completion: @escaping (Int32, String?) -> Void) {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in command.environment { env[k] = v }
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        process.environment = env

        let errPipe = Pipe()
        process.standardError = errPipe
        var outPipe: Pipe?
        var stdoutHandle: FileHandle?
        var stdinHandle: FileHandle?
        do {
            if let o = command.stdoutFile {
                guard FileManager.default.createFile(atPath: o.path, contents: nil) else { throw DBError("Could not create \(o.path)") }
                let h = try FileHandle(forWritingTo: o)
                stdoutHandle = h
                process.standardOutput = h
            } else {
                let p = Pipe()
                outPipe = p
                process.standardOutput = p
            }
            if let i = command.stdinFile {
                let h = try FileHandle(forReadingFrom: i)
                stdinHandle = h
                process.standardInput = h
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            try process.run()
        } catch {
            completion(-1, "Could not launch \(command.toolName): \(error.localizedDescription)")
            return
        }

        let group = DispatchGroup()
        func drain(_ pipe: Pipe) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                var pending = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    pending.append(d)
                    // Emit only complete UTF-8 text (cut at the last newline).
                    if let nl = pending.lastIndex(of: 10) {
                        let chunk = pending[...nl]
                        output(String(decoding: chunk, as: UTF8.self))
                        pending = Data(pending[pending.index(after: nl)...])
                    }
                }
                if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
                group.leave()
            }
        }
        drain(errPipe)
        if let outPipe { drain(outPipe) }

        let proc = process
        DispatchQueue.global(qos: .utility).async {
            group.wait()
            proc.waitUntilExit()
            try? stdoutHandle?.close()
            try? stdinHandle?.close()
            completion(proc.terminationStatus, nil)
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}
