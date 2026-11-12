import Foundation

/// How CSV columns map onto a table and how records become INSERT statements.
/// Pure value logic — safe to use on the DB queue.
struct CSVImportPlan {
    var table: DBObject
    var dialect: SQLDialect
    /// Target table column for each CSV column index (nil = skip).
    var mapping: [String?]
    var emptyAsNull: Bool

    /// (csvIndex, targetColumn) pairs that are actually imported, in CSV order.
    var mappedPairs: [(Int, String)] {
        mapping.enumerated().compactMap { i, c in c.map { (i, $0) } }
    }

    var targetColumns: [String] { mappedPairs.map(\.1) }

    func values(for record: [String]) -> [String?] {
        mappedPairs.map { i, _ in
            guard i < record.count else { return nil }
            let v = record[i]
            return emptyAsNull && v.isEmpty ? nil : v
        }
    }

    /// One multi-row INSERT for a slice of records.
    func insertSQL<S: Sequence>(_ records: S) -> String where S.Element == [String] {
        dialect.insertSQL(table, columns: targetColumns, rows: records.map(values(for:)))
    }

    /// Guess a mapping: by name (case-insensitive, ignoring spaces/underscores/dashes) when the
    /// file has a header, otherwise by position.
    static func autoMap(csvColumns: [String], tableColumns: [String], hasHeader: Bool) -> [String?] {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        if !hasHeader {
            return csvColumns.indices.map { $0 < tableColumns.count ? tableColumns[$0] : nil }
        }
        var used = Set<String>()
        return csvColumns.map { h in
            let trimmed = h.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = tableColumns.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame && !used.contains($0) }
                ?? tableColumns.first { norm($0) == norm(trimmed) && !norm(trimmed).isEmpty && !used.contains($0) }
            if let match { used.insert(match) }
            return match
        }
    }
}

/// Error raised when a specific CSV row could not be inserted.
struct CSVImportRowError: LocalizedError {
    /// 1-based data row number (header excluded).
    var row: Int
    var message: String
    var values: [String?]
    var errorDescription: String? { "Row \(row): \(message)" }
}

/// Synchronous building blocks run on the DB queue (each call is one `ws.run`).
enum CSVImporter {
    static let batchSize = 500
    private static let savepoint = "tabula_csv_import"

    static func begin(_ d: DatabaseDriver) throws {
        _ = try d.execute(d.dialect.family == .mysql ? "START TRANSACTION" : "BEGIN")
    }

    static func commit(_ d: DatabaseDriver) throws {
        _ = try d.execute("COMMIT")
    }

    static func rollback(_ d: DatabaseDriver) {
        _ = try? d.execute("ROLLBACK")
    }

    /// Insert one batch inside the open transaction. On failure the batch is retried row by row
    /// (inside a savepoint) so the exact failing row can be reported; the caller then rolls back.
    /// - Parameter firstRow: 1-based data row number of `records.first`.
    static func insertBatch(_ d: DatabaseDriver, plan: CSVImportPlan, records: ArraySlice<[String]>, firstRow: Int) throws {
        guard !records.isEmpty else { return }
        let sql = plan.insertSQL(records)
        _ = try d.execute("SAVEPOINT \(savepoint)")
        do {
            _ = try d.execute(sql)
            _ = try? d.execute("RELEASE SAVEPOINT \(savepoint)")
            return
        } catch let batchError {
            _ = try? d.execute("ROLLBACK TO SAVEPOINT \(savepoint)")
            for (n, rec) in records.enumerated() {
                do {
                    _ = try d.execute(plan.insertSQL([rec]))
                } catch {
                    throw CSVImportRowError(row: firstRow + n, message: error.localizedDescription, values: plan.values(for: rec))
                }
            }
            // Every row succeeded individually (e.g. a packet-size problem): keep going.
            _ = batchError
            _ = try? d.execute("RELEASE SAVEPOINT \(savepoint)")
        }
    }

    /// Read a CSV file as UTF-8 data (falling back to Latin-1 re-encoding when it isn't valid UTF-8).
    static func loadData(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if String(data: data, encoding: .utf8) != nil { return data }
        if let s = String(data: data, encoding: .isoLatin1) { return Data(s.utf8) }
        return data
    }
}
