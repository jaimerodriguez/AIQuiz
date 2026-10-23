import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// Phase 7: FSRS in sessions, quiz and review decks, and the reminder count.
@MainActor
final class SchedulingAppTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
    }

    private func quiz(_ name: String, cards: Int, archived: Bool = false) -> QuizRecord {
        let quiz = QuizRecord.make(from: QuizPayload(name: name, cards: (0..<cards).map { CardPayload(prompt: "\(name) \($0)", longAnswer: "A") }), origin: .topic)
        quiz.isArchived = archived
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    private func schedule(_ card: CardRecord, dueIn days: Double, now: Date = .now) {
        card.schedule = FSRS.State(stability: 5, difficulty: 5, dueAt: now.addingTimeInterval(days * 86_400), reps: 1, lastRating: 3, lastReviewedAt: now.addingTimeInterval(-86_400))
    }

    func testRecordingASessionSchedulesEveryGradedCard() throws {
        let q = quiz("Q", cards: 3)
        XCTAssertEqual(q.dueCount, 3, "new cards are due")
        let deck = ScoreStore.makeDeck(for: q)
        let ids = deck.cards.map(\.id)
        deck.record(.correct); deck.next()
        deck.record(.wrong); deck.next()
        deck.record(.skipped); deck.next()
        ScoreStore.recordSession(for: q, deck: deck, mode: .quizVoice, in: context)
        let byId = Dictionary(uniqueKeysWithValues: q.cards.map { ($0.id, $0) })
        let good = try XCTUnwrap(byId[ids[0]])
        XCTAssertEqual(good.stability, FSRS.initialStability(.good), accuracy: 0.0001)
        XCTAssertEqual(good.lastRating, 3)
        XCTAssertGreaterThan(try XCTUnwrap(good.dueAt), Date.now.addingTimeInterval(3 * 86_400))
        let again = try XCTUnwrap(byId[ids[1]])
        XCTAssertEqual(again.lastRating, 1)
        XCTAssertLessThan(try XCTUnwrap(again.dueAt), Date.now.addingTimeInterval(3_600), "a forgotten card is due again soon")
        let skipped = try XCTUnwrap(byId[ids[2]])
        XCTAssertTrue(skipped.isNewCard, "skipped cards aren't scheduled")
        XCTAssertEqual(q.dueCount, 1, "only the skipped card is still due now")
    }

    func testQuizDecksTakeDueAndNewCardsUpToTheCap() {
        let q = quiz("Q", cards: 30)
        let cards = q.sortedCards
        for card in cards[0..<20] { schedule(card, dueIn: 5) }
        for card in cards[20..<25] { schedule(card, dueIn: -1) }
        XCTAssertEqual(ScoreStore.makeQuizDeck(for: q, cap: 20, includeNotDue: false).cards.count, 10, "5 due + 5 new")
        XCTAssertEqual(ScoreStore.makeQuizDeck(for: q, cap: 8, includeNotDue: false).cards.count, 8)
        XCTAssertEqual(ScoreStore.makeQuizDeck(for: q, cap: 100, includeNotDue: true).cards.count, 30)
        let first = ScoreStore.makeQuizDeck(for: q, cap: 20, includeNotDue: false).cards.prefix(5).map(\.id)
        XCTAssertEqual(Set(first), Set(cards[20..<25].map(\.id)), "due cards come first")
        for card in cards[20..<30] { schedule(card, dueIn: 3) }
        XCTAssertEqual(ScoreStore.makeQuizDeck(for: q, cap: 20, includeNotDue: false).cards.count, 20, "nothing due → the whole deck, capped")
    }

    func testReviewSpansQuizzesSkipsArchivedAndSavesOneSessionPerQuiz() throws {
        let a = quiz("A", cards: 2)
        let b = quiz("B", cards: 2)
        let archived = quiz("Z", cards: 2, archived: true)
        for card in a.cards + b.cards + archived.cards { schedule(card, dueIn: 5) }
        schedule(a.sortedCards[0], dueIn: -1)
        schedule(b.sortedCards[0], dueIn: -2)
        schedule(archived.sortedCards[0], dueIn: -3)
        try context.save()
        XCTAssertEqual(ScoreStore.dueCount(in: context), 2, "archived quizzes don't count")

        let deck = ScoreStore.makeReviewDeck(in: context, cap: 20)
        XCTAssertEqual(Set(deck.cards.map(\.prompt)), ["A 0", "B 0"])
        // The light shuffle (§10) may swap neighbours, so grade by card, not by position;
        // the order itself is covered by the seeded Scheduler tests in AIQuizCore.
        while let card = deck.current, !deck.ended {
            if card.prompt == "B 0" {
                deck.record(.correct)
                deck.markEasy(card.id)
            } else {
                deck.record(.wrong)
            }
            deck.next()
        }
        ScoreStore.recordReview(deck, in: context)

        XCTAssertEqual(a.sessions.map(\.sessionMode), [.review])
        XCTAssertEqual(b.sessions.map(\.sessionMode), [.review])
        XCTAssertEqual(b.sessions.first?.scorePercent, 1.0)
        XCTAssertEqual(a.sessions.first?.scorePercent, 0.0)
        XCTAssertEqual(b.sortedCards[0].lastRating, 4, "long-press Correct rates Easy")
        XCTAssertEqual(a.sortedCards[0].lapses, 1)
        XCTAssertTrue(deck.recorded)
    }

    func testTheReminderCountsCardsDueByTheReminderTime() {
        let a = quiz("A", cards: 3)
        let b = quiz("B", cards: 1)
        for card in a.cards + b.cards { schedule(card, dueIn: 10) }
        schedule(a.sortedCards[0], dueIn: 0.2)
        schedule(a.sortedCards[1], dueIn: 0.3)
        schedule(b.sortedCards[0], dueIn: 0.1)
        let tonight = Date.now.addingTimeInterval(0.5 * 86_400)
        let summary = DueNotifications.dueSummary(at: tonight, in: context)
        XCTAssertEqual(summary.cards, 3)
        XCTAssertEqual(summary.quizzes, 2)
        XCTAssertEqual(DueReminder.message(cards: summary.cards, quizzes: summary.quizzes), "3 cards due in 2 quizzes")
        XCTAssertEqual(DueNotifications.dueSummary(at: .now, in: context).cards, 0)
    }

    func testSettingsForSessionsAndRemindersPersist() {
        let suite = "SchedulingAppTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.sessionCap, 20)
        XCTAssertFalse(settings.reminderOn)
        settings.sessionCap = 35
        settings.reminderOn = true
        settings.reminderMinutes = 7 * 60 + 30
        settings.includeNotDue = true
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.sessionCap, 35)
        XCTAssertTrue(again.reminderOn)
        XCTAssertEqual(again.reminderMinutes, 450)
        XCTAssertTrue(again.includeNotDue)
        defaults.removePersistentDomain(forName: suite)
    }
}
