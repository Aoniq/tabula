# Third-party notices

Tabula's own source code is licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`).

The source code in this repository contains no third-party code. Prebuilt `Tabula.app` bundles, however, embed the
following native libraries, copied from Homebrew at build time. Each is used unmodified, linked dynamically, and stays
under its own license. The full license texts ship inside the app at `Tabula.app/Contents/Resources/Licenses/`.

| Library | Used for | License |
|---|---|---|
| [libpq](https://www.postgresql.org/) (PostgreSQL client library) | PostgreSQL, CockroachDB, Redshift and Greenplum connections | PostgreSQL License (permissive) |
| [MariaDB Connector/C](https://mariadb.com/kb/en/mariadb-connector-c/) and its auth plugins | MySQL, MariaDB and SingleStore connections | GNU LGPL 2.1 or later |
| [OpenSSL](https://www.openssl.org/) 3 and 4 | TLS for database connections | Apache License 2.0 |
| [MIT Kerberos](https://web.mit.edu/kerberos/) (libgssapi_krb5, libkrb5, libk5crypto, libkrb5support, libcom_err) | GSSAPI support in libpq | MIT and BSD-style licenses (see NOTICE) |
| [GNU gettext](https://www.gnu.org/software/gettext/) runtime (libintl) | Message localisation in libpq | GNU LGPL 2.1 or later |

## LGPL libraries

MariaDB Connector/C and libintl are LGPL-licensed and are linked dynamically, as separate `.dylib` files in
`Tabula.app/Contents/Frameworks` (and `Contents/Resources/mariadb-plugins`). You may replace them with your own
compatible builds. To rebuild the app from source, see "Build & install" in the README. The corresponding library
sources are available from the projects' websites listed above.

Apple system frameworks (SwiftUI, AppKit, Security, SQLite and others) are part of macOS and are not redistributed.
