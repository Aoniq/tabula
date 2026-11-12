import SwiftUI

@main
struct TabulaApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
    }
    var body: some Scene {
        WindowGroup { Text("Tabula") }
    }
}
