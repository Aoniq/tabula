import Foundation

/// Local port forward implemented with the system OpenSSH client (`ssh -N -L`).
/// Password / passphrase authentication is fed through SSH_ASKPASS.
final class SSHTunnel {
    let localPort: Int
    private let process = Process()
    private let errPipe = Pipe()

    init(config: SSHConfig, secret: String?, remoteHost: String, remotePort: Int) throws {
        localPort = try SSHTunnel.freePort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "-p", String(config.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if config.auth == .key, !config.keyPath.isEmpty {
            args += ["-i", (config.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if config.auth == .password {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        }
        args.append(config.user.isEmpty ? config.host : "\(config.user)@\(config.host)")
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        if let secret, !secret.isEmpty {
            env["SSH_ASKPASS"] = try SSHTunnel.askPassScript()
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env["TABULA_SSH_SECRET"] = secret
        } else {
            env["SSH_ASKPASS_REQUIRE"] = "never"
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        try process.run()

        // Wait until the forwarded port accepts connections, or ssh exits.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw DBError("SSH tunnel failed: " + (msg.isEmpty ? "ssh exited with status \(process.terminationStatus)" : msg))
            }
            if SSHTunnel.canConnect(port: localPort) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.terminate()
        throw DBError("SSH tunnel timed out connecting to \(config.host)")
    }

    var isAlive: Bool { process.isRunning }

    func close() {
        if process.isRunning { process.terminate() }
    }

    deinit { close() }

    private static func askPassScript() throws -> String {
        let url = AppPaths.support.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$TABULA_SSH_SECRET\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DBError("Cannot allocate a local port") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { throw DBError("Cannot bind a local port") }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }
}
