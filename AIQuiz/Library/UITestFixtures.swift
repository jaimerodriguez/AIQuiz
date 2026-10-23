import Foundation
import SwiftData
import AIQuizCore

/// Deterministic library contents for UI-test mode (PLAN §1.5).
enum UITestFixtures {
    static let deckName = "UITest Deck"

    /// SPEC N-8 scale target.
    static let largeQuizCount = 200
    static let largeCardsPerQuiz = 50
    static let largeSessionsPerQuiz = 25

    @MainActor
    static func seed(scenario: AppEnvironment.Scenario, in context: ModelContext) async {
        switch scenario {
        case .emptyLibrary:
            return
        case .largeLibrary:
            seedLargeLibrary(in: context)
            return
        default:
            break
        }
        SampleQuizzes.seedMissing(in: context)

        let name = deckName
        let descriptor = FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        let cards: [(String, String, String?, String?)] = [
            ("Fixture prompt one", "Fixture long answer one.", "Short one", "Hint one"),
            ("Fixture prompt two", "Fixture long answer two.", "Short two", nil),
            ("Fixture prompt three", "Fixture long answer three.", nil, "Hint three"),
            ("Fixture prompt four", "Fixture long answer four.", "Short four", "Hint four"),
            ("Fixture prompt five", "Fixture long answer five.", "Short five", nil),
            ("Fixture prompt six", "Fixture long answer six.", nil, nil)
        ]
        let payload = QuizPayload(
            name: name,
            description: "Seeded for UI tests.",
            tags: ["fixture"],
            cards: cards.map { CardPayload(prompt: $0.0, longAnswer: $0.1, shortAnswer: $0.2, hint: $0.3) }
        )
        context.insert(QuizRecord.make(from: payload, origin: .imported))
        context.insert(QuizRecord.make(from: mixedDeck, origin: .imported))
        try? context.save()
        scheduleForTests(in: context)
    }

    /// Phase 7: every seeded card is reviewed and due next week, except the 2 due cards of
    /// *UITest Due Deck*, so Due today shows exactly 2. The due deck has one past session for
    /// Insights. Quiz modes on the other decks fall back to the whole deck (nothing is due).
    @MainActor
    static func scheduleForTests(in context: ModelContext, now: Date = .now) {
        let reviewed = FSRS.State(stability: 7, difficulty: 5, dueAt: now.addingTimeInterval(7 * 86_400), reps: 1, lastRating: 3, lastReviewedAt: now.addingTimeInterval(-86_400))
        for card in (try? context.fetch(FetchDescriptor<CardRecord>())) ?? [] {
            card.schedule = reviewed
        }
        let due = QuizRecord.make(from: QuizPayload(name: "UITest Due Deck", tags: ["fixture"], cards: [
            CardPayload(prompt: "Due prompt one", longAnswer: "Due answer one.", shortAnswer: "Due one"),
            CardPayload(prompt: "Due prompt two", longAnswer: "Due answer two.", shortAnswer: "Due two"),
            CardPayload(prompt: "Later prompt three", longAnswer: "Later answer three.")
        ]), origin: .imported)
        for (index, card) in due.sortedCards.enumerated() {
            var state = reviewed
            state.lapses = index == 0 ? 1 : 0
            if index < 2 { state.dueAt = now.addingTimeInterval(-Double(index + 1) * 3_600) }
            card.schedule = state
            card.wrongCount = index == 0 ? 2 : 0
            card.correctCount = 1
        }
        let session = SessionRecord(mode: .quizVoice, startedAt: now.addingTimeInterval(-2 * 86_400), endedAt: now.addingTimeInterval(-2 * 86_400 + 120), scorePercent: 0.5)
        session.quiz = due
        due.sessions.append(session)
        context.insert(due)
        for quiz in (try? context.fetch(FetchDescriptor<QuizRecord>())) ?? [] {
            QuizStats.refresh(quiz, now: now)
        }
        try? context.save()
    }

    /// One card of each kind (Phase 6, F-17).
    static let mixedDeck = QuizPayload(name: "UITest Mixed Deck", tags: ["fixture"], cards: [
        CardPayload(prompt: "Mixed multiple choice", longAnswer: "Blue is right.", shortAnswer: "Blue", kind: .multipleChoice, options: ["Red", "Blue", "Green"]),
        CardPayload(prompt: "The sky is {{blank}} on a clear day.", longAnswer: "Blue.", shortAnswer: "blue", kind: .cloze),
        CardPayload(prompt: "Water boils at 100 °C at sea level.", longAnswer: "True.", shortAnswer: "true", kind: .trueFalse),
        CardPayload(prompt: "Mixed recall prompt", longAnswer: "Mixed recall answer.", shortAnswer: "Recall", kind: .recall)
    ])

    /// Seeds the large library once; later launches reuse the on-disk store.
    @MainActor
    static func seedLargeLibrary(in context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<QuizRecord>())) ?? 0
        guard existing < largeQuizCount else { return }
        let tags = ["history", "science", "language", "tech", "math", "art", "music", "law"]
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for q in existing..<largeQuizCount {
            let cards = (0..<largeCardsPerQuiz).map {
                CardPayload(prompt: "Quiz \(q) prompt \($0)", longAnswer: "Long answer \($0) for quiz \(q).", shortAnswer: "Short \($0)")
            }
            let payload = QuizPayload(name: String(format: "Large quiz %03d", q), tags: [tags[q % tags.count], tags[(q / 8) % tags.count]], cards: cards)
            let quiz = QuizRecord.make(from: payload, origin: .imported)
            quiz.importedAt = base.addingTimeInterval(Double(q) * 3600)
            quiz.createdAt = quiz.importedAt
            for (i, card) in quiz.cards.enumerated() where i % 3 == 0 {
                card.dueAt = base.addingTimeInterval(Double(i - q) * 86_400)
            }
            for s in 0..<largeSessionsPerQuiz {
                let start = base.addingTimeInterval(Double(q * 97 + s * 13) * 600)
                let session = SessionRecord(mode: .quizVoice, startedAt: start, endedAt: start.addingTimeInterval(300),
                                            scorePercent: Double((q + s) % 11) / 10)
                session.quiz = quiz
                quiz.sessions.append(session)
            }
            QuizStats.refresh(quiz)
            context.insert(quiz)
            if q % 20 == 19 { try? context.save() }
        }
        try? context.save()
    }
}
