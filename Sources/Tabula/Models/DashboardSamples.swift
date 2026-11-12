import Foundation

/// Family-appropriate starter tiles for an empty metrics board.
/// Every query here is read-only and was checked against Postgres 17, MySQL 8.4 and SQLite 3.
enum DashboardSamples {
    static func tiles(family: DatabaseFamily, tables: [String]) -> [DashboardTile] {
        switch family {
        case .postgres: return postgres
        case .mysql: return mysql
        case .sqlite: return sqlite(tables: tables)
        case .redis: return []
        }
    }

    static let postgres: [DashboardTile] = [
        DashboardTile(
            title: "Database size",
            sql: "SELECT pg_database_size(current_database()) AS size_bytes,\n       current_database() AS database_name;",
            kind: .number, format: .bytes),
        DashboardTile(
            title: "Connections by state",
            sql: """
            SELECT CASE WHEN backend_type = 'client backend' THEN COALESCE(state, 'unknown')
                        ELSE 'background worker' END AS state,
                   COUNT(*) AS connections
            FROM pg_stat_activity
            GROUP BY 1
            ORDER BY 2 DESC;
            """,
            kind: .pie),
        DashboardTile(
            title: "Largest tables",
            sql: """
            SELECT n.nspname || '.' || c.relname AS table_name,
                   pg_total_relation_size(c.oid) AS total_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'm', 'p')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY total_bytes DESC
            LIMIT 10;
            """,
            kind: .bar, width: 2, format: .bytes),
        DashboardTile(
            title: "Rows per table",
            sql: """
            SELECT schemaname || '.' || relname AS table_name,
                   n_live_tup AS live_rows,
                   n_dead_tup AS dead_rows,
                   last_autovacuum,
                   last_autoanalyze
            FROM pg_stat_user_tables
            ORDER BY n_live_tup DESC
            LIMIT 50;
            """,
            kind: .table, width: 2),
    ]

    static let mysql: [DashboardTile] = [
        DashboardTile(
            title: "Database size",
            sql: """
            SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0) AS size_bytes,
                   DATABASE() AS database_name
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE();
            """,
            kind: .number, format: .bytes),
        DashboardTile(
            title: "Connections",
            sql: """
            SELECT COUNT(*) AS connections,
                   CONCAT(SUM(COMMAND <> 'Sleep'), ' active · ', SUM(COMMAND = 'Sleep'), ' idle') AS detail
            FROM information_schema.PROCESSLIST;
            """,
            kind: .number),
        DashboardTile(
            title: "Largest tables",
            sql: """
            SELECT TABLE_NAME AS table_name,
                   DATA_LENGTH + INDEX_LENGTH AS total_bytes
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY total_bytes DESC
            LIMIT 10;
            """,
            kind: .bar, width: 2, format: .bytes),
        DashboardTile(
            title: "Connections by command",
            sql: """
            SELECT COMMAND AS command, COUNT(*) AS connections
            FROM information_schema.PROCESSLIST
            GROUP BY COMMAND
            ORDER BY connections DESC;
            """,
            kind: .pie),
        DashboardTile(
            title: "Tables",
            sql: """
            SELECT TABLE_NAME AS table_name,
                   TABLE_ROWS AS approx_rows,
                   ENGINE AS engine,
                   ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024) AS size_kb,
                   UPDATE_TIME AS updated
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_ROWS DESC
            LIMIT 50;
            """,
            kind: .table),
    ]

    /// Max tables included in the generated row-count query.
    static let sqliteTableLimit = 25

    static func sqliteRowCountSQL(tables: [String]) -> String? {
        let names = tables.prefix(sqliteTableLimit)
        guard !names.isEmpty else { return nil }
        let parts = names.map { name -> String in
            let literal = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
            let ident = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return "SELECT \(literal) AS table_name, COUNT(*) AS row_count FROM \(ident)"
        }
        return parts.joined(separator: "\nUNION ALL\n") + "\nORDER BY row_count DESC;"
    }

    static func sqlite(tables: [String]) -> [DashboardTile] {
        var out: [DashboardTile] = [
            DashboardTile(
                title: "Database size",
                sql: "SELECT page_count * page_size AS size_bytes,\n       page_count || ' pages of ' || page_size || ' bytes' AS detail\nFROM pragma_page_count(), pragma_page_size();",
                kind: .number, format: .bytes),
            DashboardTile(
                title: "Tables & views",
                sql: "SELECT COUNT(*) AS objects,\n       SUM(type = 'table') || ' tables · ' || SUM(type = 'view') || ' views' AS detail\nFROM sqlite_master\nWHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%';",
                kind: .number),
        ]
        if let sql = sqliteRowCountSQL(tables: tables) {
            out.append(DashboardTile(title: "Rows per table", sql: sql, kind: .bar, width: 2))
        }
        return out
    }
}
