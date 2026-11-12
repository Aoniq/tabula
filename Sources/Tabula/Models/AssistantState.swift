import Foundation
import SwiftUI
import Observation

extension Notification.Name {
    /// Posted by Settings when the Anthropic API key is saved or removed.
    static let assistantAPIKeyChanged = Notification.Name("TabulaAssistantAPIKeyChanged")
}

/// Per-workspace AI assistant conversation (any configured AI provider profile).
@MainActor
@Observable
final class AssistantState {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        /// What the chat shows.
        var text: String
        /// What is sent to the API (user turns may carry editor context). nil = same as `text`.
        var apiText: String?
        /// Short label for attached editor context, e.g. "Query 1 + error".
        var attachment: String?
        var isStreaming = false
        var isError = false
        var errorStatus: Int?
        /// Small caption under a reply (stopped, truncated, fallback model…).
        var note: String?

        var payload: String { apiText ?? text }
    }

    enum QuickAction: CaseIterable {
        case explain, fixError, optimize, write

        var title: String {
            switch self {
            case .explain: return "Explain query"
            case .fixError: return "Fix last error"
            case .optimize: return "Optimize query"
            case .write: return "Write a query…"
            }
        }

        var symbol: String {
            switch self {
            case .explain: return "text.magnifyingglass"
            case .fixError: return "wrench.and.screwdriver"
            case .optimize: return "gauge.with.dots.needle.67percent"
            case .write: return "square.and.pencil"
            }
        }

        var prompt: String {
            switch self {
            case .explain:
                return "Explain the query in the editor: what it returns or changes, step by step, in plain language. Point out anything risky or surprising (missing join conditions, accidental cross joins, NULL handling, writes, full scans)."
            case .fixError:
                return "The query in the editor failed with the error shown. Briefly explain the cause, then give the corrected query in a ```sql block."
            case .optimize:
                return "Suggest how to make the query in the editor faster. Rewrite it if that helps, and propose supporting indexes as separate CREATE INDEX statements. Explain the trade-offs briefly and mention how to verify with EXPLAIN."
            case .write:
                return ""
            }
        }

        var displayText: String {
            switch self {
            case .explain: return "Explain the current query"
            case .fixError: return "Fix the last error"
            case .optimize: return "Optimize the current query"
            case .write: return ""
            }
        }
    }

    var messages: [Message] = []
    var draft = ""
    private(set) var isStreaming = false
    /// Transient status shown while waiting ("Reading schema…", "Thinking…").
    private(set) var status: String?
    private(set) var hasAPIKey = false
    /// Incremented to ask the input field to take focus.
    private(set) var focusRequest = 0

    private var task: Task<Void, Never>?
    private var lastAttachmentSignature: String?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    init() {
        refreshKeyStatus()
        keyObserver = NotificationCenter.default.addObserver(forName: .assistantAPIKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyStatus() }
        }
    }

    /// The provider profile used for new messages.
    var profile: AIProfile? { AIProfileStore.shared.active }

    var model: String { profile?.effectiveModel ?? "" }

    /// Name shown in status lines ("Waiting for …").
    var providerName: String { profile?.name ?? "the model" }

    func refreshKeyStatus() {
        // "Configured" = there is an active profile; credential problems surface as a clear error on send.
        hasAPIKey = AIProfileStore.shared.active != nil
    }

    // MARK: Quick actions

    func canRun(_ action: QuickAction, ws: WorkspaceState) -> Bool {
        guard !isStreaming else { return false }
        switch action {
        case .write: return true
        case .explain, .optimize:
            if let q = ws.selectedQueryTab { return !q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return !(ws.selectedTableTab?.lastQuery.isEmpty ?? true)
        case .fixError:
            return ws.selectedQueryTab?.error != nil || ws.selectedTableTab?.error != nil
        }
    }

    func perform(_ action: QuickAction, ws: WorkspaceState) {
        if action == .write {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = "Write a query that " }
            focusRequest += 1
            return
        }
        guard canRun(action, ws: ws) else { return }
        send(display: action.displayText, instruction: action.prompt, ws: ws, forceAttachment: true)
    }

    // MARK: Sending

    func sendDraft(ws: WorkspaceState) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        send(display: text, instruction: text, ws: ws, forceAttachment: false)
    }

    private func send(display: String, instruction: String, ws: WorkspaceState, forceAttachment: Bool) {
        guard !isStreaming else { return }
        refreshKeyStatus()
        guard hasAPIKey, let profile = self.profile else { return }

        var user = Message(role: .user, text: display)
        if let att = AssistantContext.editorAttachment(ws: ws),
           forceAttachment || att.signature != lastAttachmentSignature {
            user.apiText = att.text + "\n\n" + instruction
            user.attachment = att.label
            lastAttachmentSignature = att.signature
        } else if instruction != display {
            user.apiText = instruction
        }
        messages.append(user)
        var reply = Message(role: .assistant, text: "")
        reply.isStreaming = true
        messages.append(reply)
        isStreaming = true
        status = "Reading schema…"

        let replyID = reply.id
        if let problem = profile.setupProblem {
            return finish(replyID: replyID, error: AIProviderError(status: 401, message: "“\(profile.name)” isn't fully set up: \(problem) Open Settings › AI to fix it."))
        }
        task = Task { [weak self] in
            await self?.stream(ws: ws, profile: profile, replyID: replyID)
        }
    }

    func stop() {
        task?.cancel()
    }

    func newChat() {
        task?.cancel()
        task = nil
        messages = []
        isStreaming = false
        status = nil
        lastAttachmentSignature = nil
        focusRequest += 1
    }

    /// Re-send the last user message after an error.
    func retry(ws: WorkspaceState) {
        guard !isStreaming, let lastUser = messages.lastIndex(where: { $0.role == .user }) else { return }
        let user = messages[lastUser]
        messages.removeSubrange(lastUser...)
        messages.append(user)
        var reply = Message(role: .assistant, text: "")
        reply.isStreaming = true
        messages.append(reply)
        isStreaming = true
        status = "Reading schema…"
        refreshKeyStatus()
        guard let profile = self.profile else {
            finish(replyID: reply.id, error: AIProviderError(status: 401, message: "No AI provider is configured. Add one in Settings › AI."))
            return
        }
        if let problem = profile.setupProblem {
            finish(replyID: reply.id, error: AIProviderError(status: 401, message: "“\(profile.name)” isn't fully set up: \(problem)"))
            return
        }
        let replyID = reply.id
        task = Task { [weak self] in await self?.stream(ws: ws, profile: profile, replyID: replyID) }
    }

    /// Conversation as sent to the API (errors and empty replies dropped; consecutive roles merged by the request builder).
    var apiHistory: [AnthropicMessage] {
        let usable = messages.filter { !$0.isError && !$0.isStreaming }
        return usable.suffix(40).map { AnthropicMessage(role: $0.role == .user ? .user : .assistant, text: $0.payload) }
    }

    private func update(_ id: UUID, _ body: (inout Message) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        body(&messages[i])
    }

    private func stream(ws: WorkspaceState, profile: AIProfile, replyID: UUID) async {
        let texts = messages.filter { !$0.isError }.reversed().map(\.payload)
        let system = await AssistantContext.systemPrompt(ws: ws, texts: Array(texts))
        guard !Task.isCancelled else { return finish(replyID: replyID, cancelled: true) }
        let history = apiHistory
        let model = profile.effectiveModel
        update(replyID) { $0.note = nil }

        status = profile.auth == .entraID ? "Signing in with Microsoft Entra ID…" : "Waiting for \(profile.name)…"
        var receivedText = false
        var attempt = 0
        while true {
            do {
                for try await ev in AIClient.stream(profile: profile, system: system, messages: history) {
                    if Task.isCancelled { break }
                    switch ev {
                    case .model(let m):
                        if !receivedText && status?.hasPrefix("Signing in") == true { status = "Waiting for \(profile.name)…" }
                        if !m.isEmpty && !m.lowercased().hasPrefix(model.lowercased()) && profile.kind != .azureAgent && profile.kind.wire == .anthropicMessages {
                            update(replyID) { $0.note = "Answered by \(m)" }
                        }
                    case .thinking:
                        if !receivedText { status = "Thinking…" }
                    case .status(let st):
                        if st.hasPrefix("Continued on") {
                            update(replyID) {
                                $0.note = st
                                if !$0.text.isEmpty && !$0.text.hasSuffix("\n") { $0.text += "\n\n" }
                            }
                        } else if !receivedText {
                            status = st
                        }
                    case .text(let t):
                        receivedText = true
                        status = nil
                        update(replyID) { $0.text += t }
                    case .stop(let reason):
                        switch reason {
                        case "max_tokens":
                            update(replyID) { $0.note = "Reply was cut off (output limit reached)." }
                        case "refusal":
                            update(replyID) {
                                $0.note = "The model declined to answer this request. Try rephrasing."
                                if $0.text.isEmpty { $0.text = "_I can't help with that request._" }
                            }
                        case "content_filter":
                            update(replyID) { $0.note = "Part of the reply was blocked by the provider's content filter." }
                        default: break
                        }
                    case .failure(let e):
                        throw e
                    case .ignored:
                        break
                    }
                }
                if Task.isCancelled { return finish(replyID: replyID, cancelled: true) }
                return finish(replyID: replyID)
            } catch let e as AIProviderError where e.isRetryable && !receivedText && attempt < 2 && !Task.isCancelled {
                attempt += 1
                let wait = min(e.retryAfter ?? Double(2 << attempt), 12)
                status = "\(profile.name) is busy — retrying…"
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return finish(replyID: replyID, cancelled: true) }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    return finish(replyID: replyID, cancelled: true)
                }
                return finish(replyID: replyID, error: error)
            }
        }
    }

    private func finish(replyID: UUID, cancelled: Bool = false, error: Error? = nil) {
        update(replyID) { m in
            m.isStreaming = false
            if cancelled {
                if m.text.isEmpty {
                    m.isError = true
                    m.text = "Stopped before \(providerName) replied."
                } else {
                    m.note = "Stopped — reply is incomplete."
                }
            }
            if let error {
                let message: String
                if let api = error as? AIProviderError {
                    message = api.localizedDescription
                    m.errorStatus = api.status
                } else if let api = error as? AnthropicAPIError {
                    message = api.localizedDescription
                    m.errorStatus = api.status ?? (api.type == "authentication_error" ? 401 : nil)
                } else if let u = error as? URLError {
                    message = u.code == .cannotConnectToHost && (profile?.kind == .ollama || (profile?.endpoint.contains("localhost") ?? false))
                        ? "Couldn't reach \(profile?.endpoint ?? "the local server"). Is it running?"
                        : (u.code == .notConnectedToInternet || u.code == .networkConnectionLost
                            ? "No internet connection. Check your network and try again."
                            : "Network error: \(u.localizedDescription)")
                } else {
                    message = error.localizedDescription
                }
                if m.text.isEmpty {
                    m.isError = true
                    m.text = message
                } else {
                    m.note = "Interrupted: \(message)"
                }
            }
        }
        isStreaming = false
        status = nil
        task = nil
    }
}
