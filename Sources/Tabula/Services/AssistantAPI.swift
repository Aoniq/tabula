import Foundation

// Minimal Claude Messages API client (raw HTTP + SSE streaming via URLSession).
// Pure Foundation so it can be exercised outside the app.

enum AnthropicAPI {
    static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2026-10-21"
    static let keychainAccount = "anthropic-api-key"
    static let defaultModel = "claude-opus-5-5"

    /// Model ids offered in Settings (the text field accepts any id).
    static let knownModels: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (recommended)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest, cheapest)"),
        ("claude-fable-5-2", "Claude Fable 5.2 (most capable, priciest)"),
    ]

    /// Current-generation models accept adaptive thinking + `output_config.effort`.
    /// Older ids (e.g. claude-haiku-4-5, claude-sonnet-4-5) reject them, so they are left out there.
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        let m = model.lowercased()
        let prefixes = ["claude-fable-", "claude-mythos-", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
                        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return prefixes.contains { m.hasPrefix($0) }
    }

    /// Models that support server-side refusal fallbacks with `fallbacks: "default"`.
    static func supportsDefaultFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-fable-5-2"].contains(model.lowercased())
    }

    static let fallbackBeta = "server-side-fallback-2026-07-01"
}

// MARK: - Request

struct AnthropicMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

enum AnthropicRequest {
    /// JSON body for a streaming Messages request.
    static func body(model: String, system: String, messages: [AnthropicMessage], maxTokens: Int = 64000,
                     stream: Bool = true, effort: String = "medium") -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            "system": system,
            "messages": normalized(messages).map { ["role": $0.role.rawValue, "content": $0.text] },
            // Auto-place a prompt-cache breakpoint on the last cacheable block so follow-up turns reuse the prefix.
            "cache_control": ["type": "ephemeral"],
        ]
        if AnthropicAPI.supportsAdaptiveThinking(model) {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        if AnthropicAPI.supportsDefaultFallbacks(model) {
            body["fallbacks"] = "default"
        }
        return body
    }

    /// The API requires the first message to be from the user and roles to alternate; merge/drop to satisfy that.
    static func normalized(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
        var out: [AnthropicMessage] = []
        for m in messages {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if out.isEmpty && m.role != .user { continue }
            if let last = out.last, last.role == m.role {
                out[out.count - 1].text += "\n\n" + text
            } else {
                out.append(AnthropicMessage(role: m.role, text: text))
            }
        }
        // A trailing assistant turn would be a prefill, which current models reject.
        while out.last?.role == .assistant { out.removeLast() }
        return out
    }

    static func headers(apiKey: String, model: String) -> [String: String] {
        var h = [
            "content-type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": AnthropicAPI.apiVersion,
            "accept": "text/event-stream",
        ]
        if AnthropicAPI.supportsDefaultFallbacks(model) { h["anthropic-beta"] = AnthropicAPI.fallbackBeta }
        return h
    }

    static func urlRequest(apiKey: String, body: [String: Any], baseURL: URL = AnthropicAPI.baseURL) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        for (k, v) in headers(apiKey: apiKey, model: body["model"] as? String ?? "") { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }
}

// MARK: - Server-sent events

struct SSEEvent: Equatable {
    var event: String
    var data: String
}

/// Incremental SSE line parser (https://html.spec.whatwg.org/multipage/server-sent-events.html).
struct SSEParser {
    private var eventName = ""
    private var dataLines: [String] = []

    /// Feed one line (without the trailing newline). Returns an event when a blank line completes one.
    mutating func feed(_ rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }   // comment / keep-alive
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break   // id, retry: unused
        }
        return nil
    }

    /// Dispatch whatever is pending (call at end of stream).
    mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer { eventName = ""; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
    }

    /// Parse a complete stream body (testing convenience).
    static func parseAll(_ text: String) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        // components(separatedBy:) works on UTF-16, so "\r\n" (a single Character) still splits at "\n".
        for line in text.components(separatedBy: "\n") {
            if let e = p.feed(line) { out.append(e) }
        }
        if let e = p.finish() { out.append(e) }
        return out
    }
}

// MARK: - Stream events

enum AnthropicStreamEvent: Equatable {
    case messageStart(model: String)
    case textDelta(String)
    case thinkingStarted
    case fallback(toModel: String)
    case stop(reason: String, category: String?)
    case messageStop
    case error(AnthropicAPIError)
    case ignored

    static func decode(_ e: SSEEvent) -> AnthropicStreamEvent {
        guard let data = e.data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .ignored }
        let type = obj["type"] as? String ?? e.event
        switch type {
        case "message_start":
            let msg = obj["message"] as? [String: Any]
            return .messageStart(model: msg?["model"] as? String ?? "")
        case "content_block_start":
            let block = obj["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text":
                let t = block["text"] as? String ?? ""
                return t.isEmpty ? .ignored : .textDelta(t)
            case "thinking", "redacted_thinking": return .thinkingStarted
            case "fallback":
                let to = (block["to"] as? [String: Any])?["model"] as? String ?? ""
                return .fallback(toModel: to)
            default: return .ignored
            }
        case "content_block_delta":
            let delta = obj["delta"] as? [String: Any] ?? [:]
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String { return .textDelta(t) }
            return .ignored
        case "message_delta":
            let delta = obj["delta"] as? [String: Any] ?? [:]
            guard let reason = delta["stop_reason"] as? String else { return .ignored }
            let details = delta["stop_details"] as? [String: Any]
            return .stop(reason: reason, category: details?["category"] as? String)
        case "message_stop":
            return .messageStop
        case "error":
            let err = obj["error"] as? [String: Any] ?? [:]
            return .error(AnthropicAPIError(status: nil, type: err["type"] as? String ?? "api_error",
                                            message: err["message"] as? String ?? "Unknown error", retryAfter: nil))
        default:
            return .ignored   // ping, content_block_stop, unknown future events
        }
    }
}

// MARK: - Errors

struct AnthropicAPIError: LocalizedError, Equatable {
    var status: Int?
    var type: String
    var message: String
    var retryAfter: Double?

    static func from(status: Int, body: Data, retryAfter: String?) -> AnthropicAPIError {
        var type = "api_error", message = HTTPURLResponse.localizedString(forStatusCode: status)
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            type = err["type"] as? String ?? type
            message = err["message"] as? String ?? message
        } else if let s = String(data: body, encoding: .utf8), !s.isEmpty, s.count < 300 {
            message = s
        }
        if status == 529 { type = "overloaded_error" }
        return AnthropicAPIError(status: status, type: type, message: message, retryAfter: retryAfter.flatMap(Double.init))
    }

    var isRetryable: Bool {
        if let s = status, s == 408 || s == 409 || s == 429 || s >= 500 { return true }
        return ["overloaded_error", "rate_limit_error", "api_error"].contains(type)
    }

    var errorDescription: String? {
        switch (status, type) {
        case (401, _), (_, "authentication_error"):
            return "Your Anthropic API key was rejected (401). Check or replace it in Settings → AI."
        case (403, _), (_, "permission_error"):
            return "This API key isn't allowed to use this model or feature (403). \(message)"
        case (404, _), (_, "not_found_error"):
            return "Model not found (404). Check the model ID in Settings → AI. \(message)"
        case (402, _), (_, "billing_error"):
            return "Billing problem with your Anthropic account: \(message)"
        case (429, _), (_, "rate_limit_error"):
            let wait = retryAfter.map { " Try again in \(Int($0.rounded(.up)))s." } ?? " Try again shortly."
            return "Rate limit reached for your Anthropic account (429).\(wait)"
        case (529, _), (_, "overloaded_error"):
            return "Claude is temporarily overloaded. Please try again in a moment."
        case (413, _), (_, "request_too_large"):
            return "The request is too large. Start a new chat or reference fewer tables."
        case (400, _), (_, "invalid_request_error"):
            return "The API rejected the request: \(message)"
        case (.some(let s), _) where s >= 500:
            return "Anthropic API error (\(s)). Please try again. \(message)"
        default:
            return message
        }
    }
}

// MARK: - Client

enum AnthropicClient {
    /// Stream a Messages request. Throws `AnthropicAPIError` for HTTP errors before the stream starts.
    static func stream(apiKey: String, body: [String: Any], baseURL: URL = AnthropicAPI.baseURL,
                       session: URLSession = .shared) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try AnthropicRequest.urlRequest(apiKey: apiKey, body: body, baseURL: baseURL)
                    let (bytes, response) = try await session.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 64_000 { break }
                        }
                        throw AnthropicAPIError.from(status: status, body: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
                    }
                    // Split lines ourselves: AsyncLineSequence drops the blank lines that delimit SSE events.
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    line.reserveCapacity(1024)
                    for try await b in bytes {
                        if b == 0x0A {
                            if let e = parser.feed(String(decoding: line, as: UTF8.self)) {
                                continuation.yield(AnthropicStreamEvent.decode(e))
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if !line.isEmpty, let e = parser.feed(String(decoding: line, as: UTF8.self)) {
                        continuation.yield(AnthropicStreamEvent.decode(e))
                    }
                    if let e = parser.finish() { continuation.yield(AnthropicStreamEvent.decode(e)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Validate a key + model without spending tokens (GET /v1/models/{id}). Returns the model's display name.
    static func testKey(apiKey: String, model: String, session: URLSession = .shared) async throws -> String {
        let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: AnthropicAPI.baseURL.appendingPathComponent("models").appendingPathComponent(id))
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicAPI.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, status == 200 else {
            throw AnthropicAPIError.from(status: http?.statusCode ?? 0, body: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj?["display_name"] as? String ?? model
    }
}
