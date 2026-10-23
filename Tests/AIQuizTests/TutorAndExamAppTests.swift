import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// Phase 8: recording an oral exam, adding chat cards, and the speech composition.
@MainActor
final class TutorAndExamAppTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
    }

    private func quiz(cards: Int) -> QuizRecord {
        let quiz = QuizRecord.make(from: QuizPayload(name: "Exam", cards: (0..<cards).map { CardPayload(prompt: "P\($0)", longAnswer: "A\($0)") }), origin: .topic)
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    func testAnOralExamIsRecordedWithTheGradersVerdictsAndSchedulesTheCards() throws {
        let q = quiz(cards: 3)
        let cards = q.sortedCards.map(CardSnapshot.init)
        let deck = ScoreStore.makeDeck(cards: cards)
        deck.next(); deck.next(); deck.next()
        deck.recordAll(.correct, for: cards[0].id, ai: AIGrade(verdict: .correct, reason: "Right."))
        deck.recordAll(.wrong, for: cards[1].id, ai: AIGrade(verdict: .wrong, reason: "Off."))
        let session = try XCTUnwrap(ScoreStore.recordSession(for: q, deck: deck, mode: .oralExam, in: context))
        XCTAssertEqual(session.sessionMode, .oralExam)
        XCTAssertEqual(try XCTUnwrap(session.scorePercent), 0.5, accuracy: 0.001)
        let outcomes = session.outcomes
        XCTAssertEqual(outcomes.count, 2, "the card that was never asked has no outcome")
        XCTAssertEqual(outcomes.first { $0.cardId == cards[0].id }?.aiReason, "Right.")
        XCTAssertEqual(outcomes.first { $0.cardId == cards[1].id }?.userOverrode, false, "the examiner's verdict is not an override")
        let byId = Dictionary(uniqueKeysWithValues: q.cards.map { ($0.id, $0) })
        XCTAssertEqual(byId[cards[0].id]?.lastRating, 3)
        XCTAssertEqual(byId[cards[1].id]?.lastRating, 1)
        XCTAssertTrue(try XCTUnwrap(byId[cards[2].id]).isNewCard)
    }

    func testChatCardsAreAppendedAtTheEndOfTheDeck() throws {
        let q = quiz(cards: 2)
        q.appendCards([CardPayload(prompt: "New A", longAnswer: "a"), CardPayload(prompt: "New B", longAnswer: "b")])
        try context.save()
        XCTAssertEqual(q.sortedCards.map(\.prompt), ["P0", "P1", "New A", "New B"])
        XCTAssertEqual(q.cardCount, 4)
    }

    func testUITestSpeechSharesOneRecordingCoordinatorAndAHintListener() async {
        let speech = SpeechServices.make(for: AppEnvironment(arguments: ["-UITestMode"]))
        XCTAssertTrue(speech.synthesizer is ScriptedSynthesizer)
        XCTAssertFalse(speech.hintListener === speech.recognizer, "UI tests hear \"hint\" from their own recognizer")
        XCTAssertEqual(speech.audio.mode, .inactive)
    }
}
