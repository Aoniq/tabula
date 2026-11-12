import SwiftUI
import AppKit

struct ConnectionFormView: View {
    @State var draft: ConnectionConfig
    var onCancel: () -> Void
    var onSave: (ConnectionConfig) -> Void
    var onConnect: (ConnectionConfig) -> Void

    @State private var password = ""
    @State private var sshSecret = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    init(draft: ConnectionConfig, onCancel: @escaping () -> Void, onSave: @escaping (ConnectionConfig) -> Void, onConnect: @escaping (ConnectionConfig) -> Void) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
        self.onConnect = onConnect
        _password = State(initialValue: Keychain.get(account: draft.passwordAccount) ?? "")
        _sshSecret = State(initialValue: Keychain.get(account: draft.sshPasswordAccount) ?? "")
    }

    private var isSQLite: Bool { draft.kind.family == .sqlite }
    private var isRedis: Bool { draft.kind.family == .redis }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        KindBadge(kind: draft.kind, size: 22)
                        Picker("Type", selection: $draft.kind) {
                            ForEach(DatabaseKind.allCases) { k in Text(k.displayName).tag(k) }
                        }
                    }
                    TextField("Name", text: $draft.name, prompt: Text(draft.displayName.isEmpty ? "My database" : draft.displayName))
                    Picker("Tag", selection: $draft.tag) {
                        ForEach(EnvironmentTag.allCases) { t in
                            Label { Text(t.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(t.color) }.tag(t)
                        }
                    }
                    TextField("Group", text: $draft.group, prompt: Text("Optional"))
                }

                if isSQLite {
                    Section("Database File") {
                        HStack {
                            TextField("Path", text: $draft.filePath, prompt: Text("/path/to/database.sqlite"))
                            Button("Choose…") { chooseFile(\.filePath, create: false) }
                            Button("New…") { createSQLite() }
                        }
                    }
                } else {
                    Section(isRedis ? "Server" : "Server") {
                        HStack {
                            TextField("Host", text: $draft.host)
                            TextField("Port", value: $draft.port, format: .number.grouping(.never)).frame(width: 110)
                        }
                        TextField("User", text: $draft.user, prompt: Text(isRedis ? "Optional (ACL)" : draft.kind.defaultUser))
                        SecureField("Password", text: $password)
                        Toggle("Save password in Keychain", isOn: $draft.savePassword)
                        TextField(isRedis ? "Database index" : "Database", text: $draft.database, prompt: Text(isRedis ? "0" : "Optional"))
                    }
                    if !isRedis {
                        Section("TLS / SSL") {
                            Picker("Mode", selection: $draft.ssl.mode) {
                                ForEach(SSLMode.allCases) { Text($0.label).tag($0) }
                            }
                            if draft.ssl.mode != .disable {
                                pathRow("CA certificate", \.ssl.caCertPath)
                                pathRow("Client certificate", \.ssl.clientCertPath)
                                pathRow("Client key", \.ssl.clientKeyPath)
                            }
                        }
                    }
                    Section {
                        Toggle("Connect over SSH", isOn: $draft.ssh.enabled)
                        if draft.ssh.enabled {
                            HStack {
                                TextField("SSH host", text: $draft.ssh.host)
                                TextField("Port", value: $draft.ssh.port, format: .number.grouping(.never)).frame(width: 90)
                            }
                            TextField("SSH user", text: $draft.ssh.user)
                            Picker("Authentication", selection: $draft.ssh.auth) {
                                ForEach(SSHConfig.Auth.allCases) { Text($0.label).tag($0) }
                            }
                            if draft.ssh.auth == .key {
                                HStack {
                                    TextField("Private key", text: $draft.ssh.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                                    Button("Choose…") { chooseFile(\.ssh.keyPath, create: false, showHidden: true) }
                                }
                                SecureField("Key passphrase", text: $sshSecret, prompt: Text("Optional"))
                            } else if draft.ssh.auth == .password {
                                SecureField("SSH password", text: $sshSecret)
                            }
                        }
                    } header: { Text("SSH Tunnel") }
                }

                Section("Safety & Startup") {
                    Picker("Safe mode", selection: $draft.safeMode) {
                        ForEach(SafeMode.allCases) { Text($0.label).tag($0) }
                    }
                    if !isRedis {
                        VStack(alignment: .leading) {
                            Text("Run on connect").font(.callout)
                            TextEditor(text: $draft.startupSQL)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 50)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.kind) { old, new in
                if draft.port == old.defaultPort || draft.port == 0 { draft.port = new.defaultPort }
                if draft.user.isEmpty || draft.user == old.defaultUser { draft.user = new.defaultUser }
            }

            Divider()
            HStack {
                if testing { ProgressView().controlSize(.small) }
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                        .lineLimit(2)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Test") { Task { await test() } }.disabled(testing)
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Save") { persistSecrets(); onSave(draft) }
                Button("Connect") { persistSecrets(); onConnect(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private func pathRow(_ title: String, _ kp: WritableKeyPath<ConnectionConfig, String>) -> some View {
        HStack {
            TextField(title, text: Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0 }))
            Button("Choose…") { chooseFile(kp, create: false, showHidden: true) }
        }
    }

    private func chooseFile(_ kp: WritableKeyPath<ConnectionConfig, String>, create: Bool, showHidden: Bool = false) {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = showHidden
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { draft[keyPath: kp] = url.path }
    }

    private func createSQLite() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.sqlite"
        if panel.runModal() == .OK, let url = panel.url {
            draft.filePath = url.path
            if draft.name.isEmpty { draft.name = url.lastPathComponent }
        }
    }

    private func persistSecrets() {
        if draft.savePassword && !isSQLite { Keychain.set(password, account: draft.passwordAccount) } else { Keychain.delete(account: draft.passwordAccount) }
        if draft.ssh.enabled && !sshSecret.isEmpty { Keychain.set(sshSecret, account: draft.sshPasswordAccount) } else { Keychain.delete(account: draft.sshPasswordAccount) }
    }

    private func test() async {
        testing = true
        testResult = nil
        let cfg = draft, pw = password, ssh = sshSecret.isEmpty ? nil : sshSecret
        do {
            let s = try await DBSession.open(config: cfg, password: pw, sshSecret: ssh)
            let v = (try? await s.run { $0.serverVersion() }) ?? ""
            s.close()
            testResult = (true, "Connected · " + String(v.prefix(60)))
        } catch {
            testResult = (false, error.localizedDescription)
        }
        testing = false
    }
}
