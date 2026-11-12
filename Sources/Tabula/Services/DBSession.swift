import Foundation

/// Owns a driver (and optional SSH tunnel) and serialises all access on a background queue.
final class DBSession {
    let driver: DatabaseDriver
    let tunnel: SSHTunnel?
    private let queue: DispatchQueue

    private init(driver: DatabaseDriver, tunnel: SSHTunnel?) {
        self.driver = driver
        self.tunnel = tunnel
        self.queue = DispatchQueue(label: "tabula.session.\(UUID().uuidString)", qos: .userInitiated)
    }

    var dialect: SQLDialect { driver.dialect }

    /// Create the driver for a config (password supplied by caller) and connect. Blocking.
    static func openBlocking(config: ConnectionConfig, password: String, sshSecret: String?) throws -> DBSession {
        var host = config.host
        var port = config.port
        var tunnel: SSHTunnel?
        if config.ssh.enabled && config.kind.family != .sqlite {
            let t = try SSHTunnel(config: config.ssh, secret: sshSecret, remoteHost: config.host, remotePort: config.port)
            tunnel = t
            host = "127.0.0.1"
            port = t.localPort
        }
        let driver: DatabaseDriver
        switch config.kind.family {
        case .postgres: driver = PostgresDriver(config: config, password: password, host: host, port: port)
        case .mysql: driver = MySQLDriver(config: config, password: password, host: host, port: port)
        case .sqlite: driver = SQLiteDriver(path: config.filePath, startupSQL: config.startupSQL)
        case .redis: driver = RedisDriver(config: config, password: password, host: host, port: port)
        }
        do {
            try driver.connect()
        } catch {
            tunnel?.close()
            throw error
        }
        return DBSession(driver: driver, tunnel: tunnel)
    }

    static func open(config: ConnectionConfig, password: String, sshSecret: String?) async throws -> DBSession {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try openBlocking(config: config, password: password, sshSecret: sshSecret))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func run<T>(_ body: @escaping (DatabaseDriver) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [driver] in
                do { cont.resume(returning: try body(driver)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    func cancel() {
        DispatchQueue.global().async { [driver] in driver.cancel() }
    }

    func close() {
        queue.async { [driver, tunnel] in
            driver.close()
            tunnel?.close()
        }
    }
}
