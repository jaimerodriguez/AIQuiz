import Foundation
import Synchronization

/// Deterministic client for tests, SwiftUI previews and UI-test mode (DECISIONS ADR-005).
/// Responses come from a handler; every request is recorded for assertions.
public struct FakeLLMClient: LLMClient {
    public typealias Handler = @Sendable (ChatRequest) async throws -> String

    public let endpoint: LLMEndpoint
    public let recorder: RequestRecorder
    let handler: Handler
    let latency: Duration
    let models: [String]
    let streamChunkSize: Int

    public init(
        endpoint: LLMEndpoint = .fake(),
        latency: Duration = .zero,
        models: [String] = ["fake-model-a", "fake-model-b"],
        streamChunkSize: Int = 12,
        recorder: RequestRecorder = RequestRecorder(),
        handler: @escaping Handler
    ) {
        self.endpoint = endpoint
        self.latency = latency
        self.models = models
        self.streamChunkSize = max(1, streamChunkSize)
        self.recorder = recorder
        self.handler = handler
    }

    /// Returns each response in turn; the last one repeats. A `Result.failure` is thrown.
    public static func scripted(
        _ responses: [Result<String, LLMError>],
        endpoint: LLMEndpoint = .fake(),
        recorder: RequestRecorder = RequestRecorder()
    ) -> FakeLLMClient {
        let queue = ScriptQueue(responses)
        return FakeLLMClient(endpoint: endpoint, recorder: recorder) { _ in try queue.next().get() }
    }

    public static func scripted(_ responses: [String], endpoint: LLMEndpoint = .fake()) -> FakeLLMClient {
        scripted(responses.map { .success($0) }, endpoint: endpoint)
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        recorder.append(request)
        if latency > .zero {
            do { try await Task.sleep(for: latency) } catch { throw LLMError.cancelled }
        }
        if Task.isCancelled { throw LLMError.cancelled }
        let text = try await handler(request)
        let usage = TokenUsage(input: request.estimatedInputTokens, output: (text.utf8.count + 3) / 4)
        return ChatResponse(text: text, usage: usage, stopReason: .endTurn, model: endpoint.model)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let chunkSize = streamChunkSize
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    var remaining = Substring(response.text)
                    while !remaining.isEmpty {
                        if Task.isCancelled { throw LLMError.cancelled }
                        let piece = remaining.prefix(chunkSize)
                        remaining = remaining.dropFirst(piece.count)
                        continuation.yield(.textDelta(String(piece)))
                        await Task.yield()
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMErrorMapping.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        models
    }
}

/// Thread-safe log of requests a fake received.
public final class RequestRecorder: Sendable {
    private let storage = Mutex<[ChatRequest]>([])

    public init() {}

    public func append(_ request: ChatRequest) {
        storage.withLock { $0.append(request) }
    }

    public var requests: [ChatRequest] {
        storage.withLock { $0 }
    }

    public var count: Int {
        storage.withLock { $0.count }
    }
}

final class ScriptQueue: Sendable {
    private let storage: Mutex<[Result<String, LLMError>]>

    init(_ responses: [Result<String, LLMError>]) {
        storage = Mutex(responses.isEmpty ? [.failure(.malformedResponse("empty script"))] : responses)
    }

    func next() -> Result<String, LLMError> {
        storage.withLock { queue in
            queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }
}
