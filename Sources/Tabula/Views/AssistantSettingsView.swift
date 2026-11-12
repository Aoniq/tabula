import SwiftUI
import AppKit

/// Settings → AI: Anthropic API key (Keychain) and model.
struct AssistantSettingsView: View {
    @AppStorage(SettingsKey.anthropicModel) private var model = AnthropicAPI.defaultModel
    @State private var keyField = ""
    @State private var hasKey = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        Form {
            Section {
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { removeKey() }
                        }
                    }
                }
                SecureField(hasKey ? "Replace key" : "API key", text: $keyField, prompt: Text("sk-ant-…"))
                    .onSubmit(saveKey)
                HStack {
                    Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                    Spacer()
                    Button("Save Key") { saveKey() }
                        .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Anthropic API")
            } footer: {
                Text("The key is stored in your macOS Keychain. Requests go directly from Tabula to api.anthropic.com and include table/column definitions and the current query — never row data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    TextField("Model ID", text: $model, prompt: Text(AnthropicAPI.defaultModel))
                        .font(.system(.body, design: .monospaced))
                    Menu {
                        ForEach(AnthropicAPI.knownModels, id: \.id) { m in
                            Button(m.label) { model = m.id }
                        }
                    } label: {
                        Text("Choose")
                    }
                    .fixedSize()
                }
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(!hasKey && keyField.isEmpty || testState == .testing)
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .ok(let name):
                        Label("Works — \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .lineLimit(1)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
            }
        }
        .onAppear { refresh() }
        .onChange(of: model) { _, _ in testState = .idle }
    }

    private func refresh() {
        hasKey = !(Keychain.get(account: AnthropicAPI.keychainAccount) ?? "").isEmpty
    }

    private func saveKey() {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, account: AnthropicAPI.keychainAccount)
        keyField = ""
        refresh()
        testState = .idle
        NotificationCenter.default.post(name: .assistantAPIKeyChanged, object: nil)
    }

    private func removeKey() {
        Keychain.delete(account: AnthropicAPI.keychainAccount)
        refresh()
        testState = .idle
        NotificationCenter.default.post(name: .assistantAPIKeyChanged, object: nil)
    }

    private func test() {
        let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: AnthropicAPI.keychainAccount) ?? "") : typed
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnthropicAPI.defaultModel : model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        testState = .testing
        Task {
            do {
                let name = try await AnthropicClient.testKey(apiKey: key, model: modelID)
                testState = .ok(name)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
