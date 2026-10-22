import Foundation

/// A chat-completion endpoint. Implementations: `AnthropicClient`, `OpenAICompatibleClient`,
/// `FakeLLMClient`, and the app's Apple on-device client. Knows nothing about quizzes.
public protocol LLMClient: Sendable {
    var endpoint: LLMEndpoint { get }
    func complete(_ request: ChatRequest) async throws -> ChatResponse
    /// Streams text deltas, then exactly one `.done` with the full response.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
}

extension LLMClient {
    /// Default streaming: one delta containing the whole completion.
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(.textDelta(response.text))
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMErrorMapping.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Consume `stream` and return the final response.
    public func collect(_ request: ChatRequest) async throws -> ChatResponse {
        var text = ""
        for try await event in stream(request) {
            switch event {
            case .textDelta(let d): text += d
            case .done(let response): return response
            }
        }
        // A stream that ends without `.done` is treated as a complete end-of-turn.
        return ChatResponse(text: text)
    }
}

/// Converts arbitrary thrown errors into `LLMError`.
public enum LLMErrorMapping {
    public static func map(_ error: Error) -> Error {
        if let e = error as? LLMError { return e }
        if error is CancellationError { return LLMError.cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return LLMError.cancelled
            case .timedOut: return LLMError.timedOut
            default: return LLMError.network(u.localizedDescription)
            }
        }
        return error
    }
}
