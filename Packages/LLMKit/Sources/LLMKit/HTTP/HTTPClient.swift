import Foundation

/// Sends requests with retry, backoff and typed error mapping (SPEC §8.5).
public struct HTTPClient: Sendable {
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias ErrorMapper = @Sendable (_ status: Int, _ body: Data, _ response: HTTPURLResponse) -> LLMError

    public let transport: HTTPTransport
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    let sleeper: Sleeper
    let errorMapper: ErrorMapper

    public static let defaultSleeper: Sleeper = { seconds in
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1,
        sleeper: @escaping Sleeper = HTTPClient.defaultSleeper,
        errorMapper: @escaping ErrorMapper = HTTPErrorMapper.standard
    ) {
        self.transport = transport
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.sleeper = sleeper
        self.errorMapper = errorMapper
    }

    /// Non-streaming request. Returns the body of a 2xx response.
    public func send(_ request: URLRequest) async throws -> Data {
        try await withRetry {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw errorMapper(response.statusCode, data, response)
            }
            return data
        }
    }

    /// Streaming request. Retries only while opening; once bytes flow, errors propagate.
    public func openStream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        try await withRetry {
            let (response, chunks) = try await transport.stream(request)
            guard (200..<300).contains(response.statusCode) else {
                var body = Data()
                for try await chunk in chunks {
                    body.append(chunk)
                    if body.count > 65_536 { break }
                }
                throw errorMapper(response.statusCode, body, response)
            }
            return chunks
        }
    }

    func withRetry<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            if Task.isCancelled { throw LLMError.cancelled }
            do {
                return try await operation()
            } catch {
                let mapped = LLMErrorMapping.map(error)
                guard let llmError = mapped as? LLMError, llmError.isRetryable, attempt < maxRetries else {
                    throw mapped
                }
                do {
                    try await sleeper(delay(for: llmError, attempt: attempt))
                } catch {
                    throw LLMError.cancelled
                }
                attempt += 1
            }
        }
    }

    func delay(for error: LLMError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let after?) = error {
            return min(max(after, 0), 30)
        }
        return baseDelay * pow(2, Double(attempt))
    }
}

/// Maps HTTP status and body to `LLMError`. Works for Anthropic and OpenAI-style error bodies
/// (`{"error": {"message": ...}}`).
public enum HTTPErrorMapper {
    public static let standard: HTTPClient.ErrorMapper = { status, body, response in
        let message = errorMessage(from: body)
        let lower = message.lowercased()
        switch status {
        case 401, 403:
            return .unauthorized
        case 404:
            return .notFound
        case 408:
            return .timedOut
        case 413:
            return .contextTooLong
        case 429:
            return .rateLimited(retryAfter: retryAfter(response))
        case 400 where isContextError(lower):
            return .contextTooLong
        case 500...599:
            return .server(status: status)
        default:
            return .badRequest(status: status, detail: message)
        }
    }

    public static func errorMessage(from body: Data) -> String {
        if let json = try? JSONValue.parse(body) {
            if let m = json["error"]?["message"]?.stringValue { return m }
            if let m = json["error"]?.stringValue { return m }
            if let m = json["message"]?.stringValue { return m }
        }
        return String(decoding: body.prefix(500), as: UTF8.self)
    }

    static func isContextError(_ lower: String) -> Bool {
        lower.contains("context length") || lower.contains("context window") || lower.contains("too long")
            || lower.contains("maximum context") || lower.contains("prompt is too long")
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "retry-after") else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }
}
