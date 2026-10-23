import Foundation
import Synchronization
@testable import LLMKit

/// Test transport: replays scripted replies in order and records every request.
final class ScriptedTransport: HTTPTransport, Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// For streaming replies: body split into these chunks.
        var chunks: [Data]?
        var error: LLMError?

        static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: Data(text.utf8))
        }

        static func sse(_ text: String, chunkSize: Int = 7) -> Reply {
            let bytes = Array(text.utf8)
            var chunks: [Data] = []
            var i = 0
            while i < bytes.count {
                chunks.append(Data(bytes[i..<min(i + chunkSize, bytes.count)]))
                i += chunkSize
            }
            return Reply(status: 200, chunks: chunks)
        }

        static func failure(_ error: LLMError) -> Reply {
            Reply(status: 0, error: error)
        }
    }

    private let replies: Mutex<[Reply]>
    private let captured = Mutex<[URLRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = Mutex(replies)
    }

    var requests: [URLRequest] { captured.withLock { $0 } }

    func body(_ index: Int) throws -> JSONValue {
        let data = try #require(requests[index].httpBody)
        return try JSONValue.parse(data)
    }

    private func next(_ request: URLRequest) throws -> Reply {
        captured.withLock { $0.append(request) }
        let reply = replies.withLock { queue -> Reply? in
            queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let reply else { throw LLMError.network("no scripted reply left") }
        if let error = reply.error { throw error }
        return reply
    }

    private func response(_ request: URLRequest, _ reply: Reply) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try next(request)
        return (reply.body, response(request, reply))
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let reply = try next(request)
        let chunks = reply.chunks ?? [reply.body]
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for c in chunks { continuation.yield(c) }
            continuation.finish()
        }
        return (response(request, reply), stream)
    }
}

/// Records requested backoff delays instead of sleeping.
final class SleepLog: Sendable {
    private let storage = Mutex<[TimeInterval]>([])
    var delays: [TimeInterval] { storage.withLock { $0 } }
    var sleeper: HTTPClient.Sleeper {
        { [self] seconds in storage.withLock { $0.append(seconds) } }
    }
}

func makeHTTP(_ transport: ScriptedTransport, sleeps: SleepLog = SleepLog()) -> HTTPClient {
    HTTPClient(transport: transport, maxRetries: 3, baseDelay: 1, sleeper: sleeps.sleeper)
}

func collectStream(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> (deltas: [String], done: ChatResponse?) {
    var deltas: [String] = []
    var done: ChatResponse?
    for try await e in stream {
        switch e {
        case .textDelta(let t): deltas.append(t)
        case .done(let r): done = r
        }
    }
    return (deltas, done)
}

import Testing
