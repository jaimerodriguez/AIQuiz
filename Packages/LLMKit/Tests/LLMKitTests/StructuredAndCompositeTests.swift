import Foundation
import Synchronization
import Testing
@testable import LLMKit

private struct Answer: Decodable, Sendable, Equatable {
    let verdict: String
}

private let answerTask = StructuredTask<Answer>(
    name: "judge",
    system: "sys",
    user: "question",
    schema: .object(properties: [.init("verdict", .string())])
)

@Suite("StructuredTask")
struct StructuredTaskTests {
    @Test("valid first response")
    func valid() async throws {
        let client = FakeLLMClient.scripted([#"{"verdict":"correct"}"#])
        #expect(try await client.run(answerTask) == Answer(verdict: "correct"))
        #expect(client.recorder.count == 1)
        let request = try #require(client.recorder.requests.first)
        #expect(request.responseFormat?.name == "judge")
        #expect(request.effort == .medium)
    }

    @Test("malformed then valid retries once with the decode error appended")
    func retry() async throws {
        let client = FakeLLMClient.scripted(["not json at all", #"{"verdict":"wrong"}"#])
        #expect(try await client.run(answerTask) == Answer(verdict: "wrong"))
        let requests = client.recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages[0].text == "question")
        #expect(requests[1].messages[0].text.hasPrefix("question\n\nThe previous response could not be used: no JSON object found"))
    }

    @Test("twice malformed throws malformedResponse")
    func twiceMalformed() async {
        let client = FakeLLMClient.scripted(["{}", "{}"])
        await #expect(throws: LLMError.malformedResponse("missing key 'verdict' at root")) {
            _ = try await client.run(answerTask)
        }
    }

    @Test("validation failure triggers the retry")
    func validation() async throws {
        var task = answerTask
        task.validate = { answer in
            if answer.verdict == "bogus" { throw LLMResponseParseError("verdict must be correct or wrong") }
        }
        let client = FakeLLMClient.scripted([#"{"verdict":"bogus"}"#, #"{"verdict":"correct"}"#])
        #expect(try await client.run(task) == Answer(verdict: "correct"))
        #expect(client.recorder.requests[1].messages[0].text.contains("verdict must be correct or wrong"))
    }

    @Test("truncated output is reported as such, not retried")
    func truncated() async {
        struct Truncating: LLMClient {
            var endpoint: LLMEndpoint { .fake() }
            func complete(_ request: ChatRequest) async throws -> ChatResponse {
                ChatResponse(text: #"{"verd"#, stopReason: .maxTokens)
            }
            func listModels() async throws -> [String] { [] }
        }
        await #expect(throws: LLMError.outputTruncated) {
            _ = try await Truncating().run(answerTask)
        }
    }

    @Test("streaming path assembles deltas")
    func streaming() async throws {
        var task = answerTask
        task.useStreaming = true
        let client = FakeLLMClient(streamChunkSize: 3) { _ in #"{"verdict":"correct"}"# }
        #expect(try await client.run(task) == Answer(verdict: "correct"))
    }

    @Test("transport errors propagate without a structured retry")
    func transportError() async {
        let client = FakeLLMClient.scripted([.failure(.unauthorized)])
        await #expect(throws: LLMError.unauthorized) { _ = try await client.run(answerTask) }
        #expect(client.recorder.count == 1)
    }
}

@Suite("Composite clients")
struct CompositeClientTests {
    @Test("metered client reports usage for complete and stream")
    func metering() async throws {
        let seen = Mutex<[TokenUsage]>([])
        let base = FakeLLMClient { _ in "hello world" }
        let metered = MeteredClient(base) { _, usage in seen.withLock { $0.append(usage) } }
        _ = try await metered.complete(ChatRequest(system: "", messages: [.user("abcd")]))
        _ = try await metered.collect(ChatRequest(system: "", messages: [.user("abcd")]))
        let usages = seen.withLock { $0 }
        #expect(usages.count == 2)
        #expect(usages[0].input == 1)
        #expect(usages[0].output == 3)
    }

    @Test("fallback used for retryable failures, not for auth failures")
    func fallback() async throws {
        let primary = FakeLLMClient.scripted([.failure(.server(status: 503))], endpoint: .fake(name: "P"))
        let backup = FakeLLMClient(endpoint: .fake(name: "B")) { _ in "from backup" }
        let r = try await FallbackClient(primary: primary, fallback: backup).complete(ChatRequest(system: "", messages: [.user("x")]))
        #expect(r.text == "from backup")

        let unauthorized = FakeLLMClient.scripted([.failure(.unauthorized)])
        await #expect(throws: LLMError.unauthorized) {
            _ = try await FallbackClient(primary: unauthorized, fallback: backup).complete(ChatRequest(system: "", messages: [.user("x")]))
        }
    }

    @Test("stream falls back when the primary fails before any text")
    func streamFallback() async throws {
        let primary = FakeLLMClient.scripted([.failure(.refused(category: "cyber"))])
        let backup = FakeLLMClient { _ in "ok" }
        let r = try await FallbackClient(primary: primary, fallback: backup).collect(ChatRequest(system: "", messages: [.user("x")]))
        #expect(r.text == "ok")
    }

    @Test("default stream implementation yields one delta and done")
    func defaultStream() async throws {
        struct Plain: LLMClient {
            var endpoint: LLMEndpoint { .fake() }
            func complete(_ request: ChatRequest) async throws -> ChatResponse { ChatResponse(text: "whole") }
            func listModels() async throws -> [String] { [] }
        }
        let (deltas, done) = try await collectStream(Plain().stream(ChatRequest(system: "", messages: [])))
        #expect(deltas == ["whole"])
        #expect(done?.text == "whole")
    }

    @Test("fake client honours cancellation during latency")
    func cancellation() async {
        let client = FakeLLMClient(latency: .seconds(10)) { _ in "late" }
        let task = Task { try await client.complete(ChatRequest(system: "", messages: [.user("x")])) }
        task.cancel()
        await #expect(throws: LLMError.cancelled) { _ = try await task.value }
    }

    @Test("token usage arithmetic and cost")
    func usageMath() {
        let u = TokenUsage(input: 1_000_000, output: 500_000) + TokenUsage(input: 0, output: 500_000, cacheRead: 3)
        #expect(u == TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 3))
        #expect(u.cost(inPerMTok: 4, outPerMTok: 20) == 24)
    }
}
