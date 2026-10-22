import Foundation
import Testing
@testable import LLMKit

@Suite("AnthropicClient")
struct AnthropicClientTests {
    static func endpoint(model: String = "claude-opus-5-5", base: String? = nil) -> LLMEndpoint {
        LLMEndpoint(kind: .anthropic, name: "Anthropic", baseURL: base.flatMap(URL.init(string:)), model: model, contextWindowTokens: 1_000_000)
    }

    static let schema = JSONSchema.object(properties: [.init("verdict", .string(enumValues: ["correct", "wrong"]))])

    static let request = ChatRequest(
        system: "You grade.",
        messages: [.user("Is 2+2=4?")],
        maxTokens: 4096,
        responseFormat: ResponseFormat(name: "judge", schema: schema),
        effort: .low,
        timeout: 60
    )

    static let okBody = """
    {"id":"msg_1","model":"claude-opus-5-5","stop_reason":"end_turn",
     "content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\\"verdict\\":"},{"type":"text","text":"\\"correct\\"}"}],
     "usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":5}}
    """

    @Test("golden request body and headers")
    func goldenRequest() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "sk-test", http: makeHTTP(t))
        _ = try await client.complete(Self.request)

        let req = t.requests[0]
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(req.timeoutInterval == 60)

        let expected: JSONValue = [
            "model": "claude-opus-5-5",
            "max_tokens": 4096,
            "system": "You grade.",
            "messages": [["role": "user", "content": [["type": "text", "text": "Is 2+2=4?"]]]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Self.schema.jsonValue]],
            "fallbacks": "default"
        ]
        #expect(try t.body(0) == expected)
    }

    @Test("never sends sampling parameters or an assistant prefill")
    func noForbiddenFields() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        let body = try t.body(0)
        for key in ["temperature", "top_p", "top_k"] { #expect(body[key] == nil) }
        let roles = body["messages"]?.arrayValue?.compactMap { $0["role"]?.stringValue } ?? []
        #expect(roles.last == "user")
    }

    @Test("server fallback only for supported models on the Claude API host", arguments: [
        ("claude-opus-5-5", nil as String?, true),
        ("claude-sonnet-5-5", nil, true),
        ("claude-fable-5-1", nil, true),
        ("claude-haiku-5-5", nil, false),
        ("claude-opus-5-5", "https://proxy.example.com", false)
    ])
    func fallbackGating(model: String, base: String?, expected: Bool) async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(model: model, base: base), apiKey: "k", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        #expect((t.requests[0].value(forHTTPHeaderField: "anthropic-beta") != nil) == expected)
        #expect((try t.body(0)["fallbacks"] != nil) == expected)
    }

    @Test("effort is omitted for models that reject it")
    func effortGating() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(model: "claude-haiku-4-5"), apiKey: "k", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        #expect(try t.body(0)["output_config"]?["effort"] == nil)
        #expect(try t.body(0)["output_config"]?["format"] != nil)
    }

    @Test("base URL with /v1 is not doubled")
    func baseURLWithV1() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(base: "https://gw.example.com/v1/"), apiKey: "k", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        #expect(t.requests[0].url?.absoluteString == "https://gw.example.com/v1/messages")
    }

    @Test("response joins text blocks, skips thinking, reads usage")
    func parseResponse() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let r = try await AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t)).complete(Self.request)
        #expect(r.text == #"{"verdict":"correct"}"#)
        #expect(r.usage == TokenUsage(input: 120, output: 30, cacheRead: 5))
        #expect(r.stopReason == .endTurn)
        #expect(r.model == "claude-opus-5-5")
    }

    @Test("refusal stop reason throws refused with category")
    func refusal() async {
        let body = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"usage":{}}"#
        let t = ScriptedTransport([.json(200, body)])
        await #expect(throws: LLMError.refused(category: "cyber")) {
            _ = try await AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t)).complete(Self.request)
        }
    }

    @Test("max_tokens stop reason is reported")
    func maxTokens() async throws {
        let body = #"{"content":[{"type":"text","text":"{\"a\":"}],"stop_reason":"max_tokens","usage":{}}"#
        let t = ScriptedTransport([.json(200, body)])
        let r = try await AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t)).complete(Self.request)
        #expect(r.stopReason == .maxTokens)
    }

    static let streamText = """
    event: message_start
    data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":1,"cache_read_input_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

    event: ping
    data: {"type":"ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":", world"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    @Test("streaming yields text deltas only and a final response")
    func streaming() async throws {
        let t = ScriptedTransport([.sse(Self.streamText, chunkSize: 5)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        let (deltas, done) = try await collectStream(client.stream(Self.request))
        #expect(deltas == ["Hello", ", world"])
        #expect(done?.text == "Hello, world")
        #expect(done?.usage == TokenUsage(input: 50, output: 12, cacheRead: 0))
        #expect(try t.body(0)["stream"]?.boolValue == true)
    }

    @Test("stream error event maps to a typed error")
    func streamError() async {
        let text = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
        let t = ScriptedTransport([.sse(text)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        await #expect(throws: LLMError.server(status: 529)) {
            _ = try await collectStream(client.stream(Self.request))
        }
    }

    @Test("streamed refusal throws")
    func streamRefusal() async {
        let text = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"category\":\"bio\"}},\"usage\":{\"output_tokens\":0}}\n\n"
        let t = ScriptedTransport([.sse(text)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        await #expect(throws: LLMError.refused(category: "bio")) {
            _ = try await collectStream(client.stream(Self.request))
        }
    }

    @Test("image parts become base64 image blocks")
    func imageBlocks() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        let req = ChatRequest(system: "", messages: [ChatMessage(role: .user, parts: [.image(Data([1, 2, 3]), mimeType: "image/png"), .text("what?")])])
        _ = try await client.complete(req)
        let block = try t.body(0)["messages"]?[0]?["content"]?[0]
        #expect(block?["type"]?.stringValue == "image")
        #expect(block?["source"]?["media_type"]?.stringValue == "image/png")
        #expect(block?["source"]?["data"]?.stringValue == "AQID")
        #expect(try t.body(0)["system"] == nil, "empty system is omitted")
    }

    @Test("listModels reads ids")
    func models() async throws {
        let t = ScriptedTransport([.json(200, #"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-haiku-5-5"}],"has_more":false}"#)])
        let ids = try await AnthropicClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t)).listModels()
        #expect(ids == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(t.requests[0].httpMethod == "GET")
        #expect(t.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
    }
}
