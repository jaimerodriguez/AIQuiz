import Foundation

/// Anthropic Messages API client (SPEC §8.4). Verified against the API docs on 2026-10-22:
/// API version `2026-10-21`; no `temperature`/`top_p`/`top_k` and no assistant prefill (both 400
/// on current models); JSON via `output_config.format`; depth via `output_config.effort`;
/// refusal fallbacks via `fallbacks: "default"` on models that support it.
public struct AnthropicClient: LLMClient {
    public static let apiVersion = "2026-10-21"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models that accept `fallbacks: "default"` on the Claude API.
    public static let fallbackModels: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    public let endpoint: LLMEndpoint
    let apiKey: String
    let http: HTTPClient

    public init(endpoint: LLMEndpoint, apiKey: String, http: HTTPClient = HTTPClient()) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
    }

    var baseURL: URL { endpoint.baseURL ?? Self.defaultBaseURL }

    /// The Messages endpoint. Accepts a base URL with or without a trailing `/v1`.
    var messagesURL: URL {
        baseURL.path.hasSuffix("/v1")
            ? URLBuilding.url(baseURL, appending: "messages")
            : URLBuilding.url(baseURL, appending: "v1/messages")
    }

    var modelsURL: URL {
        let u = baseURL.path.hasSuffix("/v1")
            ? URLBuilding.url(baseURL, appending: "models")
            : URLBuilding.url(baseURL, appending: "v1/models")
        return URL(string: u.absoluteString + "?limit=100") ?? u
    }

    var usesServerFallback: Bool {
        baseURL.host == "api.anthropic.com" && Self.fallbackModels.contains(endpoint.model)
    }

    /// Effort is rejected by Sonnet 4.5, Haiku 4.5 and Claude 3 models.
    var supportsEffort: Bool {
        let m = endpoint.model
        return !(m.hasPrefix("claude-3") || m.contains("haiku-4") || m.contains("sonnet-4-5"))
    }

    // MARK: Request building

    func headers() -> [String: String] {
        var h = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion
        ]
        if usesServerFallback {
            h["anthropic-beta"] = Self.fallbackBeta
        }
        return h
    }

    func body(_ request: ChatRequest, stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(endpoint.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "messages": .array(request.messages.map(Self.message))
        ]
        if !request.system.isEmpty {
            body["system"] = .string(request.system)
        }
        if stream {
            body["stream"] = true
        }
        var outputConfig: [String: JSONValue] = [:]
        if let effort = request.effort, supportsEffort {
            outputConfig["effort"] = .string(effort.rawValue)
        }
        if let format = request.responseFormat {
            outputConfig["format"] = ["type": "json_schema", "schema": format.schema.jsonValue]
        }
        if !outputConfig.isEmpty {
            body["output_config"] = .object(outputConfig)
        }
        if usesServerFallback {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    static func message(_ m: ChatMessage) -> JSONValue {
        let blocks: [JSONValue] = m.parts.map { part in
            switch part {
            case .text(let t):
                return ["type": "text", "text": .string(t)]
            case .image(let data, let mime):
                return [
                    "type": "image",
                    "source": ["type": "base64", "media_type": .string(mime), "data": .string(data.base64EncodedString())]
                ]
            }
        }
        return ["role": .string(m.role.rawValue), "content": .array(blocks)]
    }

    func urlRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        try URLBuilding.jsonRequest(
            url: messagesURL,
            body: body(request, stream: stream),
            headers: headers(),
            timeout: request.timeout
        )
    }

    // MARK: LLMClient

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let data = try await http.send(try urlRequest(request, stream: false))
        return try Self.parseResponse(data)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await http.openStream(try urlRequest(request, stream: true))
                    var decoder = SSEDecoder()
                    var state = StreamState()
                    for try await chunk in chunks {
                        for payload in decoder.feed(chunk) {
                            try Self.handle(payload, state: &state, continuation: continuation)
                        }
                    }
                    for payload in decoder.finish() {
                        try Self.handle(payload, state: &state, continuation: continuation)
                    }
                    if state.stopReason == .refusal {
                        throw LLMError.refused(category: state.refusalCategory)
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
        let request = try URLBuilding.jsonRequest(url: modelsURL, method: "GET", body: nil, headers: headers(), timeout: 30)
        let data = try await http.send(request)
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    // MARK: Response parsing

    static func stopReason(_ raw: String?) -> StopReason {
        switch raw {
        case "end_turn", nil: return .endTurn
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        case let other?: return .other(other)
        }
    }

    static func usage(_ json: JSONValue?) -> TokenUsage {
        TokenUsage(
            input: json?["input_tokens"]?.intValue ?? 0,
            output: json?["output_tokens"]?.intValue ?? 0,
            cacheRead: json?["cache_read_input_tokens"]?.intValue ?? 0
        )
    }

    /// Joins the `text` blocks only; thinking and fallback blocks are skipped.
    static func parseResponse(_ data: Data) throws -> ChatResponse {
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            throw LLMError.malformedResponse("response body is not JSON")
        }
        let stop = stopReason(json["stop_reason"]?.stringValue)
        if stop == .refusal {
            throw LLMError.refused(category: json["stop_details"]?["category"]?.stringValue)
        }
        guard let blocks = json["content"]?.arrayValue else {
            throw LLMError.malformedResponse("missing content")
        }
        let text = blocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        return ChatResponse(text: text, usage: usage(json["usage"]), stopReason: stop, model: json["model"]?.stringValue)
    }

    struct StreamState {
        var text = ""
        var usage = TokenUsage.zero
        var stopReason: StopReason?
        var refusalCategory: String?
        var model: String?
    }

    static func handle(
        _ payload: String,
        state: inout StreamState,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) throws {
        for single in SSEDecoder.splitIfConcatenated(payload) {
            guard let event = try? JSONValue.parse(single) else { continue }
            switch event["type"]?.stringValue {
            case "message_start":
                let message = event["message"]
                state.model = message?["model"]?.stringValue
                let u = usage(message?["usage"])
                state.usage.input = u.input
                state.usage.cacheRead = u.cacheRead
                state.usage.output = u.output
            case "content_block_delta":
                if event["delta"]?["type"]?.stringValue == "text_delta", let t = event["delta"]?["text"]?.stringValue {
                    state.text += t
                    continuation.yield(.textDelta(t))
                }
            case "message_delta":
                if let raw = event["delta"]?["stop_reason"]?.stringValue {
                    state.stopReason = stopReason(raw)
                }
                if let category = event["delta"]?["stop_details"]?["category"]?.stringValue {
                    state.refusalCategory = category
                }
                if let out = event["usage"]?["output_tokens"]?.intValue {
                    state.usage.output = out
                }
            case "error":
                throw mapStreamError(event["error"])
            default:
                break
            }
        }
    }

    static func mapStreamError(_ error: JSONValue?) -> LLMError {
        let type = error?["type"]?.stringValue ?? ""
        let message = error?["message"]?.stringValue ?? type
        switch type {
        case "overloaded_error": return .server(status: 529)
        case "api_error": return .server(status: 500)
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "authentication_error", "permission_error": return .unauthorized
        default: return .badRequest(status: 400, detail: message)
        }
    }
}
