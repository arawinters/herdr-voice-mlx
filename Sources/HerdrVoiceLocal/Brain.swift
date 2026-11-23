import Foundation

/// The brain: an OpenAI-compatible chat server (Splash, Ollama, …) that picks tool calls and writes the replies.
public struct BrainConfig: Sendable, Equatable {
    public enum Kind: String, Sendable { case local, keyed, custom }

    public var kind: Kind
    public var baseURL: URL
    public var model: String
    public var reasoningEffort: String?
    public var apiKey: String?
    public var label: String?

    public enum ConfigError: LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let detail) = self { detail } else { nil } }
    }

    /// The brain when the boot record doesn't name one: Splash on its default port. Same defaults as
    /// LocalBackend.native in HerdrVoiceCore.
    public static let defaultURL = "http://127.0.0.1:8000/v1"
    public static let defaultModel = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M"

    /// Validates the brain the app passed in the boot record, with the same rules as the Electron helper.
    /// The native helper speaks only the OpenAI Chat Completions protocol.
    public static func validate(_ value: JSONValue?) throws -> BrainConfig {
        let value = value ?? .object([:])
        func field(_ key: String) -> String? { value[key]?.string }
        guard let kind = Kind(rawValue: field("kind") ?? "local") else { throw ConfigError.invalid("unsupported brain kind") }
        let protocolName = field("protocol") ?? "openai-chat"
        guard protocolName == "openai-chat" else {
            throw ConfigError.invalid("the native local helper supports only the openai-chat brain protocol")
        }
        let rawURL = field("baseURL") ?? defaultURL
        guard let components = URLComponents(string: rawURL), let url = components.url,
              components.scheme == "http" || components.scheme == "https"
        else { throw ConfigError.invalid("brain URL must use HTTP(S)") }
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
            throw ConfigError.invalid("brain URL must not contain credentials or query data")
        }
        let host = (components.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if kind == .local, !["127.0.0.1", "localhost", "::1"].contains(host) {
            throw ConfigError.invalid("local brain must be loopback-only")
        }
        let model = field("model") ?? defaultModel
        if kind == .local, model.firstMatch(#"(?i)(?:^|[-_:])cloud(?:$|[-_:])"#) != nil {
            throw ConfigError.invalid("local brain refuses cloud model names")
        }
        guard model.firstMatch(#"^(?i)[a-z0-9._:/@+-]{1,200}$"#) != nil else { throw ConfigError.invalid("invalid brain model") }
        let label = field("label").flatMap { $0.isEmpty ? nil : $0 }
        if kind != .local, label == nil { throw ConfigError.invalid("remote brain requires an explicit hybrid label") }
        if let label, label.count > 80 || label.contains(where: \.isNewline) { throw ConfigError.invalid("invalid brain label") }
        let apiKey = field("apiKey").flatMap { $0.isEmpty ? nil : $0 }
        if kind == .keyed, apiKey == nil { throw ConfigError.invalid("keyed brain requires a Keychain API key") }
        let effort = field("reasoningEffort")
        if let effort, !effort.isEmpty, effort.firstMatch(#"^(?i)[a-z0-9_-]{1,40}$"#) == nil {
            throw ConfigError.invalid("invalid reasoning effort")
        }
        return BrainConfig(kind: kind, baseURL: url, model: model, reasoningEffort: effort, apiKey: apiKey, label: label)
    }

    /// What the orb shows. A remote brain is always labelled hybrid.
    public var displayLabel: String { kind == .local ? "Local native / \(model)" : "Hybrid: \(label ?? "")" }

    public func endpoint(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression) + path)!
    }

    /// Whether `GET /models` lists this exact model ID.
    public static func listsModel(_ body: JSONValue, model: String) -> Bool {
        body["data"]?.array?.contains { $0["id"]?.string == model } ?? false
    }
}

/// One model call or reply in the conversation. A class, because a reply that's interrupted is edited in place and
/// a placeholder tool result is replaced in place when the real one arrives.
public final class HistoryEntry {
    public enum Role: String { case system, user, assistant, tool }

    public struct ToolCall: Equatable, Sendable {
        public var id: String
        public var name: String
        public var arguments: String
    }

    public let role: Role
    public var text: String?
    public var toolCalls: [ToolCall]
    public let callID: String?
    public let name: String?

    init(role: Role, text: String?, toolCalls: [ToolCall] = [], callID: String? = nil, name: String? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.callID = callID
        self.name = name
    }

    public static func system(_ text: String) -> HistoryEntry { HistoryEntry(role: .system, text: text) }
    public static func user(_ text: String) -> HistoryEntry { HistoryEntry(role: .user, text: text) }
    public static func assistant(_ text: String?, calls: [ToolCall]) -> HistoryEntry {
        HistoryEntry(role: .assistant, text: text, toolCalls: calls)
    }
    public static func tool(callID: String, name: String, result: String) -> HistoryEntry {
        HistoryEntry(role: .tool, text: result, callID: callID, name: name)
    }

    /// The Chat Completions message.
    var chatMessage: [String: Any] {
        switch role {
        case .system, .user: return ["role": role.rawValue, "content": text ?? ""]
        case .assistant:
            var message: [String: Any] = ["role": "assistant", "content": text ?? ""]
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map { call in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
                }
            }
            return message
        case .tool: return ["role": "tool", "tool_call_id": callID ?? "", "content": text ?? ""]
        }
    }
}

/// A snapshot of the history, for the request. Entries are copied so the stream can't see later edits.
public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [JSONValue]
    public var tools: [JSONValue]
    public var reasoningEffort: String?
    public var maxTokens: Int?

    public init(model: String, history: [HistoryEntry], tools: [JSONValue], reasoningEffort: String?, maxTokens: Int?) {
        self.model = model
        self.messages = history.map { (try? JSONValue($0.chatMessage)) ?? .null }
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens
    }

    public func body() throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.any),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function", "function": [
                    "name": tool["name"]?.any ?? "", "description": tool["description"]?.any ?? "",
                    "parameters": tool["parameters"]?.any ?? [String: Any](),
                ] as [String: Any]]
            }
        }
        if let reasoningEffort, !reasoningEffort.isEmpty { body["reasoning_effort"] = reasoningEffort }
        if let maxTokens { body["max_tokens"] = maxTokens }
        // Sorted keys: Swift dictionaries have no stable order, and the brain's prompt-prefix cache only hits when the
        // instructions and tool schemas are byte-identical from one request to the next.
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Normalized streaming events from the brain.
public enum ProviderEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case toolStart(index: Int, id: String, name: String)
    case toolDelta(index: Int, arguments: String)
    case toolStop(index: Int)
    case usage(input: Int, output: Int)
    case done(stopReason: String)
}

/// Parses Chat Completions server-sent events one line at a time.
public struct ChatStreamParser {
    private var started: [Int] = []
    private var stopReason = "stop"
    public private(set) var finished = false

    public init() {}

    public mutating func parse(line: String) -> [ProviderEvent] {
        guard !finished, line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return [] } // keepalive, not the end
        if payload == "[DONE]" {
            finished = true
            return []
        }
        guard let event = try? JSONValue.parse(Data(payload.utf8)) else { return [] }
        var out: [ProviderEvent] = []
        if let usage = event["usage"], usage.object != nil {
            out.append(.usage(input: usage["prompt_tokens"]?.safeInteger ?? 0, output: usage["completion_tokens"]?.safeInteger ?? 0))
        }
        guard let choice = event["choices"]?.array?.first else { return out }
        let delta = choice["delta"]
        if let content = delta?["content"]?.string, !content.isEmpty { out.append(.text(content)) }
        if let reasoning = (delta?["reasoning_content"] ?? delta?["reasoning"])?.string, !reasoning.isEmpty {
            out.append(.reasoning(reasoning))
        }
        for call in delta?["tool_calls"]?.array ?? [] {
            let index = call["index"]?.safeInteger ?? 0
            if !started.contains(index) {
                started.append(index)
                out.append(.toolStart(index: index, id: call["id"]?.string ?? "call_\(index)",
                                      name: call["function"]?["name"]?.string ?? ""))
            }
            if let arguments = call["function"]?["arguments"]?.string, !arguments.isEmpty {
                out.append(.toolDelta(index: index, arguments: arguments))
            }
        }
        if let reason = choice["finish_reason"]?.string { stopReason = reason }
        return out
    }

    /// The closing events once the stream ends.
    public func finish() -> [ProviderEvent] { started.map { .toolStop(index: $0) } + [.done(stopReason: stopReason)] }
}

public enum BrainError: LocalizedError {
    case http(Int, String)
    case lineTooLong

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .lineTooLong: "SSE line exceeded the size limit"
        }
    }
}

/// Streams a chat completion from the brain.
public struct BrainClient: Sendable {
    public let config: BrainConfig
    private let session: URLSession

    public init(config: BrainConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: config.endpoint(path))
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let key = config.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        return request
    }

    public func stream(_ chat: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = request("/chat/completions", body: try chat.body())
                    let (bytes, response) = try await Self.withRetry { try await session.bytes(for: request) }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var text = ""
                        for try await line in bytes.lines where text.count < 400 { text += line }
                        throw BrainError.http(http.statusCode, String(text.prefix(400)))
                    }
                    var parser = ChatStreamParser()
                    for try await line in bytes.lines {
                        if line.utf8.count > 8_000_000 { throw BrainError.lineTooLong }
                        for event in parser.parse(line: line) { continuation.yield(event) }
                        if parser.finished { break }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let retryStatus: Set<Int> = [408, 409, 429, 500, 502, 503, 529]

    /// Retries the request before any of the stream is read: up to 4 attempts with jittered backoff, honoring
    /// Retry-After. A retry after bytes were yielded would replay text and tool deltas, so it never happens.
    static func withRetry(_ send: () async throws -> (URLSession.AsyncBytes, URLResponse)) async throws
        -> (URLSession.AsyncBytes, URLResponse)
    {
        var lastError: Error?
        for attempt in 0...3 {
            try Task.checkCancellation()
            var result: (URLSession.AsyncBytes, URLResponse)?
            do { result = try await send() } catch {
                if Task.isCancelled { throw error }
                lastError = error
            }
            let status = (result?.1 as? HTTPURLResponse)?.statusCode
            if let result, let status, (200..<300).contains(status) || !retryStatus.contains(status) { return result }
            if attempt == 3 {
                if let result { return result }
                throw lastError ?? URLError(.unknown)
            }
            var delay = min(8.0, 0.5 * pow(2, Double(attempt)))
            if let header = (result?.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after"),
               let seconds = Double(header), seconds >= 0 { delay = min(8, seconds) }
            delay = delay / 2 + Double.random(in: 0...(delay / 2))
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        }
        throw lastError ?? URLError(.unknown)
    }

    /// Startup check for a local brain: the server lists the exact model and answers one tiny completion.
    public func preflight() async throws -> [String: Any] {
        guard config.kind == .local else { return ["mode": "hybrid", "checked": false] }
        let (models, modelsResponse) = try await session.data(for: request("/models", body: nil))
        guard (modelsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrainError.http((modelsResponse as? HTTPURLResponse)?.statusCode ?? 0, "local brain model inventory failed")
        }
        guard Self.listsModel(models, model: config.model) else {
            throw BrainConfig.ConfigError.invalid("local brain model \(config.model) is not served at \(config.baseURL.absoluteString)")
        }
        let probe = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "messages": [["role": "user", "content": "Reply OK."]], "max_tokens": 2,
            "stream": false, "reasoning_effort": config.reasoningEffort ?? "none",
        ] as [String: Any])
        var probeRequest = request("/chat/completions", body: probe)
        probeRequest.timeoutInterval = 60
        let (body, response) = try await session.data(for: probeRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrainError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "local brain inference probe failed")
        }
        guard let choices = (try? JSONValue.parse(body))?["choices"]?.array, !choices.isEmpty else {
            throw BrainConfig.ConfigError.invalid("local brain inference probe returned no choice")
        }
        return ["mode": "local", "model": config.model, "installed": true, "inference": "ok"]
    }

    static func listsModel(_ data: Data, model: String) -> Bool {
        guard let body = try? JSONValue.parse(data) else { return false }
        return BrainConfig.listsModel(body, model: model)
    }
}
