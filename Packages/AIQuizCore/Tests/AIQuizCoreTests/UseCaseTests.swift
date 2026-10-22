import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

@Suite("QuizGenerator")
struct QuizGeneratorTests {
    static let validQuiz = """
    {"quiz":{"name":"Rome","cards":[
      {"prompt":"Who was first?","long_answer":"Augustus, 27 BC.","short_answer":"Augustus","hint":null},
      {"prompt":"Who was second?","long_answer":"Tiberius.","short_answer":null,"hint":"Capri"}
    ]}}
    """

    @Test("generates a quiz, requesting the quiz schema with streaming and medium effort")
    func happyPath() async throws {
        let client = FakeLLMClient.scripted([Self.validQuiz])
        let quiz = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "Rome", cardCount: 2), using: client)
        #expect(quiz.name == "Rome")
        #expect(quiz.cards.count == 2)
        #expect(quiz.cards[0].hint == nil, "null decodes as absent")
        #expect(quiz.cards[1].shortAnswer == nil)
        #expect(quiz.cards[1].hint == "Capri")

        let request = try #require(client.recorder.requests.first)
        #expect(request.responseFormat?.name == "quiz")
        #expect(request.responseFormat?.schema == QuizGenerator.schema)
        #expect(request.effort == .medium)
        #expect(request.maxTokens == 32_000)
        #expect(request.timeout == 300)
        #expect(request.messages[0].text.contains("Topic: Rome"))
        #expect(request.messages[0].text.contains("Card count: 2"))
    }

    @Test("malformed then valid succeeds on the retry")
    func retry() async throws {
        let client = FakeLLMClient.scripted(["Sure! Here is your quiz", Self.validQuiz])
        let quiz = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "Rome"), using: client)
        #expect(quiz.cards.count == 2)
        #expect(client.recorder.count == 2)
    }

    @Test("a quiz with no cards is rejected and retried")
    func emptyQuiz() async throws {
        let client = FakeLLMClient.scripted([#"{"quiz":{"name":"Empty","cards":[]}}"#, Self.validQuiz])
        let quiz = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "Rome"), using: client)
        #expect(quiz.cards.count == 2)
        #expect(client.recorder.requests[1].messages[0].text.contains("the quiz has no cards"))
    }

    @Test("twice malformed surfaces malformedResponse")
    func twiceMalformed() async {
        let client = FakeLLMClient.scripted(["nope", "still nope"])
        await #expect(throws: LLMError.malformedResponse("no JSON object found")) {
            _ = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "x"), using: client)
        }
    }

    @Test("source larger than 80% of the context window is rejected before any request")
    func contextBudget() async {
        let small = LLMEndpoint(kind: .fake, name: "Small", model: "m", contextWindowTokens: 4_096)
        let client = FakeLLMClient(endpoint: small) { _ in Self.validQuiz }
        let source = String(repeating: "word ", count: 4_000)
        await #expect(throws: LLMError.contextTooLong) {
            _ = try await QuizGenerator.generate(QuizGenRequest(source: .markdown, topic: "t", sourceContent: source), using: client)
        }
        #expect(client.recorder.count == 0)
    }

    @Test("source modes embed the content between markers")
    func sourcePrompt() {
        let user = PromptBuilder.quizUser(QuizGenRequest(source: .article, topic: "t", sourceContent: "BODY"))
        #expect(user.contains("---SOURCE-ARTICLE---\nBODY\n---END-SOURCE---"))
    }

    @Test("schema marks optional card fields nullable and still required")
    func schemaShape() {
        let card = QuizGenerator.schema.jsonValue["properties"]?["quiz"]?["properties"]?["cards"]?["items"]
        let required = card?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(required) == ["prompt", "long_answer", "short_answer", "hint"])
        #expect(card?["properties"]?["hint"]?["anyOf"] != nil)
    }
}

@Suite("AnswerJudge")
struct AnswerJudgeTests {
    let request = JudgeRequest(prompt: "2+2?", userAnswer: "four", correctShort: "4", correctLong: "Four.")

    @Test("returns the verdict with low effort and a small token budget")
    func judge() async throws {
        let client = FakeLLMClient.scripted([#"{"verdict":"correct","reason":"Same number."}"#])
        let v = try await AnswerJudge.judge(request, using: client)
        #expect(v == JudgeVerdict(verdict: .correct, reason: "Same number."))
        let sent = try #require(client.recorder.requests.first)
        #expect(sent.effort == .low)
        #expect(sent.maxTokens == 4_096)
        #expect(sent.responseFormat?.name == "judge")
        #expect(sent.messages[0].text.contains("Candidate answer: four"))
    }

    @Test("an out-of-set verdict is retried")
    func invalidVerdict() async throws {
        let client = FakeLLMClient.scripted([
            #"{"verdict":"mostly","reason":"x"}"#,
            #"{"verdict":"partial","reason":"Half right."}"#
        ])
        let v = try await AnswerJudge.judge(request, using: client)
        #expect(v.verdict == .partial)
        #expect(client.recorder.count == 2)
    }

    @Test("empty answers are labelled in the prompt")
    func emptyAnswer() {
        let user = PromptBuilder.judgeUser(JudgeRequest(prompt: "p", userAnswer: "   ", correctLong: "l"))
        #expect(user.contains("Candidate answer: (empty)"))
    }
}
