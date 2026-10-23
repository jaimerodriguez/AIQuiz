import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

@MainActor
final class ScoreStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: QuizRecord.self, CardRecord.self, SessionRecord.self,
            configurations: config
        )
    }

    private func makeQuiz(cardCount: Int) -> QuizRecord {
        let quiz = QuizRecord(name: "Test")
        for i in 0..<cardCount {
            let card = CardRecord(prompt: "p\(i)", longAnswer: "l\(i)", orderIndex: i)
            card.quiz = quiz
            quiz.cards.append(card)
        }
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    func testMakeDeckContainsEveryCardOnce() {
        let quiz = makeQuiz(cardCount: 12)
        let deck = ScoreStore.makeDeck(for: quiz)
        XCTAssertEqual(deck.cards.count, 12)
        XCTAssertEqual(Set(deck.cards.map(\.id)), Set(quiz.cards.map(\.id)))
    }

    func testMakeDeckHonoursCardLimit() {
        let quiz = makeQuiz(cardCount: 12)
        let deck = ScoreStore.makeDeck(for: quiz, cardLimit: 5)
        XCTAssertEqual(deck.cards.count, 5)
    }

    func testRecordSessionUpdatesHistoryAndCreatesSession() {
        let quiz = makeQuiz(cardCount: 3)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.correct); deck.next()
        deck.record(.partial); deck.next()
        deck.record(.wrong); deck.next()
        XCTAssertTrue(deck.ended)

        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)

        XCTAssertEqual(quiz.sessions.count, 1)
        let session = quiz.sessions[0]
        XCTAssertEqual(session.sessionMode, .quizVoice)
        XCTAssertFalse(session.abandoned)
        XCTAssertEqual(session.scorePercent!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(session.outcomes.count, 3)

        let byId = Dictionary(uniqueKeysWithValues: quiz.cards.map { ($0.id, $0) })
        for (card, verdict) in deck.scoredCards {
            let record = byId[card.id]!
            XCTAssertNotNil(record.lastSeenAt)
            switch verdict {
            case .correct: XCTAssertEqual(record.correctCount, 1)
            case .partial: XCTAssertEqual(record.partialCount, 1)
            case .wrong: XCTAssertEqual(record.wrongCount, 1)
            case .skipped: XCTFail("unexpected")
            }
        }
        XCTAssertEqual(quiz.bestScore!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(quiz.averageScore!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(quiz.sessionCount, 1)
    }

    func testAbandonedSessionIsNotPersisted() {
        let quiz = makeQuiz(cardCount: 2)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.correct)
        deck.abandon()
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)
        XCTAssertTrue(quiz.sessions.isEmpty)
        XCTAssertEqual(quiz.cards.map(\.correctCount).reduce(0, +), 0)
    }

    func testQuizModeWithNoOutcomesIsNotPersisted() {
        let quiz = makeQuiz(cardCount: 2)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.next(); deck.next()
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)
        XCTAssertTrue(quiz.sessions.isEmpty)
    }

    func testStudyModeWithNoOutcomesIsPersistedWithoutScore() {
        let quiz = makeQuiz(cardCount: 2)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.next(); deck.next()
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .studyRead, in: context)
        XCTAssertEqual(quiz.sessions.count, 1)
        XCTAssertNil(quiz.sessions[0].scorePercent)
        XCTAssertNil(quiz.bestScore)
    }

    func testSkippedDoesNotTouchHistory() {
        let quiz = makeQuiz(cardCount: 1)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.skipped)
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)
        XCTAssertNil(quiz.cards[0].lastSeenAt)
        XCTAssertEqual(quiz.sessions.count, 1)
        XCTAssertNil(quiz.sessions[0].scorePercent)
    }

    func testPracticeDeckFromMissedCards() {
        let quiz = makeQuiz(cardCount: 3)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.wrong); deck.next()
        deck.record(.correct); deck.next()
        deck.record(.partial)
        let practice = ScoreStore.makeDeck(cards: deck.missedCards)
        XCTAssertEqual(practice.cards.count, 2)
        XCTAssertEqual(practice.cards.map(\.id), deck.missedCards.map(\.id))
    }
}
