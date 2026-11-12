import Foundation
import Observation

// MARK: - Provider kinds

/// Wire protocol a provider speaks.
enum AIWireProtocol {
    case anthropicMessages      // POST …/messages (Anthropic, Claude in Azure AI Foundry)
    case openAIChat             // POST …/chat/completions (OpenAI, Azure OpenAI v1 / Foundry models, compatible servers)
    case openAIResponsesAgent   // POST {project}/openai/v1/responses + agent_reference (Azure AI Foundry Agents)
}

enum AIAuthMode: String, Codable, CaseIterable, Identifiable {
    case apiKey
    case entraID   // Microsoft Entra ID token from the Azure CLI (`az login`)
    case none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apiKey: return "API key"
        case .entraID: return "Microsoft Entra ID (Azure CLI)"
        case .none: return "None"
        }
    }
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case azureFoundry        // model deployments in Azure AI Foundry / Azure OpenAI (GPT, o-series, DeepSeek, Grok, Llama, Mistral, Phi…)
    case azureClaude         // Claude deployments in Azure AI Foundry
    case azureAgent          // Azure AI Foundry Agent Service
    case openAI
    case openAICompatible    // OpenRouter, Groq, Mistral, Gemini, DeepSeek, xAI, Together, LM Studio, vLLM…
    case ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude API)"
        case .azureFoundry: return "Azure AI Foundry — model deployment"
        case .azureClaude: return "Azure AI Foundry — Claude"
        case .azureAgent: return "Azure AI Foundry — Agent"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        case .ollama: return "Ollama (local)"
        }
    }

    var shortLabel: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .azureFoundry: return "Azure AI Foundry"
        case .azureClaude: return "Azure AI Foundry · Claude"
        case .azureAgent: return "Foundry Agent"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        case .ollama: return "Ollama"
        }
    }

    var symbol: String {
        switch self {
        case .anthropic, .azureClaude: return "sparkles"
        case .azureFoundry: return "cloud"
        case .azureAgent: return "person.crop.circle.badge.checkmark"
        case .openAI, .openAICompatible: return "circle.hexagongrid"
        case .ollama: return "desktopcomputer"
        }
    }

    var wire: AIWireProtocol {
        switch self {
        case .anthropic, .azureClaude: return .anthropicMessages
        case .azureAgent: return .openAIResponsesAgent
        default: return .openAIChat
        }
    }

    var isAzure: Bool { [.azureFoundry, .azureClaude, .azureAgent].contains(self) }

    var authModes: [AIAuthMode] {
        switch self {
        case .azureFoundry, .azureClaude: return [.apiKey, .entraID]
        case .azureAgent: return [.entraID]
        case .ollama: return [.none, .apiKey]
        case .openAICompatible: return [.apiKey, .none]
        default: return [.apiKey]
        }
    }

    var defaultAuth: AIAuthMode { authModes.first ?? .apiKey }

    var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        default: return ""
        }
    }

    var endpointPrompt: String {
        switch self {
        case .azureFoundry: return "https://<resource>.openai.azure.com  or  https://<resource>.services.ai.azure.com"
        case .azureClaude: return "https://<resource>.services.ai.azure.com"
        case .azureAgent: return "https://<resource>.services.ai.azure.com/api/projects/<project>"
        case .openAICompatible: return "https://openrouter.ai/api/v1"
        default: return defaultEndpoint
        }
    }

    var endpointHelp: String {
        switch self {
        case .azureFoundry: return "Paste the resource endpoint or the deployment's Target URI from the Foundry portal (Models + endpoints). Uses the OpenAI v1 API — no api-version needed."
        case .azureClaude: return "The Foundry resource endpoint (Models + endpoints → your Claude deployment). Tabula calls …/anthropic/v1/messages."
        case .azureAgent: return "The project endpoint from the Foundry portal overview page. Agents require Microsoft Entra ID (run `az login` once in Terminal)."
        case .openAICompatible: return "Base URL of any server that implements the OpenAI Chat Completions API."
        case .ollama: return "Ollama's OpenAI-compatible endpoint. Make sure Ollama is running and the model is pulled."
        default: return ""
        }
    }

    var modelLabel: String {
        switch self {
        case .azureFoundry, .azureClaude: return "Deployment name"
        case .azureAgent: return "Agent name"
        default: return "Model"
        }
    }

    var modelPrompt: String {
        switch self {
        case .anthropic: return AnthropicAPI.defaultModel
        case .azureFoundry: return "e.g. gpt-5-mini, DeepSeek-R1, grok-4"
        case .azureClaude: return "e.g. claude-sonnet-4-6"
        case .azureAgent: return "e.g. sql-helper"
        case .openAI: return "e.g. gpt-5"
        case .openAICompatible: return "model id"
        case .ollama: return "e.g. qwen3-coder, llama3.3"
        }
    }

    /// Entra ID token audience for Azure kinds.
    var tokenResource: String {
        switch self {
        case .azureFoundry: return "https://cognitiveservices.azure.com"
        default: return "https://ai.azure.com"
        }
    }
}

/// Well-known OpenAI-compatible services offered as presets.
struct AICompatiblePreset: Identifiable {
    let name: String
    let endpoint: String
    let model: String
    var id: String { name }

    static let all: [AICompatiblePreset] = [
        .init(name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5"),
        .init(name: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-pro"),
        .init(name: "Mistral", endpoint: "https://api.mistral.ai/v1", model: "mistral-large-latest"),
        .init(name: "DeepSeek", endpoint: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        .init(name: "xAI (Grok)", endpoint: "https://api.x.ai/v1", model: "grok-4"),
        .init(name: "Groq", endpoint: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        .init(name: "Together AI", endpoint: "https://api.together.xyz/v1", model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        .init(name: "LM Studio (local)", endpoint: "http://localhost:1234/v1", model: ""),
        .init(name: "Foundry Local", endpoint: "http://localhost:5273/v1", model: ""),
    ]
}

// MARK: - Profiles

struct AIProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: AIProviderKind
    var endpoint: String
    var model: String
    var auth: AIAuthMode
    /// Optional override for the Entra ID token audience.
    var tokenResource: String = ""

    init(name: String, kind: AIProviderKind, endpoint: String? = nil, model: String = "", auth: AIAuthMode? = nil) {
        self.name = name
        self.kind = kind
        self.endpoint = endpoint ?? kind.defaultEndpoint
        self.model = model
        self.auth = auth ?? kind.defaultAuth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(AIProviderKind.self, forKey: .kind)) ?? .anthropic
        name = (try? c.decode(String.self, forKey: .name)) ?? kind.shortLabel
        endpoint = (try? c.decode(String.self, forKey: .endpoint)) ?? kind.defaultEndpoint
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        auth = (try? c.decode(AIAuthMode.self, forKey: .auth)) ?? kind.defaultAuth
        tokenResource = (try? c.decode(String.self, forKey: .tokenResource)) ?? ""
    }

    var keychainAccount: String { "ai-key-\(id.uuidString)" }
    var effectiveModel: String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty && kind == .anthropic { return AnthropicAPI.defaultModel }
        return m
    }
    var effectiveTokenResource: String {
        let r = tokenResource.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? kind.tokenResource : r
    }

    /// Short label for menus: "Name · model".
    var menuTitle: String {
        let m = effectiveModel
        return m.isEmpty || name.localizedCaseInsensitiveContains(m) ? name : "\(name) · \(m)"
    }

    var apiKey: String? {
        let k = Keychain.get(account: keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? nil : k
    }

    /// Why this profile can't be used yet (nil when ready).
    var setupProblem: String? {
        if effectiveModel.isEmpty { return "\(kind.modelLabel) is missing." }
        if kind != .anthropic && kind != .openAI && kind != .ollama && endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Endpoint is missing."
        }
        if auth == .apiKey && apiKey == nil { return "API key is missing." }
        if auth == .entraID && AzureCLI.path == nil { return "Azure CLI not found — install it (brew install azure-cli) and run `az login`, or use an API key." }
        return nil
    }

    // MARK: Endpoint normalisation

    private var trimmedEndpoint: String {
        var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = kind.defaultEndpoint }
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        return s
    }

    /// `scheme://host[:port]` of the endpoint.
    private var origin: String {
        guard let c = URLComponents(string: trimmedEndpoint), let scheme = c.scheme, let host = c.host else { return trimmedEndpoint }
        return "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")"
    }

    /// Base URL the request path is appended to.
    var baseURL: URL? {
        switch kind {
        case .anthropic, .openAI, .openAICompatible, .ollama:
            var s = trimmedEndpoint
            for suffix in ["/chat/completions", "/messages", "/responses"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
            while s.hasSuffix("/") { s.removeLast() }
            return URL(string: s)
        case .azureFoundry:
            return URL(string: origin + "/openai/v1")
        case .azureClaude:
            return URL(string: origin + "/anthropic/v1")
        case .azureAgent:
            // keep "/api/projects/<name>" — that's the project endpoint
            guard let c = URLComponents(string: trimmedEndpoint) else { return nil }
            let parts = c.path.split(separator: "/")
            if let i = parts.firstIndex(of: "projects"), i + 1 < parts.count {
                return URL(string: origin + "/" + parts[...(i + 1)].joined(separator: "/"))
            }
            return URL(string: trimmedEndpoint)
        }
    }

    /// Deployment name embedded in a pasted Azure "Target URI" (…/deployments/<name>/…).
    static func deploymentName(fromEndpoint s: String) -> String? {
        guard let r = s.range(of: "/deployments/") else { return nil }
        let rest = s[r.upperBound...]
        let name = rest.prefix { $0 != "/" && $0 != "?" }
        return name.isEmpty ? nil : String(name)
    }
}

/// Persisted list of AI provider profiles + the active one.
@MainActor
@Observable
final class AIProfileStore {
    static let shared = AIProfileStore()
    private(set) var profiles: [AIProfile] = []
    var activeID: UUID? {
        didSet {
            UserDefaults.standard.set(activeID?.uuidString, forKey: "aiActiveProfile")
            NotificationCenter.default.post(name: .assistantAPIKeyChanged, object: nil)
        }
    }

    private var url: URL { AppPaths.support.appendingPathComponent("ai-profiles.json") }

    private init() {
        if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([AIProfile].self, from: data) {
            profiles = p
        }
        activeID = UserDefaults.standard.string(forKey: "aiActiveProfile").flatMap(UUID.init)
        migrateLegacyAnthropicKey()
        if activeID == nil || !profiles.contains(where: { $0.id == activeID }) { activeID = profiles.first?.id }
    }

    /// Earlier versions stored a single Anthropic key; turn it into a profile.
    private func migrateLegacyAnthropicKey() {
        guard profiles.isEmpty, let key = Keychain.get(account: AnthropicAPI.keychainAccount), !key.isEmpty else { return }
        var p = AIProfile(name: "Claude", kind: .anthropic)
        p.model = UserDefaults.standard.string(forKey: SettingsKey.anthropicModel) ?? AnthropicAPI.defaultModel
        Keychain.set(key, account: p.keychainAccount)
        profiles = [p]
        activeID = p.id
        save()
    }

    var active: AIProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) { try? data.write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: .assistantAPIKeyChanged, object: nil)
    }

    func upsert(_ p: AIProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        if activeID == nil { activeID = p.id }
        save()
    }

    func delete(_ id: UUID) {
        if let p = profiles.first(where: { $0.id == id }) { Keychain.delete(account: p.keychainAccount) }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles.first?.id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        save()
    }
}

// MARK: - Azure CLI (Microsoft Entra ID tokens)

enum AzureCLI {
    static var path: String? {
        if let p = ProcessInfo.processInfo.environment["TABULA_AZ_PATH"], FileManager.default.isExecutableFile(atPath: p) { return p }
        for p in ["/opt/homebrew/bin/az", "/usr/local/bin/az", "/usr/bin/az"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private struct Cached { let token: String; let expires: Date }
    private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    /// Access token for `resource` (cached until 5 minutes before expiry). Blocking — call off the main thread.
    static func token(resource: String) throws -> String {
        lock.lock()
        if let c = cache[resource], c.expires.timeIntervalSinceNow > 300 { lock.unlock(); return c.token }
        lock.unlock()
        guard let az = path else {
            throw AIProviderError(message: "Azure CLI not found. Install it with `brew install azure-cli`, run `az login`, or switch this provider to an API key.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: az)
        p.arguments = ["account", "get-access-token", "--resource", resource, "--output", "json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["accessToken"] as? String else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hint = msg.contains("az login") || msg.contains("AADSTS") ? "" : " Run `az login` in Terminal."
            throw AIProviderError(message: "Couldn't get a Microsoft Entra ID token from the Azure CLI." + hint + (msg.isEmpty ? "" : "\n\(msg.prefix(400))"))
        }
        var expires = Date().addingTimeInterval(45 * 60)
        if let ts = obj["expires_on"] as? Double { expires = Date(timeIntervalSince1970: ts) }
        else if let ts = obj["expires_on"] as? Int { expires = Date(timeIntervalSince1970: Double(ts)) }
        lock.lock()
        cache[resource] = Cached(token: token, expires: expires)
        lock.unlock()
        return token
    }

    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

/// Provider-agnostic API error.
struct AIProviderError: LocalizedError, Equatable {
    var status: Int?
    var message: String
    var retryAfter: Double?
    var isRetryable: Bool = false

    var errorDescription: String? { message }

    static func from(status: Int, body: Data, retryAfter: String?, provider: String) -> AIProviderError {
        var detail = ""
        var code = ""
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let e = obj["error"] as? [String: Any] {
                detail = (e["message"] as? String) ?? ""
                code = (e["code"] as? String) ?? (e["type"] as? String) ?? ""
            } else if let m = obj["message"] as? String {
                detail = m
            } else if let e = obj["error"] as? String {
                detail = e
            }
        }
        if detail.isEmpty { detail = String(data: body.prefix(400), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let retry = retryAfter.flatMap(Double.init)
        let summary: String
        var retryable = false
        switch status {
        case 401: summary = "\(provider) rejected the credentials (401). Check the API key, or run `az login` for Entra ID."
        case 403: summary = "Access denied by \(provider) (403). Your identity may lack a role such as “Azure AI User” / “Cognitive Services OpenAI User”."
        case 404: summary = "Not found (404). Check the endpoint and the \(provider == "Foundry Agent" ? "agent" : "deployment/model") name."
        case 400 where code == "content_filter" || detail.lowercased().contains("content management policy"):
            summary = "The request was blocked by the content filter."
        case 400: summary = "Bad request (400)."
        case 408, 409: summary = "\(provider) timed out (\(status))."; retryable = true
        case 429: summary = "Rate limited by \(provider) (429)" + (retry.map { " — retry in \(Int($0))s" } ?? "") + "."; retryable = true
        case 500...599: summary = "\(provider) had a server error (\(status))."; retryable = true
        default: summary = "\(provider) returned HTTP \(status)."
        }
        return AIProviderError(status: status, message: detail.isEmpty ? summary : "\(summary)\n\(detail)", retryAfter: retry, isRetryable: retryable)
    }
}
