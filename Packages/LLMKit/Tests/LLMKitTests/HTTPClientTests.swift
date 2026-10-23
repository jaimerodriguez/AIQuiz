import Foundation
import Testing
@testable import LLMKit

@Suite("HTTPClient retry and error mapping")
struct HTTPClientTests {
    let request = URLRequest(url: URL(string: "https://example.test/v1/x")!)

    @Test("429 then 200 honours Retry-After")
    func rateLimitThenSuccess() async throws {
        let t = ScriptedTransport([
            .json(429, #"{"error":{"message":"slow down"}}"#, headers: ["Retry-After": "7"]),
            .json(200, #"{"ok":true}"#)
        ])
        let sleeps = SleepLog()
        let data = try await makeHTTP(t, sleeps: sleeps).send(request)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(sleeps.delays == [7])
        #expect(t.requests.count == 2)
    }

    @Test("Retry-After is capped at 30 seconds")
    func retryAfterCap() async throws {
        let t = ScriptedTransport([.json(429, "{}", headers: ["retry-after": "600"]), .json(200, "{}")])
        let sleeps = SleepLog()
        _ = try await makeHTTP(t, sleeps: sleeps).send(request)
        #expect(sleeps.delays == [30])
    }

    @Test("5xx retries three times with exponential backoff, then fails")
    func serverErrorsExhaust() async {
        let t = ScriptedTransport(Array(repeating: .json(503, "{}"), count: 4))
        let sleeps = SleepLog()
        await #expect(throws: LLMError.server(status: 503)) {
            _ = try await makeHTTP(t, sleeps: sleeps).send(request)
        }
        #expect(sleeps.delays == [1, 2, 4])
        #expect(t.requests.count == 4)
    }

    @Test("network errors are retried")
    func networkRetry() async throws {
        let t = ScriptedTransport([.failure(.network("offline")), .json(200, "{}")])
        _ = try await makeHTTP(t).send(request)
        #expect(t.requests.count == 2)
    }

    @Test("4xx errors are not retried", arguments: [
        (400, #"{"error":{"message":"bad field"}}"#, LLMError.badRequest(status: 400, detail: "bad field")),
        (401, "{}", LLMError.unauthorized),
        (403, "{}", LLMError.unauthorized),
        (404, "{}", LLMError.notFound),
        (413, "{}", LLMError.contextTooLong),
        (400, #"{"error":{"message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#, LLMError.contextTooLong)
    ])
    func noRetry(status: Int, body: String, expected: LLMError) async {
        let t = ScriptedTransport([.json(status, body)])
        await #expect(throws: expected) {
            _ = try await makeHTTP(t).send(request)
        }
        #expect(t.requests.count == 1)
    }

    @Test("streaming open retries on 529 and reads the error body otherwise")
    func streamOpen() async throws {
        let t = ScriptedTransport([.json(529, #"{"error":{"message":"overloaded"}}"#), .sse("data: hi\n\n")])
        let chunks = try await makeHTTP(t).openStream(request)
        var all = Data()
        for try await c in chunks { all.append(c) }
        #expect(String(decoding: all, as: UTF8.self) == "data: hi\n\n")
        #expect(t.requests.count == 2)
    }

    @Test("a cancelled sleep surfaces as cancelled")
    func cancelledSleep() async {
        let t = ScriptedTransport([.json(500, "{}"), .json(200, "{}")])
        let http = HTTPClient(transport: t, maxRetries: 3, baseDelay: 1, sleeper: { _ in throw CancellationError() })
        await #expect(throws: LLMError.cancelled) {
            _ = try await http.send(request)
        }
    }

    @Test("error mapping helpers")
    func mapping() {
        #expect(LLMErrorMapping.map(URLError(.timedOut)) as? LLMError == .timedOut)
        #expect(LLMErrorMapping.map(URLError(.cancelled)) as? LLMError == .cancelled)
        #expect(LLMErrorMapping.map(CancellationError()) as? LLMError == .cancelled)
        #expect(HTTPErrorMapper.errorMessage(from: Data(#"{"error":"plain"}"#.utf8)) == "plain")
        #expect(HTTPErrorMapper.errorMessage(from: Data("not json".utf8)) == "not json")
    }

    @Test("user-facing error text never contains the response detail")
    func friendlyText() {
        let e = LLMError.badRequest(status: 400, detail: "secret internal detail")
        #expect(e.errorDescription?.contains("secret") == false)
        #expect(e.logDescription.contains("secret internal detail"))
    }
}
