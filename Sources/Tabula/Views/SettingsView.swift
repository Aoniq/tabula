import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.editorFontSize) private var editorFontSize = 13.0
    @AppStorage(SettingsKey.gridFontSize) private var gridFontSize = 12.0
    @AppStorage(SettingsKey.pageSize) private var pageSize = 300
    @AppStorage(SettingsKey.nullText) private var nullText = "NULL"
    @AppStorage(SettingsKey.autocomplete) private var autocomplete = true
    @AppStorage(SettingsKey.uppercaseKeywords) private var uppercase = true
    @AppStorage(SettingsKey.confirmDrop) private var confirmDrop = true
    @AppStorage(SettingsKey.alternatingRows) private var alternatingRows = true

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(AppearanceMode.system.rawValue)
                    Text("Light").tag(AppearanceMode.light.rawValue)
                    Text("Dark").tag(AppearanceMode.dark.rawValue)
                }
                .onChange(of: appearance) { _, v in NSApp.appearance = (AppearanceMode(rawValue: v) ?? .system).nsAppearance }
                Toggle("Confirm before dropping objects", isOn: $confirmDrop)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Stepper("Font size: \(Int(editorFontSize))", value: $editorFontSize, in: 9...28)
                Toggle("Autocomplete while typing", isOn: $autocomplete)
                Toggle("Uppercase keywords (completion & formatting)", isOn: $uppercase)
                Text("⌘↩ run statement · ⇧⌘↩ run all · ⌘I format · ⌘/ comment · ⌃Space complete")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }

            Form {
                Stepper("Font size: \(Int(gridFontSize))", value: $gridFontSize, in: 9...22)
                Picker("Rows per page", selection: $pageSize) {
                    ForEach([100, 200, 300, 500, 1000, 2000, 5000], id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("NULL display text", text: $nullText)
                Toggle("Alternating row colors", isOn: $alternatingRows)
                Text("Grid changes apply to newly opened tabs.").font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Data Grid", systemImage: "tablecells") }

            ToolPathsSettings()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            AssistantSettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .formStyle(.grouped)
        .frame(width: 720, height: 520)
    }
}

struct ToolPathsSettings: View {
    @AppStorage(SettingsKey.pgDumpPath) private var pgDump = ""
    @AppStorage(SettingsKey.psqlPath) private var psql = ""
    @AppStorage(SettingsKey.mysqldumpPath) private var mysqldump = ""
    @AppStorage(SettingsKey.mysqlPath) private var mysql = ""
    @AppStorage(SettingsKey.sqlite3Path) private var sqlite3 = ""

    var body: some View {
        Form {
            Section("Used for backup & restore") {
                row("pg_dump", $pgDump)
                row("psql", $psql)
                row("mysqldump", $mysqldump)
                row("mysql", $mysql)
                row("sqlite3", $sqlite3)
            }
        }
    }

    private func row(_ name: String, _ binding: Binding<String>) -> some View {
        HStack {
            TextField(name, text: binding, prompt: Text("not found"))
            Button("Detect") { binding.wrappedValue = ToolLocator.find(name) ?? "" }
            Button("Choose…") {
                let p = NSOpenPanel()
                p.showsHiddenFiles = true
                if p.runModal() == .OK, let u = p.url { binding.wrappedValue = u.path }
            }
        }
    }
}
