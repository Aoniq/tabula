// swift-tools-version:5.10
import PackageDescription

// Native client libraries (from Homebrew at build time; bundled into the .app by scripts/build-app.sh)
let pgInclude = "/opt/homebrew/opt/postgresql@17/include/postgresql"
let pgLib = "/opt/homebrew/opt/postgresql@17/lib/postgresql"
let mariaInclude = "/opt/homebrew/opt/mariadb-connector-c/include/mariadb"
let mariaLib = "/opt/homebrew/opt/mariadb-connector-c/lib/mariadb"

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "Sources/CLibPQ"),
        .systemLibrary(name: "CMariaDB", path: "Sources/CMariaDB"),
        .executableTarget(
            name: "Tabula",
            dependencies: ["CLibPQ", "CMariaDB"],
            path: "Sources/Tabula",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(pgInclude)", "-Xcc", "-I\(mariaInclude)"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(pgLib)", "-L\(mariaLib)",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
