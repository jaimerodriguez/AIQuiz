import XCTest
import SwiftData
import AIQuizCore
import LLMKit
@testable import AIQuiz

/// Phase 4 persistence and the auto-grade path with a real `AnswerJudge` over a fake client.
@MainActor
final class Phase4Tests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
    }

    private func quiz(_ n: Int) -> QuizRecord {
        let quiz = QuizRecord.make(from: QuizPayload(name: "Q", cards: (0..<n).map { CardPayload(prompt: "P\($0)", longAnswer: "L\($0)", hint: $0 == 0 ? "H0" : nil) }), origin: .topic)
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    func testExpandInsertsAfterTheCardAndKeepsOrder() {
        let q = quiz(3)
        let middle = q.sortedCards[1]
        q.insertCards([CardPayload(prompt: "New A", longAnswer: "a"), CardPayload(prompt: "New B", longAnswer: "b")], after: middle)
        XCTAssertEqual(q.sortedCards.map(\.prompt), ["P0", "P1", "New A", "New B", "P2"])
        XCTAssertEqual(q.cardCount, 5)
    }

    func testAIHintsAreStoredAndReachTheSession() throws {
        let q = quiz(1)
        let card = try XCTUnwrap(q.cards.first)
        card.aiHints = ["Stronger", "Strongest"]
        try context.save()
        XCTAssertEqual(card.aiHints, ["Stronger", "Strongest"])
        let snapshot = CardSnapshot(card)
        XCTAssertEqual(snapshot.hints, ["H0", "Stronger", "Strongest"], "author's hint first, then AI hints")
        card.aiHints = []
        XCTAssertNil(card.aiHintsData)
    }

    func testAIOutcomeFieldsPersistWithTheSession() throws {
        let q = quiz(2)
        let deck = ScoreStore.makeDeck(for: q)
        deck.record(.correct, ai: AIGrade(verdict: .partial, reason: "Close."))
        deck.setExplanation("Because.", for: deck.current!.id)
        deck.next()
        deck.record(.wrong)
        deck.next()
        let session = try XCTUnwrap(ScoreStore.recordSession(for: q, deck: deck, mode: .quizVoice, in: context))
        session.recapText = "Recap."
        try context.save()
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<SessionRecord>()).first)
        XCTAssertEqual(stored.recapText, "Recap.")
        XCTAssertEqual(stored.outcomes.count, 2)
        XCTAssertEqual(stored.outcomes[0].aiVerdict, .partial)
        XCTAssertTrue(stored.outcomes[0].userOverrode)
        XCTAssertEqual(stored.outcomes[0].explanation, "Because.")
        XCTAssertNil(stored.outcomes[1].aiVerdict)
        XCTAssertFalse(stored.outcomes[1].userOverrode)
    }

    /// The grading call resolves after the user has already moved on: nothing lands on the
    /// next card, and grading never waited.
    func testAutoGradeWithASlowEndpointNeverBlocksGrading() async throws {
        let client = FakeLLMClient(latency: .milliseconds(400)) { _ in #"{"verdict":"wrong","reason":"Too slow."}"# }
        let player = QuizVoicePlayer(
            deck: ScoreStore.makeDeck(for: quiz(2)),
            recognizer: ScriptedRecognizer(delay: .milliseconds(5)),
            autoJudge: { try await AnswerJudge.judge($0, using: client) },
            silenceTimeout: nil
        )
        await player.startListening()
        try await Task.sleep(for: .milliseconds(30))
        player.stopListeningAndReveal()
        XCTAssertTrue(player.aiJudging)
        player.record(.correct)
        XCTAssertEqual(player.phase, .awaitingAnswer)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(player.aiVerdict)
        XCTAssertNil(player.deck.toCardOutcomes().first?.aiVerdict)
    }

    func testAutoGradeWithAFakeEndpointPreselects() async throws {
        let client = FakeLLMClient { _ in #"{"verdict":"partial","reason":"Half right."}"# }
        let player = QuizVoicePlayer(
            deck: ScoreStore.makeDeck(for: quiz(1)),
            recognizer: ScriptedRecognizer(delay: .milliseconds(5)),
            autoJudge: { try await AnswerJudge.judge($0, using: client) },
            silenceTimeout: nil
        )
        await player.startListening()
        try await Task.sleep(for: .milliseconds(30))
        player.stopListeningAndReveal()
        for _ in 0..<50 where player.aiVerdict == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.aiVerdict, AIGrade(verdict: .partial, reason: "Half right."))
        XCTAssertEqual(client.recorder.requests.first?.responseFormat?.name, "judge")
    }

    func testAutoGradeSettingDefaultsOnAndPersists() {
        let suite = "Phase4Tests.autoGrade"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(AppSettings(defaults: defaults).autoGrade, "S-3 is on by default")
        AppSettings(defaults: defaults).autoGrade = false
        XCTAssertFalse(AppSettings(defaults: defaults).autoGrade)
        defaults.removePersistentDomain(forName: suite)
    }
}
