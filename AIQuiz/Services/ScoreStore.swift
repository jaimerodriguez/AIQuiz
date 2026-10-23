import Foundation
import SwiftData
import AIQuizCore

/// Bridges persistent records and the value-typed session model: builds decks from a
/// quiz and writes a finished deck back as a `SessionRecord` plus per-card history.
@MainActor
enum ScoreStore {
    /// The scheduler's order for these cards (SPEC §10): due, then new, then the rest.
    static func ordered(_ cards: [CardRecord], now: Date = .now) -> [CardRecord] {
        var generator = SystemRandomNumberGenerator()
        return Scheduler.order(cards, now: now, dueAt: \.dueAt, isNew: \.isNewCard, using: &generator)
    }

    /// A study session: the whole deck in scheduler order (§10).
    static func makeDeck(for quiz: QuizRecord, cardLimit: Int? = nil) -> SessionDeck {
        let ordered = ordered(quiz.cards)
        let limited = cardLimit.map { Array(ordered.prefix($0)) } ?? ordered
        return SessionDeck(cards: limited.map(CardSnapshot.init))
    }

    /// A quiz session (§10, S-11): due and new cards up to `cap`, or the whole deck when
    /// nothing is due; `includeNotDue` adds the rest.
    static func makeQuizDeck(for quiz: QuizRecord, cap: Int, includeNotDue: Bool, now: Date = .now) -> SessionDeck {
        let session = Scheduler.quizSession(ordered(quiz.cards, now: now), now: now, dueAt: \.dueAt, isNew: \.isNewCard, cap: cap, includeNotDue: includeNotDue)
        return SessionDeck(cards: session.map(CardSnapshot.init))
    }

    /// The Due today review (F-2, F-41): due and new cards across non-archived quizzes, in
    /// scheduler order, capped by S-11.
    static func makeReviewDeck(in context: ModelContext, cap: Int, now: Date = .now) -> SessionDeck {
        let never = Date.distantPast
        let due = (try? context.fetch(FetchDescriptor<CardRecord>(predicate: #Predicate { card in
            (card.dueAt ?? never) <= now && card.quiz?.isArchived == false
        }))) ?? []
        return SessionDeck(cards: Array(ordered(due, now: now).prefix(max(1, cap))).map(CardSnapshot.init))
    }

    /// Cards due across the library, for the Due today row and the reminder (one fetchCount, F-2).
    static func dueCount(in context: ModelContext, at date: Date = .now) -> Int {
        let never = Date.distantPast
        return (try? context.fetchCount(FetchDescriptor<CardRecord>(predicate: #Predicate { card in
            (card.dueAt ?? never) <= date && card.quiz?.isArchived == false
        }))) ?? 0
    }

    /// Build a deck that contains only the given cards, in input order
    /// (used by "Practice missed cards").
    static func makeDeck(cards: [CardSnapshot]) -> SessionDeck {
        SessionDeck(cards: cards)
    }

    /// Persist the session result and update per-card history. Records a deck at most once.
    /// Skipped cards do not affect history. Abandoned sessions are not persisted.
    /// Quiz-mode sessions with no graded cards are not persisted either.
    @discardableResult
    static func recordSession(
        for quiz: QuizRecord,
        deck: SessionDeck,
        mode: SessionMode,
        in context: ModelContext
    ) -> SessionRecord? {
        guard !deck.abandoned, !deck.recorded else { return nil }
        deck.markRecorded()
        guard !deck.outcomes.isEmpty || mode != .quizVoice else { return nil }

        let byId = Dictionary(uniqueKeysWithValues: quiz.cards.map { ($0.id, $0) })
        for (cardId, verdict) in deck.outcomes {
            guard let card = byId[cardId] else { continue }
            switch verdict {
            case .correct: card.correctCount += 1
            case .partial: card.partialCount += 1
            case .wrong:   card.wrongCount += 1
            case .skipped: continue
            }
            card.lastSeenAt = .now
            if let rating = FSRS.Rating(verdict, easy: deck.easyCards.contains(cardId)) {
                card.schedule = FSRS.review(card.schedule, rating: rating, now: .now)
            }
        }

        let session = SessionRecord(
            mode: mode,
            startedAt: deck.startedAt,
            endedAt: .now,
            scorePercent: deck.scorePercent,
            abandoned: false,
            outcomes: deck.toCardOutcomes()
        )
        session.quiz = quiz
        quiz.sessions.append(session)
        QuizStats.refresh(quiz)

        do {
            try context.save()
        } catch {
            Log.data.error("recordSession save failed: \(String(describing: error))")
        }
        return session
    }

    /// The Due today review (F-41): one session per quiz, with that quiz's cards.
    static func recordReview(_ deck: SessionDeck, in context: ModelContext) {
        guard !deck.abandoned, !deck.recorded else { return }
        let ids = Set(deck.outcomes.keys)
        let cards = ((try? context.fetch(FetchDescriptor<CardRecord>())) ?? []).filter { ids.contains($0.id) }
        let byQuiz = Dictionary(grouping: cards) { $0.quiz?.id }
        for (_, quizCards) in byQuiz {
            guard let quiz = quizCards.first?.quiz else { continue }
            let quizIds = Set(quizCards.map(\.id))
            let part = SessionDeck(cards: deck.cards.filter { quizIds.contains($0.id) }, startedAt: deck.startedAt)
            for card in part.cards {
                if let verdict = deck.outcomes[card.id] {
                    part.recordAll(verdict, for: card.id, ai: deck.aiGrades[card.id], easy: deck.easyCards.contains(card.id))
                }
            }
            recordSession(for: quiz, deck: part, mode: .review, in: context)
        }
        deck.markRecorded()
    }
}
