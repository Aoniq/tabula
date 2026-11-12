import Foundation
import SwiftUI
import Observation

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

private func loadJSON<T: Decodable>(_ type: T.Type, file: String) -> T? {
    let url = AppPaths.support.appendingPathComponent(file)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(type, from: data)
}

private func saveJSON<T: Encodable>(_ value: T, file: String) {
    let url = AppPaths.support.appendingPathComponent(file)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
}

// MARK: Connections

@Observable
final class ConnectionStore {
    static let shared = ConnectionStore()
    var connections: [ConnectionConfig] = []

    private init() {
        connections = loadJSON([ConnectionConfig].self, file: "connections.json") ?? []
    }

    func save() { saveJSON(connections, file: "connections.json") }

    func connection(_ id: UUID) -> ConnectionConfig? { connections.first { $0.id == id } }

    func upsert(_ c: ConnectionConfig) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i] = c } else { connections.append(c) }
        save()
    }

    func delete(_ id: UUID) {
        if let c = connection(id) {
            Keychain.delete(account: c.passwordAccount)
            Keychain.delete(account: c.sshPasswordAccount)
        }
        connections.removeAll { $0.id == id }
        save()
    }

    func duplicate(_ id: UUID) -> ConnectionConfig? {
        guard let c = connection(id) else { return nil }
        var copy = c
        copy.id = UUID()
        copy.name = c.displayName + " copy"
        if let pw = Keychain.get(account: c.passwordAccount) { Keychain.set(pw, account: copy.passwordAccount) }
        if let pw = Keychain.get(account: c.sshPasswordAccount) { Keychain.set(pw, account: copy.sshPasswordAccount) }
        upsert(copy)
        return copy
    }

    func touch(_ id: UUID) {
        if let i = connections.firstIndex(where: { $0.id == id }) {
            connections[i].lastUsed = Date()
            save()
        }
    }

    var groups: [String] {
        Array(Set(connections.map(\.group).filter { !$0.isEmpty })).sorted()
    }
}

// MARK: Query history

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var connectionID: UUID
    var database: String
    var sql: String
    var date: Date
    var duration: TimeInterval
    var success: Bool
}

@Observable
final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var items: [HistoryItem] = []
    private let limit = 5000
    private var saveScheduled = false

    private init() {
        items = loadJSON([HistoryItem].self, file: "history.json") ?? []
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        scheduleSave()
    }

    func clear(connectionID: UUID) {
        items.removeAll { $0.connectionID == connectionID }
        scheduleSave()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saveScheduled = false
            saveJSON(items, file: "history.json")
        }
    }
}

// MARK: Saved queries (favorites)

struct SavedQuery: Codable, Identifiable, Hashable {
    var id = UUID()
    var connectionID: UUID?   // nil = available for all connections
    var name: String
    var sql: String
    var keyword: String = ""
    var updated = Date()
}

@Observable
final class SavedQueryStore {
    static let shared = SavedQueryStore()
    var queries: [SavedQuery] = []

    private init() {
        queries = loadJSON([SavedQuery].self, file: "saved-queries.json") ?? []
    }

    func save() { saveJSON(queries, file: "saved-queries.json") }

    func upsert(_ q: SavedQuery) {
        var q = q
        q.updated = Date()
        if let i = queries.firstIndex(where: { $0.id == q.id }) { queries[i] = q } else { queries.append(q) }
        save()
    }

    func delete(_ id: UUID) {
        queries.removeAll { $0.id == id }
        save()
    }

    func queries(for connectionID: UUID) -> [SavedQuery] {
        queries.filter { $0.connectionID == nil || $0.connectionID == connectionID }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: Settings

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

enum SettingsKey {
    static let appearance = "appearance"
    static let editorFontSize = "editorFontSize"
    static let gridFontSize = "gridFontSize"
    static let pageSize = "pageSize"
    static let nullText = "nullText"
    static let autocomplete = "autocomplete"
    static let uppercaseKeywords = "uppercaseKeywords"
    static let estimateCounts = "estimateCounts"
    static let confirmDrop = "confirmDrop"
    static let alternatingRows = "alternatingRows"
    static let pgDumpPath = "pgDumpPath"
    static let psqlPath = "psqlPath"
    static let mysqldumpPath = "mysqldumpPath"
    static let mysqlPath = "mysqlPath"
    static let sqlite3Path = "sqlite3Path"
    static let anthropicModel = "anthropicModel"
}

enum Settings {
    static var defaults: UserDefaults { .standard }

    static func register() {
        defaults.register(defaults: [
            SettingsKey.appearance: AppearanceMode.system.rawValue,
            SettingsKey.editorFontSize: 13.0,
            SettingsKey.gridFontSize: 12.0,
            SettingsKey.pageSize: 300,
            SettingsKey.nullText: "NULL",
            SettingsKey.autocomplete: true,
            SettingsKey.uppercaseKeywords: true,
            SettingsKey.confirmDrop: true,
            SettingsKey.alternatingRows: true,
            SettingsKey.pgDumpPath: ToolLocator.find("pg_dump") ?? "",
            SettingsKey.psqlPath: ToolLocator.find("psql") ?? "",
            SettingsKey.mysqldumpPath: ToolLocator.find("mysqldump") ?? "",
            SettingsKey.mysqlPath: ToolLocator.find("mysql") ?? "",
            SettingsKey.sqlite3Path: ToolLocator.find("sqlite3") ?? "/usr/bin/sqlite3",
            SettingsKey.anthropicModel: "claude-opus-5-5",
        ])
    }

    static var pageSize: Int { max(10, defaults.integer(forKey: SettingsKey.pageSize)) }
    static var nullText: String { defaults.string(forKey: SettingsKey.nullText) ?? "NULL" }
    static var editorFontSize: CGFloat { CGFloat(defaults.double(forKey: SettingsKey.editorFontSize)) }
    static var gridFontSize: CGFloat { CGFloat(defaults.double(forKey: SettingsKey.gridFontSize)) }
    static var autocomplete: Bool { defaults.bool(forKey: SettingsKey.autocomplete) }
    static var uppercaseKeywords: Bool { defaults.bool(forKey: SettingsKey.uppercaseKeywords) }
    static var alternatingRows: Bool { defaults.bool(forKey: SettingsKey.alternatingRows) }
    static var confirmDrop: Bool { defaults.bool(forKey: SettingsKey.confirmDrop) }
    static func path(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
}

enum ToolLocator {
    static func find(_ tool: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/opt/homebrew/opt/libpq/bin", "/opt/homebrew/opt/postgresql@17/bin", "/opt/homebrew/opt/postgresql@16/bin",
            "/opt/homebrew/opt/mysql-client/bin", "/usr/local/mysql/bin",
            "/Applications/Postgres.app/Contents/Versions/latest/bin",
        ]
        for dir in candidates {
            let p = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
