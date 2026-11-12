import Foundation
import SwiftUI

/// Protocol family a database speaks. Drivers are chosen per family.
enum DatabaseFamily: String, Codable {
    case postgres, mysql, sqlite, redis
}

enum DatabaseKind: String, Codable, CaseIterable, Identifiable {
    case postgresql, cockroachdb, redshift, greenplum, mysql, mariadb, singlestore, sqlite, redis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .postgresql: return "PostgreSQL"
        case .cockroachdb: return "CockroachDB"
        case .redshift: return "Amazon Redshift"
        case .greenplum: return "Greenplum"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .singlestore: return "SingleStore"
        case .sqlite: return "SQLite"
        case .redis: return "Redis"
        }
    }

    var family: DatabaseFamily {
        switch self {
        case .postgresql, .cockroachdb, .redshift, .greenplum: return .postgres
        case .mysql, .mariadb, .singlestore: return .mysql
        case .sqlite: return .sqlite
        case .redis: return .redis
        }
    }

    var defaultPort: Int {
        switch self {
        case .postgresql, .greenplum: return 5432
        case .cockroachdb: return 26257
        case .redshift: return 5439
        case .mysql, .mariadb, .singlestore: return 3306
        case .sqlite: return 0
        case .redis: return 6379
        }
    }

    var defaultUser: String {
        switch family {
        case .postgres: return self == .cockroachdb ? "root" : "postgres"
        case .mysql: return "root"
        default: return ""
        }
    }

    var badge: String {
        switch self {
        case .postgresql: return "Pg"
        case .cockroachdb: return "Cr"
        case .redshift: return "Rs"
        case .greenplum: return "Gp"
        case .mysql: return "My"
        case .mariadb: return "Ma"
        case .singlestore: return "Ss"
        case .sqlite: return "Lt"
        case .redis: return "Rd"
        }
    }

    var color: Color {
        switch self {
        case .postgresql: return Color(red: 0.20, green: 0.40, blue: 0.62)
        case .cockroachdb: return Color(red: 0.38, green: 0.31, blue: 0.85)
        case .redshift: return Color(red: 0.80, green: 0.25, blue: 0.20)
        case .greenplum: return Color(red: 0.20, green: 0.60, blue: 0.40)
        case .mysql: return Color(red: 0.0, green: 0.46, blue: 0.56)
        case .mariadb: return Color(red: 0.75, green: 0.50, blue: 0.30)
        case .singlestore: return Color(red: 0.55, green: 0.20, blue: 0.75)
        case .sqlite: return Color(red: 0.25, green: 0.55, blue: 0.85)
        case .redis: return Color(red: 0.85, green: 0.20, blue: 0.18)
        }
    }
}

enum EnvironmentTag: String, Codable, CaseIterable, Identifiable {
    case none, local, development, testing, staging, production
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .local: return "Local"
        case .development: return "Development"
        case .testing: return "Testing"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }
    var color: Color {
        switch self {
        case .none: return .gray
        case .local: return .green
        case .development: return .blue
        case .testing: return .purple
        case .staging: return .orange
        case .production: return .red
        }
    }
}

enum SafeMode: String, Codable, CaseIterable, Identifiable {
    case off, confirmWrites, readOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .confirmWrites: return "Confirm before writing"
        case .readOnly: return "Read-only"
        }
    }
}

enum SSLMode: String, Codable, CaseIterable, Identifiable {
    case disable, prefer, require, verifyCA = "verify-ca", verifyFull = "verify-full"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disable: return "Disabled"
        case .prefer: return "Preferred"
        case .require: return "Required"
        case .verifyCA: return "Verify CA"
        case .verifyFull: return "Verify Full"
        }
    }
}

struct SSLConfig: Codable, Hashable {
    var mode: SSLMode = .prefer
    var caCertPath = ""
    var clientCertPath = ""
    var clientKeyPath = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(SSLMode.self, forKey: .mode)) ?? .prefer
        caCertPath = (try? c.decode(String.self, forKey: .caCertPath)) ?? ""
        clientCertPath = (try? c.decode(String.self, forKey: .clientCertPath)) ?? ""
        clientKeyPath = (try? c.decode(String.self, forKey: .clientKeyPath)) ?? ""
    }
}

struct SSHConfig: Codable, Hashable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        case password, key, agent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .password: return "Password"
            case .key: return "Private Key"
            case .agent: return "SSH Agent / Config"
            }
        }
    }
    var enabled = false
    var host = ""
    var port = 22
    var user = ""
    var auth: Auth = .key
    var keyPath = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 22
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        auth = (try? c.decode(Auth.self, forKey: .auth)) ?? .key
        keyPath = (try? c.decode(String.self, forKey: .keyPath)) ?? ""
    }
}

struct ConnectionConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var kind: DatabaseKind = .postgresql
    var host = "127.0.0.1"
    var port = 5432
    var user = ""
    var database = ""
    var filePath = ""
    var tag: EnvironmentTag = .none
    var group = ""
    var safeMode: SafeMode = .off
    var savePassword = true
    var ssl = SSLConfig()
    var ssh = SSHConfig()
    var startupSQL = ""
    var lastUsed: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decode(DatabaseKind.self, forKey: .kind)) ?? .postgresql
        host = (try? c.decode(String.self, forKey: .host)) ?? "127.0.0.1"
        port = (try? c.decode(Int.self, forKey: .port)) ?? kind.defaultPort
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        database = (try? c.decode(String.self, forKey: .database)) ?? ""
        filePath = (try? c.decode(String.self, forKey: .filePath)) ?? ""
        tag = (try? c.decode(EnvironmentTag.self, forKey: .tag)) ?? .none
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        safeMode = (try? c.decode(SafeMode.self, forKey: .safeMode)) ?? .off
        savePassword = (try? c.decode(Bool.self, forKey: .savePassword)) ?? true
        ssl = (try? c.decode(SSLConfig.self, forKey: .ssl)) ?? SSLConfig()
        ssh = (try? c.decode(SSHConfig.self, forKey: .ssh)) ?? SSHConfig()
        startupSQL = (try? c.decode(String.self, forKey: .startupSQL)) ?? ""
        lastUsed = try? c.decode(Date.self, forKey: .lastUsed)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if kind.family == .sqlite { return (filePath as NSString).lastPathComponent }
        return "\(user.isEmpty ? "" : user + "@")\(host)"
    }

    var subtitle: String {
        if kind.family == .sqlite { return filePath }
        var s = "\(host):\(port)"
        if !database.isEmpty { s += "/\(database)" }
        if ssh.enabled { s += "  via SSH \(ssh.host)" }
        return s
    }

    // Keychain accounts
    var passwordAccount: String { "\(id.uuidString).db" }
    var sshPasswordAccount: String { "\(id.uuidString).ssh" }
}
