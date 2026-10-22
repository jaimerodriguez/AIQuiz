import Foundation
import Synchronization
import Testing
@testable import LLMKit

@Suite("OpenAICompatibleClient")
struct OpenAICompatibleClientTests {
    static func endpoint(base: String = "https://api.openai.com/v1", model: String = "gpt-test", schema: Bool = true) -> LLMEndpoint {
        LLMEndpoint(kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: base), model: model, contextWindowTokens: 128_000, supportsJSONSchema: schema)
    }

    static let schema = JSONSchema.object(properties: [.init("verdict", .string())])
    static let request = ChatRequest(
        system: "You grade.",
        messages: [.user("Q?")],
        maxTokens: 2000,
        responseFormat: ResponseFormat(name: "judge", schema: schema),
        effort: .low
    )
    static let okBody = #"{"model":"gpt-test","choices":[{"message":{"role":"assistant","content":"{\"verdict\":\"correct\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":9,"prompt_tokens_details":{"cached_tokens":4}}}"#
    static let rejectFormat = #"{"error":{"message":"Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model."}}"#

    @Test("golden request for OpenAI: strict json_schema, max_completion_tokens, bearer auth")
    func goldenOpenAI() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "sk-o", http: makeHTTP(t))
        let r = try await client.complete(Self.request)

        #expect(t.requests[0].url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-o")
        let expected: JSONValue = [
            "model": "gpt-test",
            "max_completion_tokens": 2000,
            "messages": [["role": "system", "content": "You grade."], ["role": "user", "content": "Q?"]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "judge", "strict": true, "schema": Self.schema.jsonValue]]
        ]
        #expect(try t.body(0) == expected)
        #expect(r.text == #"{"verdict":"correct"}"#)
        #expect(r.usage == TokenUsage(input: 40, output: 9, cacheRead: 4))
    }

    @Test("local server: max_tokens, no auth header without a key, no sampling params")
    func localServer() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(base: "http://192.168.1.20:11434/v1"), apiKey: "", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        let body = try t.body(0)
        #expect(t.requests[0].url?.absoluteString == "http://192.168.1.20:11434/v1/chat/completions")
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body["max_tokens"]?.intValue == 2000)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["temperature"] == nil)
    }

    @Test("response_format ladder: json_schema → json_object → prompt only, reporting lost support")
    func ladder() async throws {
        let t = ScriptedTransport([
            .json(400, Self.rejectFormat),
            .json(400, #"{"error":{"message":"response_format json_object unsupported"}}"#),
            .json(200, Self.okBody)
        ])
        let learned = Mutex<[Bool]>([])
        let client = OpenAICompatibleClient(
            endpoint: Self.endpoint(base: "http://localhost:1234/v1"), apiKey: nil, http: makeHTTP(t),
            onJSONSchemaSupport: { v in learned.withLock { $0.append(v) } }
        )
        _ = try await client.complete(Self.request)

        #expect(try t.body(0)["response_format"]?["type"]?.stringValue == "json_schema")
        #expect(try t.body(1)["response_format"]?["type"]?.stringValue == "json_object")
        #expect(try t.body(2)["response_format"] == nil)
        let system = try t.body(2)["messages"]?[0]?["content"]?.stringValue ?? ""
        #expect(system.contains("JSON Schema"))
        #expect(system.contains("\"verdict\""))
        #expect(learned.withLock { $0 } == [false])
    }

    @Test("endpoint known not to support json_schema starts at json_object with schema in the prompt")
    func startsAtJSONObject() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(schema: false), apiKey: "k", http: makeHTTP(t))
        _ = try await client.complete(Self.request)
        #expect(try t.body(0)["response_format"]?["type"]?.stringValue == "json_object")
        #expect((try t.body(0)["messages"]?[0]?["content"]?.stringValue ?? "").contains("JSON Schema"))
    }

    @Test("unrelated 400 is not treated as a format rejection")
    func unrelated400() async {
        let t = ScriptedTransport([.json(400, #"{"error":{"message":"model not supported"}}"#)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        await #expect(throws: LLMError.badRequest(status: 400, detail: "model not supported")) {
            _ = try await client.complete(Self.request)
        }
        #expect(t.requests.count == 1)
    }

    @Test("refusal field and content_filter both throw refused")
    func refusals() async {
        let refusal = #"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#
        let filter = #"{"choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}"#
        for body in [refusal, filter] {
            let t = ScriptedTransport([.json(200, body)])
            let client = OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
            await #expect(throws: LLMError.self) { _ = try await client.complete(Self.request) }
        }
    }

    @Test("streaming: deltas, finish reason, usage chunk, [DONE]")
    func streaming() async throws {
        let text = """
        data: {"model":"gpt-test","choices":[{"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}

        data: [DONE]


        """
        let t = ScriptedTransport([.sse(text, chunkSize: 9)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        let (deltas, done) = try await collectStream(client.stream(Self.request))
        #expect(deltas == ["Hel", "lo"])
        #expect(done?.text == "Hello")
        #expect(done?.usage == TokenUsage(input: 10, output: 2))
        #expect(try t.body(0)["stream_options"]?["include_usage"]?.boolValue == true)
    }

    @Test("streaming to a local server omits stream_options")
    func streamingLocal() async throws {
        let t = ScriptedTransport([.sse("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\ndata: [DONE]\n\n")])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(base: "http://10.0.0.5:11434/v1"), apiKey: nil, http: makeHTTP(t))
        _ = try await collectStream(client.stream(Self.request))
        #expect(try t.body(0)["stream_options"] == nil)
    }

    @Test("images use data URLs in content parts")
    func images() async throws {
        let t = ScriptedTransport([.json(200, Self.okBody)])
        let client = OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t))
        let req = ChatRequest(system: "", messages: [ChatMessage(role: .user, parts: [.text("what?"), .image(Data([255]), mimeType: "image/jpeg")])])
        _ = try await client.complete(req)
        let content = try t.body(0)["messages"]?[0]?["content"]
        #expect(content?[1]?["image_url"]?["url"]?.stringValue == "data:image/jpeg;base64,/w==")
        #expect(try t.body(0)["messages"]?.arrayValue?.count == 1, "empty system prompt is omitted")
    }

    @Test("listModels returns sorted ids")
    func models() async throws {
        let t = ScriptedTransport([.json(200, #"{"object":"list","data":[{"id":"zeta"},{"id":"alpha"}]}"#)])
        let ids = try await OpenAICompatibleClient(endpoint: Self.endpoint(), apiKey: "k", http: makeHTTP(t)).listModels()
        #expect(ids == ["alpha", "zeta"])
        #expect(t.requests[0].url?.absoluteString == "https://api.openai.com/v1/models")
    }
}
