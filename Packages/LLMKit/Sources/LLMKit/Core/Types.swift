import Foundation

/// Which wire protocol an endpoint speaks.
public enum EndpointKind: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openAICompatible
    case appleOnDevice
    /// Deterministic fixture-backed client used in tests and UI-test mode. Never offered as a preset.
    case fake
}

/// A configured model endpoint (SPEC §8.1). The API key is not stored here; it lives in the
/// Keychain under `keychainAccount`.
public struct LLMEndpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: EndpointKind
    public var name: String
    public var baseURL: URL?
    public var model: String
    public var keychainAccount: String?
    public var contextWindowTokens: Int
    public var supportsJSONSchema: Bool
    public var supportsVision: Bool
    public var priceInPerMTok: Double?
    public var priceOutPerMTok: Double?

    public init(
        id: UUID = UUID(),
        kind: EndpointKind,
        name: String,
        baseURL: URL? = nil,
        model: String,
        keychainAccount: String? = nil,
        contextWindowTokens: Int,
        supportsJSONSchema: Bool = true,
        supportsVision: Bool = false,
        priceInPerMTok: Double? = nil,
        priceOutPerMTok: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.keychainAccount = keychainAccount
        self.contextWindowTokens = contextWindowTokens
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsVision = supportsVision
        self.priceInPerMTok = priceInPerMTok
        self.priceOutPerMTok = priceOutPerMTok
    }

    /// Whether requests need an API key. OpenAI-compatible local servers usually do not.
    public var requiresAPIKey: Bool {
        kind == .anthropic
    }

    public static func fake(name: String = "Fake", contextWindowTokens: Int = 200_000) -> LLMEndpoint {
        LLMEndpoint(kind: .fake, name: name, model: "fake-model-a", contextWindowTokens: contextWindowTokens)
    }
}

/// How much reasoning the model should spend. Mapped to `output_config.effort` on Anthropic;
/// ignored by endpoints that have no equivalent.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum ContentPart: Sendable, Hashable {
    case text(String)
    case image(Data, mimeType: String)
}

public struct ChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }

    public var role: Role
    public var parts: [ContentPart]

    public init(role: Role, parts: [ContentPart]) {
        self.role = role
        self.parts = parts
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, parts: [.text(text)])
    }

    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, parts: [.text(text)])
    }

    /// Concatenated text parts.
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
}

/// Request that the response be a JSON object matching `schema`.
public struct ResponseFormat: Sendable, Hashable {
    /// Short identifier, sent as the OpenAI `json_schema.name` and used by fakes to pick fixtures.
    public var name: String
    public var schema: JSONSchema

    public init(name: String, schema: JSONSchema) {
        self.name = name
        self.schema = schema
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var system: String
    public var messages: [ChatMessage]
    public var maxTokens: Int
    public var responseFormat: ResponseFormat?
    public var effort: Effort?
    /// Seconds without data before the request times out.
    public var timeout: TimeInterval

    public init(
        system: String,
        messages: [ChatMessage],
        maxTokens: Int = 16_000,
        responseFormat: ResponseFormat? = nil,
        effort: Effort? = nil,
        timeout: TimeInterval = 120
    ) {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.effort = effort
        self.timeout = timeout
    }

    /// Rough token estimate for context-budget checks (SPEC §7.4): UTF-8 bytes / 4.
    public var estimatedInputTokens: Int {
        let chars = system.utf8.count + messages.reduce(0) { $0 + $1.text.utf8.count }
        return (chars + 3) / 4
    }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }

    public static let zero = TokenUsage()

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    /// Estimated cost in dollars given per-million-token prices.
    public func cost(inPerMTok: Double, outPerMTok: Double) -> Double {
        (Double(input) * inPerMTok + Double(output) * outPerMTok) / 1_000_000
    }
}

public enum StopReason: Sendable, Hashable {
    case endTurn
    case maxTokens
    case refusal
    case other(String)
}

public struct ChatResponse: Sendable, Hashable {
    public var text: String
    public var usage: TokenUsage
    public var stopReason: StopReason
    public var model: String?

    public init(text: String, usage: TokenUsage = .zero, stopReason: StopReason = .endTurn, model: String? = nil) {
        self.text = text
        self.usage = usage
        self.stopReason = stopReason
        self.model = model
    }
}

public enum ChatEvent: Sendable, Hashable {
    case textDelta(String)
    case done(ChatResponse)
}
