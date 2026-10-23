import Foundation
import SwiftData
import AIQuizCore

/// Bridges persistent records and the value-typed session model: builds decks from a
/// quiz and writes a finished deck back as a `SessionRecord` plus per-card history.
@MainActor
enum ScoreStore {
    /// Build a smart-ordered session deck for the quiz.
    static func makeDeck(for quiz: QuizRecord, cardLimit: Int? = nil) -> SessionDeck {
        let ordered = SmartOrdering.order(quiz.cards, now: .now) { $0.history }
        let limited = cardLimit.map { Array(ordered.prefix($0)) } ?? ordered
        return SessionDeck(cards: limited.map(CardSnapshot.init))
    }

    /// Build a deck that contains only the given cards, in input order
    /// (used by "Practice missed cards").
    static func makeDeck(cards: [CardSnapshot]) -> SessionDeck {
        SessionDeck(cards: cards)
    }

    /// Persist the session result and update per-card history.
    /// Skipped cards do not affect history. Abandoned sessions are not persisted.
    /// Quiz-mode sessions with no graded cards are not persisted either.
    static func recordSession(
        for quiz: QuizRecord,
        deck: SessionDeck,
        mode: SessionMode,
        in context: ModelContext
    ) {
        guard !deck.abandoned else { return }
        guard !deck.outcomes.isEmpty || mode != .quizVoice else { return }

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
    }
}
