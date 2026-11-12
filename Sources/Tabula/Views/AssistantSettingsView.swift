import SwiftUI
import AppKit

/// Settings › AI: manage provider profiles (Anthropic, Azure AI Foundry, OpenAI, compatible servers, Ollama).
struct AssistantSettingsView: View {
    @State private var store = AIProfileStore.shared
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.profiles) { p in
                        HStack(spacing: 8) {
                            Image(systemName: p.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).lineLimit(1)
                                Text(p.kind.shortLabel + (p.effectiveModel.isEmpty ? "" : " · \(p.effectiveModel)"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if p.id == store.activeID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).help("Used by the assistant")
                            } else if p.setupProblem != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(p.setupProblem ?? "")
                            }
                        }
                        .tag(p.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        ForEach(AIProviderKind.allCases) { k in
                            Button(k.label) { add(k) }
                        }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Button {
                        if let s = selection { store.delete(s); selection = store.profiles.first?.id }
                    } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 210)
            Divider()
            if let id = selection, let p = store.profiles.first(where: { $0.id == id }) {
                AIProfileEditor(profile: p).id(p.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
                    Text("Add an AI provider").font(.headline)
                    Text("Use Claude, Azure AI Foundry (model deployments, Claude, Agents), OpenAI, any OpenAI-compatible service, or a local model via Ollama.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                    Menu("Add Provider") {
                        ForEach(AIProviderKind.allCases) { k in Button(k.label) { add(k) } }
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.activeID ?? store.profiles.first?.id } }
    }

    private func add(_ kind: AIProviderKind) {
        var p = AIProfile(name: kind.shortLabel, kind: kind)
        if kind == .anthropic { p.model = AnthropicAPI.defaultModel }
        store.upsert(p)
        selection = p.id
    }
}

struct AIProfileEditor: View {
    @State var profile: AIProfile
    @State private var key = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var store = AIProfileStore.shared

    init(profile: AIProfile) {
        _profile = State(initialValue: profile)
        _hasKey = State(initialValue: profile.apiKey != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Provider", selection: $profile.kind) {
                    ForEach(AIProviderKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: profile.kind) { old, new in
                    if profile.endpoint.isEmpty || profile.endpoint == old.defaultEndpoint { profile.endpoint = new.defaultEndpoint }
                    if !new.authModes.contains(profile.auth) { profile.auth = new.defaultAuth }
                    if profile.name == old.shortLabel { profile.name = new.shortLabel }
                }
            }
            Section {
                if profile.kind != .anthropic && profile.kind != .openAI {
                    HStack {
                        TextField("Endpoint", text: $profile.endpoint, prompt: Text(profile.kind.endpointPrompt))
                            .onChange(of: profile.endpoint) { _, v in
                                if profile.kind == .azureFoundry, profile.model.isEmpty, let d = AIProfile.deploymentName(fromEndpoint: v) { profile.model = d }
                            }
                        if profile.kind == .openAICompatible {
                            Menu("Presets") {
                                ForEach(AICompatiblePreset.all) { pr in
                                    Button(pr.name) {
                                        profile.endpoint = pr.endpoint
                                        if !pr.model.isEmpty { profile.model = pr.model }
                                        if profile.name == AIProviderKind.openAICompatible.shortLabel { profile.name = pr.name }
                                        if pr.endpoint.contains("localhost") { profile.auth = .none }
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if !profile.kind.endpointHelp.isEmpty {
                        Text(profile.kind.endpointHelp).font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = profile.baseURL, profile.kind.isAzure {
                        Text("Calls \(url.absoluteString)/\(profile.kind.wire == .anthropicMessages ? "messages" : (profile.kind.wire == .openAIChat ? "chat/completions" : "openai/v1/responses"))")
                            .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                HStack {
                    TextField(profile.kind.modelLabel, text: $profile.model, prompt: Text(profile.kind.modelPrompt))
                    if profile.kind == .anthropic {
                        Menu("Models") {
                            ForEach(AnthropicAPI.knownModels, id: \.id) { m in Button(m.label) { profile.model = m.id } }
                        }
                        .fixedSize()
                    }
                }
            } header: { Text("Endpoint & Model") }

            Section {
                if profile.kind.authModes.count > 1 {
                    Picker("Authentication", selection: $profile.auth) {
                        ForEach(profile.kind.authModes) { Text($0.label).tag($0) }
                    }
                }
                switch profile.auth {
                case .apiKey:
                    HStack {
                        SecureField(hasKey ? "Saved in Keychain — paste to replace" : "API key", text: $key)
                        if hasKey {
                            Button("Remove") {
                                Keychain.delete(account: profile.keychainAccount)
                                hasKey = false
                                store.save()
                            }
                        }
                    }
                    if profile.kind.isAzure {
                        Text("Foundry portal → your resource → Keys and Endpoint (or the deployment's details page).").font(.caption).foregroundStyle(.secondary)
                    }
                case .entraID:
                    if let az = AzureCLI.path {
                        Text("Uses your Azure CLI sign-in (\(az)). Run `az login` in Terminal once; tokens refresh automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Azure CLI not found. Install it with `brew install azure-cli`, then run `az login`.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Token audience", text: $profile.tokenResource, prompt: Text(profile.kind.tokenResource))
                        .font(.caption)
                case .none:
                    Text("No authentication — typical for local servers.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Authentication") }

            Section {
                HStack {
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    Button("Test") { Task { await test() } }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if store.activeID == profile.id {
                        Label("Used by the assistant", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).font(.callout)
                    } else {
                        Button("Use for Assistant") { save(); store.activeID = profile.id }
                    }
                }
                if let r = result {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                        .font(.callout)
                        .textSelection(.enabled)
                } else if let problem = profile.setupProblem, !(profile.auth == .apiKey && !key.isEmpty && problem.contains("API key")) {
                    Label(problem, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                Text("Only table and column definitions and your current query are sent — never row data.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty {
            Keychain.set(k, account: profile.keychainAccount)
            key = ""
            hasKey = true
        }
        profile.name = profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? profile.kind.shortLabel : profile.name
        store.upsert(profile)
    }

    private func test() async {
        save()
        testing = true
        result = nil
        if let problem = profile.setupProblem {
            result = (false, problem)
            testing = false
            return
        }
        do {
            result = (true, try await AIClient.test(profile))
        } catch {
            result = (false, error.localizedDescription)
        }
        testing = false
    }
}
