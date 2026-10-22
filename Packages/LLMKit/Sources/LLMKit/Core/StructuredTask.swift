import Foundation

/// One structured AI feature call: a prompt plus the JSON shape the answer must have.
/// `run` sends it, decodes the result, and retries once with the decode error appended
/// when the model returns something unusable (SPEC §7.2).
public struct StructuredTask<Output: Decodable & Sendable>: Sendable {
    public var name: String
    public var system: String
    public var user: String
    public var schema: JSONSchema
    public var maxTokens: Int
    public var effort: Effort?
    public var timeout: TimeInterval
    /// Stream the response (use for large outputs so long generations don't hit HTTP timeouts).
    public var useStreaming: Bool
    public var maxRetries: Int
    /// Extra semantic validation; throwing triggers the retry like a decode failure.
    public var validate: (@Sendable (Output) throws -> Void)?

    public init(
        name: String,
        system: String,
        user: String,
        schema: JSONSchema,
        maxTokens: Int = 16_000,
        effort: Effort? = .medium,
        timeout: TimeInterval = 120,
        useStreaming: Bool = false,
        maxRetries: Int = 1,
        validate: (@Sendable (Output) throws -> Void)? = nil
    ) {
        self.name = name
        self.system = system
        self.user = user
        self.schema = schema
        self.maxTokens = maxTokens
        self.effort = effort
        self.timeout = timeout
        self.useStreaming = useStreaming
        self.maxRetries = maxRetries
        self.validate = validate
    }

    public static func retrySuffix(_ decodeError: String) -> String {
        "\n\nThe previous response could not be used: \(decodeError). Return only the JSON object, exactly matching the schema."
    }

    func request(user: String) -> ChatRequest {
        ChatRequest(
            system: system,
            messages: [.user(user)],
            maxTokens: maxTokens,
            responseFormat: ResponseFormat(name: name, schema: schema),
            effort: effort,
            timeout: timeout
        )
    }
}

extension LLMClient {
    public func run<T>(_ task: StructuredTask<T>) async throws -> T {
        var user = task.user
        var lastDetail = "unknown"
        for _ in 0...max(0, task.maxRetries) {
            let request = task.request(user: user)
            let response = task.useStreaming ? try await collect(request) : try await complete(request)
            do {
                let value = try LLMResponseParser.decode(response.text, as: T.self)
                try task.validate?(value)
                return value
            } catch {
                if response.stopReason == .maxTokens { throw LLMError.outputTruncated }
                lastDetail = (error as? LLMResponseParseError)?.detail ?? error.localizedDescription
                user = task.user + StructuredTask<T>.retrySuffix(lastDetail)
            }
        }
        throw LLMError.malformedResponse(lastDetail)
    }
}
