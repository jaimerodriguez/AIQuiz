import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

/// Opt-in: the Phase 4 features against real APIs (PLAN §1.6), so their strict schemas and
/// prompts are proven on Anthropic and OpenAI. Run with `scripts/live-test.sh`, which reads
/// the keys from the Keychain. Spends a few cents.
private let env = ProcessInfo.processInfo.environment
private let liveEnabled = env["AIQUIZ_LIVE_TESTS"] == "1"

private func liveClients() -> [LLMClient] {
    var clients: [LLMClient] = []
    if let key = env["AIQuiz_Ant_test_key"], !key.isEmpty {
        let model = env["AIQuiz_Ant_test_model"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5"
        clients.append(AnthropicClient(endpoint: LLMEndpoint(kind: .anthropic, name: "Anthropic", model: model, contextWindowTokens: 1_000_000), apiKey: key))
    }
    if let key = env["AIQuiz_Oai_test_key"], !key.isEmpty, let model = env["AIQuiz_Oai_test_model"], !model.isEmpty {
        clients.append(OpenAICompatibleClient(
            endpoint: LLMEndpoint(kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1"), model: model, contextWindowTokens: 128_000),
            apiKey: key
        ))
    }
    return clients
}

private let tiberius = CardPayload(prompt: "Who succeeded Augustus as Roman emperor?", longAnswer: "Tiberius, Augustus's stepson and adopted heir, ruled from 14 to 37 AD.", shortAnswer: "Tiberius", hint: "He later retired to Capri.")
private let deck = [
    tiberius,
    CardPayload(prompt: "Who was the first Roman emperor?", longAnswer: "Augustus, from 27 BC.", shortAnswer: "Augustus"),
    CardPayload(prompt: "Which emperor is famous?", longAnswer: "Nero fiddled while Rome burned; it is a legend.", shortAnswer: "Caligula", hint: "Nero"),
    CardPayload(prompt: "Who was the first emperor of Rome?", longAnswer: "Augustus became the first emperor in 27 BC.", shortAnswer: "Augustus")
]

@Suite("Live card AI (Phase 4)", .enabled(if: liveEnabled))
struct LiveCardAITests {
    @Test("judge, explain, why-wrong, hint, mnemonic, difficulty, expand, rewrite, lint and recap")
    func everyFeature() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty, "set AIQuiz_Ant_test_key and/or AIQuiz_Oai_test_key + AIQuiz_Oai_test_model")
        for client in clients {
            let name = client.endpoint.name
            let wrong = try await AnswerJudge.judge(JudgeRequest(prompt: tiberius.prompt, userAnswer: "Caligula", correctShort: "Tiberius", correctLong: tiberius.longAnswer), using: client)
            #expect(wrong.verdict == .wrong, "\(name) judged Caligula \(wrong.verdict): \(wrong.reason)")

            let explanation = try await Explainer.explain(tiberius, quizName: "Roman emperors", using: client)
            #expect(explanation.count > 40, "\(name) explain: \(explanation)")
            let why = try await Explainer.whyWrong(tiberius, answer: "Caligula", using: client)
            #expect(why.localizedCaseInsensitiveContains("tiberius"), "\(name) why-wrong: \(why)")

            let hint = try await HintGenerator.nextHint(for: tiberius, previous: ["He later retired to Capri."], using: client)
            #expect(!hint.isEmpty, "\(name) hint")
            let mnemonic = try await MnemonicGenerator.mnemonic(for: tiberius, using: client)
            #expect(!mnemonic.isEmpty, "\(name) mnemonic")

            let ratings = try await DifficultyRater.rate(deck, using: client)
            #expect(ratings.compactMap { $0 }.count == deck.count, "\(name) rated \(ratings)")

            let expanded = try await CardExpander.expand(tiberius, quizName: "Roman emperors", existingPrompts: deck.map(\.prompt), using: client)
            #expect((3...5).contains(expanded.count), "\(name) expanded to \(expanded.count)")

            let simpler = try await CardRewriter.rewrite(tiberius, .translate("Spanish"), using: client)
            #expect(simpler.longAnswer != tiberius.longAnswer, "\(name) rewrite")

            let issues = try await CardLinter.lint(deck, using: client)
            #expect(issues.contains { $0.index == 2 }, "\(name) lint should flag the mismatched card 2: \(issues.map { "\($0.index) \($0.kind)" })")
            #expect(issues.contains { $0.index == 3 || $0.index == 1 }, "\(name) lint should flag the duplicate: \(issues.map { "\($0.index) \($0.kind)" })")

            let recap = try await SessionRecapper.recap(quizName: "Roman emperors", results: [(tiberius, .wrong), (deck[1], .correct)], using: client)
            #expect(!recap.isEmpty, "\(name) recap")
            print("LIVE \(name): judge=\(wrong.verdict) ratings=\(ratings) expanded=\(expanded.count) lint=\(issues.map { "\($0.index):\($0.kind.rawValue)" })")
        }
    }
}
