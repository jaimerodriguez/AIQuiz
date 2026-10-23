import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

/// Opt-in live test of the notes → cards pipeline (CR-006) against real models. Runs only via
/// `scripts/live-test.sh`, which reads keys from the Keychain (see LLMKit LiveTests).
private let env = ProcessInfo.processInfo.environment

private func liveClients() -> [LLMClient] {
    var clients: [LLMClient] = []
    if let key = env["AIQuiz_Ant_test_key"], !key.isEmpty {
        let model = env["AIQuiz_Ant_test_model"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-opus-5-5"
        clients.append(AnthropicClient(
            endpoint: LLMEndpoint(kind: .anthropic, name: "Anthropic \(model)", model: model, contextWindowTokens: 1_000_000),
            apiKey: key
        ))
    }
    if let key = env["AIQuiz_Oai_test_key"], !key.isEmpty, let model = env["AIQuiz_Oai_test_model"], !model.isEmpty {
        clients.append(OpenAICompatibleClient(
            endpoint: LLMEndpoint(kind: .openAICompatible, name: "OpenAI \(model)", baseURL: URL(string: "https://api.openai.com/v1"), model: model, contextWindowTokens: 128_000),
            apiKey: key
        ))
    }
    return clients
}

@Suite("Live study notes pipeline", .enabled(if: env["AIQUIZ_LIVE_TESTS"] == "1"))
struct LiveStudyNotesTests {
    @Test("topic → Markdown notes → cards drawn from them, on every configured provider")
    func pipeline() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        for client in clients {
            let quiz = try await QuizCreationPipeline.run(
                QuizGenRequest(source: .topic, topic: "The causes of the French Revolution", cardCount: 8, difficulty: "intro", language: "en", tone: "casual"),
                notesClient: client,
                cardsClient: client
            )
            let notes = try #require(quiz.studyNotes, "\(client.endpoint.name): no notes")
            let words = StudyNotesWriter.wordCount(notes)
            let blocks = MarkdownParser.parse(notes)
            let headings = blocks.filter { if case .heading = $0 { true } else { false } }
            let lists = blocks.filter {
                switch $0 { case .bulletList, .numberedList: true; default: false }
            }
            #expect(words >= 250, "\(client.endpoint.name): notes only \(words) words")
            #expect(headings.count >= 2, "\(client.endpoint.name): notes have \(headings.count) headings")
            #expect(!lists.isEmpty, "\(client.endpoint.name): notes have no lists")
            #expect(!notes.hasPrefix("```"), "\(client.endpoint.name): notes wrapped in a code fence")
            #expect((5...12).contains(quiz.cards.count), "\(client.endpoint.name): \(quiz.cards.count) cards")
            #expect(quiz.cards.allSatisfy { !$0.prompt.isEmpty && !$0.longAnswer.isEmpty })
            print("[live] \(client.endpoint.name): \(words) words, \(headings.count) headings, \(quiz.cards.count) cards")
        }
    }
}
