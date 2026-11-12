import Foundation
import SwiftUI
import Observation

extension Notification.Name {
    /// Posted by Settings when the Anthropic API key is saved or removed.
    static let assistantAPIKeyChanged = Notification.Name("TabulaAssistantAPIKeyChanged")
}

/// Per-workspace AI assistant conversation (Claude Messages API).
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

    var model: String {
        let m = UserDefaults.standard.string(forKey: SettingsKey.anthropicModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? AnthropicAPI.defaultModel : m
    }

    func refreshKeyStatus() {
        let key = Keychain.get(account: AnthropicAPI.keychainAccount) ?? ""
        hasAPIKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        guard hasAPIKey, let key = Keychain.get(account: AnthropicAPI.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

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
        let model = self.model
        task = Task { [weak self] in
            await self?.stream(ws: ws, apiKey: key, model: model, replyID: replyID)
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
        guard let key = Keychain.get(account: AnthropicAPI.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            finish(replyID: reply.id, error: AnthropicAPIError(status: 401, type: "authentication_error", message: "No API key", retryAfter: nil))
            return
        }
        let replyID = reply.id, model = self.model
        task = Task { [weak self] in await self?.stream(ws: ws, apiKey: key, model: model, replyID: replyID) }
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

    private func stream(ws: WorkspaceState, apiKey: String, model: String, replyID: UUID) async {
        let texts = messages.filter { !$0.isError }.reversed().map(\.payload)
        let system = await AssistantContext.systemPrompt(ws: ws, texts: Array(texts))
        guard !Task.isCancelled else { return finish(replyID: replyID, cancelled: true) }
        let body = AnthropicRequest.body(model: model, system: system, messages: apiHistory)

        status = "Waiting for Claude…"
        var receivedText = false
        var attempt = 0
        while true {
            do {
                for try await ev in AnthropicClient.stream(apiKey: apiKey, body: body) {
                    if Task.isCancelled { break }
                    switch ev {
                    case .messageStart(let m):
                        if !m.isEmpty && m != model { update(replyID) { $0.note = "Answered by \(m)" } }
                    case .thinkingStarted:
                        if !receivedText { status = "Thinking…" }
                    case .textDelta(let t):
                        receivedText = true
                        status = nil
                        update(replyID) { $0.text += t }
                    case .fallback(let to):
                        update(replyID) {
                            $0.note = to.isEmpty ? "Continued on a fallback model" : "Continued on \(to)"
                            if !$0.text.isEmpty && !$0.text.hasSuffix("\n") { $0.text += "\n\n" }
                        }
                    case .stop(let reason, let category):
                        switch reason {
                        case "max_tokens":
                            update(replyID) { $0.note = "Reply was cut off (max tokens reached)." }
                        case "refusal":
                            update(replyID) {
                                $0.note = "Claude declined to answer this request" + (category.map { " (\($0))" } ?? "") + ". Try rephrasing."
                                if $0.text.isEmpty { $0.text = "_I can't help with that request._" }
                            }
                        default: break
                        }
                    case .error(let e):
                        throw e
                    case .messageStop, .ignored:
                        break
                    }
                }
                if Task.isCancelled { return finish(replyID: replyID, cancelled: true) }
                return finish(replyID: replyID)
            } catch let e as AnthropicAPIError where e.isRetryable && !receivedText && attempt < 2 && !Task.isCancelled {
                attempt += 1
                let wait = min(e.retryAfter ?? Double(2 << attempt), 12)
                status = e.type == "overloaded_error" ? "Claude is busy — retrying…" : "Retrying…"
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
                    m.text = "Stopped before Claude replied."
                } else {
                    m.note = "Stopped — reply is incomplete."
                }
            }
            if let error {
                let message: String
                if let api = error as? AnthropicAPIError {
                    message = api.localizedDescription
                    m.errorStatus = api.status ?? (api.type == "authentication_error" ? 401 : nil)
                } else if let u = error as? URLError {
                    message = u.code == .notConnectedToInternet || u.code == .networkConnectionLost
                        ? "No internet connection. Check your network and try again."
                        : "Network error: \(u.localizedDescription)"
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
