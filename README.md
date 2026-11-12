# Tabula

A native macOS database client in the spirit of TablePlus. Built with SwiftUI and AppKit, it talks to databases through their official C client libraries.

## Supported databases

| Engine | Driver |
|---|---|
| PostgreSQL, CockroachDB, Amazon Redshift, Greenplum | libpq |
| MySQL, MariaDB, SingleStore | MariaDB Connector/C (including MySQL 8 `caching_sha2_password`) |
| SQLite | system SQLite |
| Redis | built-in RESP client |

## Features

- **Connections:** groups, colour-coded environment tags (local → production), and passwords stored in the Keychain.
  - SSL/TLS with CA and client certificates.
  - SSH tunnels using a password, a private key or the SSH agent.
  - Startup SQL, and import from `postgres://…` URLs.
  - Open `.sqlite` and `.db` files from Finder.
- **Workspace:** one window per connection, with tabs.
  - Preview tabs on single click; double-click to pin a tab.
  - Database and schema switcher (⌘K) and Open Anything (⌘P).
  - Process list, users & roles, and a metrics dashboard.
- **Data grid:** a fast `NSTableView` grid.
  - Inline editing, set NULL/empty/DEFAULT, and add/duplicate/delete rows.
  - Pending changes are highlighted. Review the generated SQL (⇧⌘P), then commit them in one transaction (⌘S).
  - Server-side sorting, pagination and advanced filters (any column, 20 operators, raw SQL).
  - Follow foreign keys with ⌥-click.
  - Copy as TSV, CSV, JSON, SQL INSERT or Markdown.
  - Row inspector with JSON pretty-printing.
- **ER diagram (⇧⌘E):**
  - Live diagram of the current schema or database with crow's-foot relationships and automatic layered layout.
  - Drag to arrange (positions are remembered), pan, pinch or ⌘-scroll to zoom, find a table, and focus on a table plus its neighbours.
  - Show all columns, keys only or names only.
  - Export to PNG, PDF, SVG or the clipboard, as Mermaid, DBML, PlantUML or Graphviz DOT, as a Markdown data dictionary, or as SQL DDL.
- **Structure editor:** columns, indexes and foreign keys, with ALTER statements generated per dialect. Create tables, rename, truncate, drop and view the DDL.
- **SQL editor:**
  - Syntax highlighting, line numbers and context-aware autocomplete (tables, aliases, columns, keywords).
  - Run the current statement (⌘↩) or all statements (⇧⌘↩), explain, stop (⌘.).
  - Formatter (⌘I), comment toggle (⌘/), and multiple result sets plus a message log.
  - Saved queries and searchable query history.
- **Safe mode** per connection: off, confirm every write, or read-only.
- **Import/export:**
  - Export to CSV, TSV, JSON, SQL, Markdown or HTML.
  - Import CSV with column mapping, and run SQL files.
  - Backup and restore through pg_dump/psql, mysqldump/mysql and sqlite3.
- **AI assistant** (Claude API, bring your own key) that knows your schema. It can insert or run the SQL it suggests.
- Light and dark mode, configurable fonts and page size.

## Build & install

Requirements: Xcode 16+, Homebrew `postgresql@17` and `mariadb-connector-c`. The libraries are copied into the app bundle, so the installed app does not need Homebrew at runtime.

```bash
brew install postgresql@17 mariadb-connector-c
scripts/build-app.sh --install     # builds release, bundles dylibs, signs ad-hoc, copies to /Applications
```

## Development

```bash
swift build && .build/debug/Tabula            # run from source
scripts/test-dbs.sh                            # start + seed Postgres/MySQL/Redis test containers (Docker)
.build/debug/Tabula --selftest                 # driver/tokenizer self-test against the test containers
.build/debug/Tabula --snapshot "<connection name>" /tmp/shots   # render key screens offscreen to PNG
Tabula --erd-dump "<connection url>" [schema]  # print the ER graph as JSON
Tabula --scrollbench "<connection url>" <table>   # measure grid scrolling performance
```

App data lives in `~/Library/Application Support/Tabula`: connections, history, saved queries and dashboards. Passwords are kept in the Keychain under the service "Tabula".

## Keyboard shortcuts

| | |
|---|---|
| ⌘T / ⌘W | New query tab / close tab |
| ⌘P | Open anything |
| ⌘K | Switch database or schema |
| ⌘↩ / ⇧⌘↩ | Run current statement / run all |
| ⌘I / ⌘/ | Format SQL / toggle comment |
| ⌃Space | Autocomplete |
| ⌘F | Filter rows (data) / find (editor) |
| ⌘S / ⇧⌘P / ⇧⌘⌫ | Commit / review / discard changes |
| ⌥⌘N / ⌘D / ⌫ | Add / duplicate / delete row |
| ⌃⌘[ / ⌃⌘] | Data / structure view |
| ⌥⌘← / ⌥⌘→ | Previous / next page |
| ⌘R | Refresh |
| ⌥⌘I / ⌘J | Row inspector / AI assistant |
| ⇧⌘E | ER diagram |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
