import Foundation
import Synchronization
import Testing
@testable import LLMKit

/// Opt-in tests against real APIs (PLAN §1.6). They spend real money, so they only run with
/// `AIQUIZ_LIVE_TESTS=1`. Run them with `scripts/live-test.sh`, which reads the keys from the
/// macOS login Keychain and passes them in these variables:
///
/// - `AIQuiz_Ant_test_key`: Anthropic key. Optional `AIQuiz_Ant_test_model` overrides `claude-opus-5-5`.
/// - `AIQuiz_Oai_test_key` and `AIQuiz_Oai_test_model`: OpenAI key and chat model (no OpenAI
///   model is hardcoded, DECISIONS ADR-008).
///
/// The names deliberately differ from `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` so no other tool
/// picks up the test keys.
private let env = ProcessInfo.processInfo.environment
private let liveEnabled = env["AIQUIZ_LIVE_TESTS"] == "1"

private struct Verdict: Decodable, Sendable {
    let verdict: String
    let reason: String
}

private let judgeTask = StructuredTask<Verdict>(
    name: "judge",
    system: "You grade short answers. Reply with the JSON object only.",
    user: "Prompt: What is 2 + 2?\nReference answer: 4\nCandidate answer: four",
    schema: .object(properties: [
        .init("verdict", .string(enumValues: ["correct", "partial", "wrong"])),
        .init("reason", .string())
    ]),
    maxTokens: 4096,
    effort: .low
)

/// Same shape as the quiz schema's optional fields: required but nullable (`anyOf: [T, null]`).
private struct CardLike: Decodable, Sendable {
    let prompt: String
    let hint: String?
}

private let nullableTask = StructuredTask<CardLike>(
    name: "card",
    system: "You write one flashcard as JSON.",
    user: "Write a flashcard about the capital of France. Set hint to null.",
    schema: .object(properties: [
        .init("prompt", .string()),
        .init("hint", .nullable(.string()))
    ]),
    maxTokens: 4096,
    effort: .low
)

/// Records whether the OpenAI client had to step down from strict json_schema.
private let schemaDowngrades = Mutex<Int>(0)

private func liveClients() -> [LLMClient] {
    var clients: [LLMClient] = []
    if let key = env["AIQuiz_Ant_test_key"], !key.isEmpty {
        let model = env["AIQuiz_Ant_test_model"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-opus-5-5"
        clients.append(AnthropicClient(
            endpoint: LLMEndpoint(kind: .anthropic, name: "Anthropic", model: model, contextWindowTokens: 1_000_000),
            apiKey: key
        ))
    }
    if let key = env["AIQuiz_Oai_test_key"], !key.isEmpty, let model = env["AIQuiz_Oai_test_model"], !model.isEmpty {
        clients.append(OpenAICompatibleClient(
            endpoint: LLMEndpoint(kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1"), model: model, contextWindowTokens: 128_000),
            apiKey: key,
            onJSONSchemaSupport: { supported in
                if !supported { schemaDowngrades.withLock { $0 += 1 } }
            }
        ))
    }
    return clients
}

@Suite("Live API", .enabled(if: liveEnabled))
struct LiveTests {
    @Test("complete, stream, structured and listModels against every configured provider")
    func everyProvider() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty, "set AIQuiz_Ant_test_key and/or AIQuiz_Oai_test_key + AIQuiz_Oai_test_model")
        for client in clients {
            let simple = ChatRequest(system: "Be terse.", messages: [.user("Reply with exactly: OK")], maxTokens: 2048, effort: .low)
            let r = try await client.complete(simple)
            #expect(r.text.uppercased().contains("OK"), "\(client.endpoint.name) complete: \(r.text)")
            #expect(r.usage.input > 0)

            let s = try await client.collect(simple)
            #expect(s.text.uppercased().contains("OK"), "\(client.endpoint.name) stream: \(s.text)")

            let v = try await client.run(judgeTask)
            #expect(v.verdict == "correct", "\(client.endpoint.name) judged \(v.verdict): \(v.reason)")

            let card = try await client.run(nullableTask)
            #expect(!card.prompt.isEmpty)
            #expect(card.hint == nil, "\(client.endpoint.name) returned hint \(card.hint ?? "")")

            let models = try await client.listModels()
            #expect(!models.isEmpty)
        }
        #expect(schemaDowngrades.withLock { $0 } == 0, "OpenAI rejected strict json_schema and fell back to a looser mode")
    }
}
