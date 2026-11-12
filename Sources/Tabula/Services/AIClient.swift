import Foundation

/// Provider-agnostic streaming events.
enum AIStreamEvent: Equatable {
    case model(String)
    case text(String)
    case thinking
    case status(String)
    case stop(reason: String)          // "done", "max_tokens", "content_filter", "refusal"
    case failure(AIProviderError)
    case ignored
}

/// Streams chat replies from any configured provider.
enum AIClient {
    // MARK: Requests

    /// Auth headers for a profile. Blocking for Entra ID (Azure CLI); call off the main thread.
    static func authHeaders(_ p: AIProfile) throws -> [String: String] {
        switch p.auth {
        case .none:
            return [:]
        case .entraID:
            return ["Authorization": "Bearer " + (try AzureCLI.token(resource: p.effectiveTokenResource))]
        case .apiKey:
            guard let key = p.apiKey else { throw AIProviderError(message: "No API key saved for “\(p.name)”. Add one in Settings › AI.") }
            switch p.kind {
            case .anthropic, .azureClaude: return ["x-api-key": key]
            case .azureFoundry: return ["api-key": key]
            case .azureAgent, .openAI, .openAICompatible, .ollama: return ["Authorization": "Bearer \(key)"]
            }
        }
    }

    static func request(_ p: AIProfile, system: String, messages: [AnthropicMessage], stream: Bool = true) throws -> URLRequest {
        guard let base = p.baseURL else { throw AIProviderError(message: "The endpoint “\(p.endpoint)” isn't a valid URL.") }
        let model = p.effectiveModel
        let history = AnthropicRequest.normalized(messages)
        var body: [String: Any]
        var headers = try authHeaders(p)
        headers["content-type"] = "application/json"
        headers["accept"] = stream ? "text/event-stream" : "application/json"
        let path: String
        switch p.kind.wire {
        case .anthropicMessages:
            path = "messages"
            body = AnthropicRequest.body(model: model, system: system, messages: history, stream: stream)
            if p.kind == .anthropic {
                headers["anthropic-version"] = AnthropicAPI.apiVersion
                if AnthropicAPI.supportsDefaultFallbacks(model) { headers["anthropic-beta"] = AnthropicAPI.fallbackBeta }
            } else {
                // Claude in Azure AI Foundry: documented API version; Anthropic-only extras removed.
                headers["anthropic-version"] = "2023-06-01"
                body.removeValue(forKey: "fallbacks")
                body.removeValue(forKey: "cache_control")
                body["max_tokens"] = 32000
            }
        case .openAIChat:
            path = "chat/completions"
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += history.map { ["role": $0.role.rawValue, "content": $0.text] }
            body = ["model": model, "messages": msgs, "stream": stream]
        case .openAIResponsesAgent:
            path = "openai/v1/responses"
            // The agent has its own instructions; the database context travels with the first user turn.
            var input: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
            if let i = input.firstIndex(where: { $0["role"] as? String == "user" }) {
                input[i]["content"] = "<database_context>\n\(system)\n</database_context>\n\n" + (input[i]["content"] as? String ?? "")
            }
            body = ["input": input, "stream": stream, "agent_reference": ["name": model, "type": "agent_reference"]]
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    // MARK: Decoding

    static func decode(_ e: SSEEvent, wire: AIWireProtocol) -> [AIStreamEvent] {
        switch wire {
        case .anthropicMessages:
            switch AnthropicStreamEvent.decode(e) {
            case .messageStart(let m): return [.model(m)]
            case .textDelta(let t): return [.text(t)]
            case .thinkingStarted: return [.thinking]
            case .fallback(let to): return [.status(to.isEmpty ? "Continued on a fallback model" : "Continued on \(to)")]
            case .stop(let reason, _): return [.stop(reason: reason == "end_turn" ? "done" : reason)]
            case .messageStop: return [.stop(reason: "done")]
            case .error(let err):
                return [.failure(AIProviderError(status: err.status, message: err.localizedDescription, retryAfter: err.retryAfter, isRetryable: err.isRetryable))]
            case .ignored: return [.ignored]
            }
        case .openAIChat:
            let data = e.data.trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { return [.stop(reason: "done")] }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return [.ignored] }
            if let err = obj["error"] as? [String: Any] {
                return [.failure(AIProviderError(message: (err["message"] as? String) ?? "The model returned an error."))]
            }
            var out: [AIStreamEvent] = []
            if let m = obj["model"] as? String, !m.isEmpty { out.append(.model(m)) }
            for choice in (obj["choices"] as? [[String: Any]]) ?? [] {
                if let delta = choice["delta"] as? [String: Any] {
                    if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty { out.append(.thinking) }
                    if let t = delta["content"] as? String, !t.isEmpty { out.append(.text(t)) }
                }
                switch choice["finish_reason"] as? String {
                case "length": out.append(.stop(reason: "max_tokens"))
                case "content_filter": out.append(.stop(reason: "content_filter"))
                default: break
                }
            }
            return out.isEmpty ? [.ignored] : out
        case .openAIResponsesAgent:
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(e.data.utf8))) as? [String: Any] else { return [.ignored] }
            let type = (obj["type"] as? String) ?? e.event
            switch type {
            case "response.output_text.delta":
                return [.text(obj["delta"] as? String ?? "")]
            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.reasoning_summary_part.added":
                return [.thinking]
            case "response.output_item.added":
                let item = obj["item"] as? [String: Any]
                let t = item?["type"] as? String ?? ""
                if t.hasSuffix("_call") {
                    let tool = t.replacingOccurrences(of: "_call", with: "").replacingOccurrences(of: "_", with: " ")
                    return [.status("Agent is using \(tool)…")]
                }
                return [.ignored]
            case "response.created":
                let resp = obj["response"] as? [String: Any]
                return [.model((resp?["model"] as? String) ?? "")]
            case "response.completed": return [.stop(reason: "done")]
            case "response.incomplete": return [.stop(reason: "max_tokens")]
            case "response.failed":
                let resp = obj["response"] as? [String: Any]
                let err = resp?["error"] as? [String: Any]
                return [.failure(AIProviderError(message: (err?["message"] as? String) ?? "The agent run failed."))]
            case "error":
                return [.failure(AIProviderError(message: (obj["message"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? "The agent returned an error."))]
            default:
                return [.ignored]
            }
        }
    }

    // MARK: Streaming

    static func stream(profile p: AIProfile, system: String, messages: [AnthropicMessage],
                       session: URLSession = .shared) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let req = try request(p, system: system, messages: messages)
                    let (bytes, response) = try await session.bytes(for: req)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 64_000 { break }
                        }
                        if p.auth == .entraID && status == 401 { AzureCLI.clearCache() }
                        throw AIProviderError.from(status: status, body: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"), provider: p.kind.shortLabel)
                    }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    line.reserveCapacity(1024)
                    func emit(_ e: SSEEvent) throws {
                        for ev in decode(e, wire: p.kind.wire) {
                            if case .failure(let err) = ev { throw err }
                            continuation.yield(ev)
                        }
                    }
                    for try await b in bytes {
                        if b == 0x0A {
                            if let e = parser.feed(String(decoding: line, as: UTF8.self)) { try emit(e) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if !line.isEmpty, let e = parser.feed(String(decoding: line, as: UTF8.self)) { try emit(e) }
                    if let e = parser.finish() { try emit(e) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends a tiny prompt and returns a short description of the reply (model + text).
    static func test(_ p: AIProfile) async throws -> String {
        var text = ""
        var model = ""
        for try await ev in stream(profile: p, system: "You are a connectivity check. Reply with exactly: OK",
                                   messages: [AnthropicMessage(role: .user, text: "Reply with exactly: OK")]) {
            switch ev {
            case .model(let m): if !m.isEmpty { model = m }
            case .text(let t): text += t; if text.count > 200 { break }
            default: break
            }
        }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Connected\(model.isEmpty ? "" : " to \(model)")" + (reply.isEmpty ? "" : " — replied “\(reply.prefix(60))”")
    }
}
