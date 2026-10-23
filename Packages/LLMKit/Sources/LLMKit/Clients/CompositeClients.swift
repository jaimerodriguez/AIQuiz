import Foundation

/// Reports token usage of every successful call to `onUsage` (SPEC §7.5).
public struct MeteredClient: LLMClient {
    let base: LLMClient
    let onUsage: @Sendable (LLMEndpoint, TokenUsage) -> Void

    public init(_ base: LLMClient, onUsage: @escaping @Sendable (LLMEndpoint, TokenUsage) -> Void) {
        self.base = base
        self.onUsage = onUsage
    }

    public var endpoint: LLMEndpoint { base.endpoint }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let response = try await base.complete(request)
        onUsage(base.endpoint, response.usage)
        return response
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let upstream = base.stream(request)
        let endpoint = base.endpoint
        let onUsage = self.onUsage
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .done(let response) = event {
                            onUsage(endpoint, response.usage)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        try await base.listModels()
    }
}

/// Tries `primary`; on a failure where another endpoint could help (`LLMError.shouldTryFallback`)
/// repeats the request on `fallback` (SPEC §8.2). Streams switch only if no text was delivered yet.
public struct FallbackClient: LLMClient {
    let primary: LLMClient
    let fallback: LLMClient

    public init(primary: LLMClient, fallback: LLMClient) {
        self.primary = primary
        self.fallback = fallback
    }

    public var endpoint: LLMEndpoint { primary.endpoint }

    static func shouldFallBack(_ error: Error) -> Bool {
        (LLMErrorMapping.map(error) as? LLMError)?.shouldTryFallback ?? false
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        do {
            return try await primary.complete(request)
        } catch where Self.shouldFallBack(error) {
            return try await fallback.complete(request)
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let primary = self.primary
        let fallback = self.fallback
        return AsyncThrowingStream { continuation in
            let task = Task {
                var delivered = false
                do {
                    for try await event in primary.stream(request) {
                        if case .textDelta = event { delivered = true }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    guard !delivered, Self.shouldFallBack(error) else {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        for try await event in fallback.stream(request) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        try await primary.listModels()
    }
}
