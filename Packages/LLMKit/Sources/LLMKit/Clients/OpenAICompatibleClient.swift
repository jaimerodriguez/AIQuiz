import Foundation

/// Client for OpenAI and every server that speaks its Chat Completions format: Ollama,
/// LM Studio, llama.cpp, vLLM, OpenRouter (SPEC §8.4).
///
/// Structured output degrades gracefully: `json_schema` (strict) → `json_object` with the schema
/// in the system prompt → prompt only. When a server rejects `json_schema`, `onJSONSchemaSupport`
/// reports `false` so the caller can persist it on the endpoint and skip the failing step next time.
public struct OpenAICompatibleClient: LLMClient {
    public enum JSONMode: Sendable, Hashable {
        case jsonSchema
        case jsonObject
        case promptOnly

        var next: JSONMode? {
            switch self {
            case .jsonSchema: return .jsonObject
            case .jsonObject: return .promptOnly
            case .promptOnly: return nil
            }
        }
    }

    public let endpoint: LLMEndpoint
    let apiKey: String?
    let http: HTTPClient
    let onJSONSchemaSupport: @Sendable (Bool) -> Void

    public init(
        endpoint: LLMEndpoint,
        apiKey: String?,
        http: HTTPClient = HTTPClient(),
        onJSONSchemaSupport: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.http = http
        self.onJSONSchemaSupport = onJSONSchemaSupport
    }

    var baseURL: URL { endpoint.baseURL ?? URL(string: "https://api.openai.com/v1")! }
    var host: String { baseURL.host ?? "" }
    var isOpenAI: Bool { host == "api.openai.com" }
    var reportsStreamUsage: Bool { isOpenAI || host.hasSuffix("openrouter.ai") }

    // MARK: Request building

    func headers() -> [String: String] {
        var h: [String: String] = [:]
        if let apiKey { h["Authorization"] = "Bearer \(apiKey)" }
        return h
    }

    func initialMode(for request: ChatRequest) -> JSONMode {
        guard request.responseFormat != nil else { return .promptOnly }
        return endpoint.supportsJSONSchema ? .jsonSchema : .jsonObject
    }

    func body(_ request: ChatRequest, mode: JSONMode, stream: Bool) -> JSONValue {
        var system = request.system
        if let format = request.responseFormat, mode != .jsonSchema {
            system += "\n\nRespond with only a JSON object (no prose, no code fences) that matches this JSON Schema:\n" + format.schema.promptText
        }
        var messages: [JSONValue] = []
        if !system.isEmpty {
            messages.append(["role": "system", "content": .string(system)])
        }
        messages += request.messages.map(Self.message)

        var body: [String: JSONValue] = [
            "model": .string(endpoint.model),
            "messages": .array(messages)
        ]
        // OpenAI's current models reject `max_tokens`; most local servers only know `max_tokens`.
        body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = .number(Double(request.maxTokens))
        if stream {
            body["stream"] = true
            if reportsStreamUsage {
                body["stream_options"] = ["include_usage": true]
            }
        }
        if let format = request.responseFormat {
            switch mode {
            case .jsonSchema:
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": .string(format.name), "strict": true, "schema": format.schema.jsonValue]
                ]
            case .jsonObject:
                body["response_format"] = ["type": "json_object"]
            case .promptOnly:
                break
            }
        }
        return .object(body)
    }

    static func message(_ m: ChatMessage) -> JSONValue {
        if m.parts.count == 1, case .text(let t) = m.parts[0] {
            return ["role": .string(m.role.rawValue), "content": .string(t)]
        }
        let parts: [JSONValue] = m.parts.map { part in
            switch part {
            case .text(let t):
                return ["type": "text", "text": .string(t)]
            case .image(let data, let mime):
                return ["type": "image_url", "image_url": ["url": .string("data:\(mime);base64,\(data.base64EncodedString())")]]
            }
        }
        return ["role": .string(m.role.rawValue), "content": .array(parts)]
    }

    func urlRequest(_ request: ChatRequest, mode: JSONMode, stream: Bool) throws -> URLRequest {
        try URLBuilding.jsonRequest(
            url: URLBuilding.url(baseURL, appending: "chat/completions"),
            body: body(request, mode: mode, stream: stream),
            headers: headers(),
            timeout: request.timeout
        )
    }

    /// True when a 400 is the server rejecting our `response_format`.
    static func isResponseFormatRejection(_ error: Error) -> Bool {
        guard case LLMError.badRequest(400, let detail) = error else { return false }
        let lower = detail.lowercased()
        return lower.contains("response_format") || lower.contains("json_schema")
            || lower.contains("json_object") || lower.contains("structured output")
    }

    /// Runs `operation` stepping down the JSON-mode ladder on response_format rejections.
    func withModeLadder<T: Sendable>(_ request: ChatRequest, _ operation: (JSONMode) async throws -> T) async throws -> T {
        let start = initialMode(for: request)
        var mode = start
        while true {
            do {
                let result = try await operation(mode)
                if start == .jsonSchema && mode != .jsonSchema {
                    onJSONSchemaSupport(false)
                }
                return result
            } catch {
                guard Self.isResponseFormatRejection(error), let next = mode.next else { throw error }
                mode = next
            }
        }
    }

    // MARK: LLMClient

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        try await withModeLadder(request) { mode in
            let data = try await http.send(try urlRequest(request, mode: mode, stream: false))
            return try Self.parseResponse(data)
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await withModeLadder(request) { mode in
                        try await http.openStream(try urlRequest(request, mode: mode, stream: true))
                    }
                    var decoder = SSEDecoder()
                    var state = StreamState()
                    streamLoop: for try await chunk in chunks {
                        for payload in decoder.feed(chunk) {
                            if try Self.handle(payload, state: &state, continuation: continuation) { break streamLoop }
                        }
                    }
                    for payload in decoder.finish() {
                        _ = try Self.handle(payload, state: &state, continuation: continuation)
                    }
                    if state.stopReason == .refusal {
                        throw LLMError.refused(category: nil)
                    }
                    continuation.yield(.done(ChatResponse(
                        text: state.text, usage: state.usage, stopReason: state.stopReason ?? .endTurn, model: state.model
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMErrorMapping.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        let request = try URLBuilding.jsonRequest(
            url: URLBuilding.url(baseURL, appending: "models"), method: "GET", body: nil, headers: headers(), timeout: 30
        )
        let data = try await http.send(request)
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
    }

    // MARK: Response parsing

    static func stopReason(_ raw: String?) -> StopReason {
        switch raw {
        case "stop", nil: return .endTurn
        case "length": return .maxTokens
        case "content_filter": return .refusal
        case let other?: return .other(other)
        }
    }

    static func usage(_ json: JSONValue?) -> TokenUsage {
        TokenUsage(
            input: json?["prompt_tokens"]?.intValue ?? 0,
            output: json?["completion_tokens"]?.intValue ?? 0,
            cacheRead: json?["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        )
    }

    static func parseResponse(_ data: Data) throws -> ChatResponse {
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            throw LLMError.malformedResponse("response body is not JSON")
        }
        guard let choice = json["choices"]?[0] else {
            throw LLMError.malformedResponse("missing choices[0]")
        }
        let message = choice["message"]
        if let refusal = message?["refusal"]?.stringValue, !refusal.isEmpty {
            throw LLMError.refused(category: nil)
        }
        let stop = stopReason(choice["finish_reason"]?.stringValue)
        if stop == .refusal {
            throw LLMError.refused(category: "content_filter")
        }
        let text = message?["content"]?.stringValue ?? ""
        return ChatResponse(text: text, usage: usage(json["usage"]), stopReason: stop, model: json["model"]?.stringValue)
    }

    struct StreamState {
        var text = ""
        var usage = TokenUsage.zero
        var stopReason: StopReason?
        var model: String?
    }

    /// Returns true when the stream signalled `[DONE]`.
    static func handle(
        _ payload: String,
        state: inout StreamState,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) throws -> Bool {
        for single in SSEDecoder.splitIfConcatenated(payload) {
            if single.trimmingCharacters(in: .whitespaces) == "[DONE]" { return true }
            guard let chunk = try? JSONValue.parse(single) else { continue }
            if let error = chunk["error"] {
                throw LLMError.badRequest(status: 400, detail: error["message"]?.stringValue ?? "stream error")
            }
            if state.model == nil { state.model = chunk["model"]?.stringValue }
            if let choice = chunk["choices"]?[0] {
                if let t = choice["delta"]?["content"]?.stringValue, !t.isEmpty {
                    state.text += t
                    continuation.yield(.textDelta(t))
                }
                if let reason = choice["finish_reason"]?.stringValue {
                    state.stopReason = stopReason(reason)
                }
            }
            if let u = chunk["usage"], !u.isNull {
                state.usage = usage(u)
            }
        }
        return false
    }
}
