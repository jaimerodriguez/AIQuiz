import Foundation
import SwiftData

@MainActor
enum ScoreStore {
    /// Build a smart-weighted, shuffled session deck for the quiz.
    static func makeDeck(for quiz: QuizRecord, cardLimit: Int? = nil) -> SessionDeck {
        let ordered = smartWeightedOrder(quiz.cards)
        let limited = cardLimit.map { Array(ordered.prefix($0)) } ?? ordered
        return SessionDeck(cards: limited)
    }

    /// Build a deck that contains only the given cards, in input order.
    static func makeDeck(cards: [CardRecord]) -> SessionDeck {
        SessionDeck(cards: cards)
    }

    /// Persist the session result and update per-card history.
    /// Skipped cards do not affect history. Abandoned sessions are not persisted.
    static func recordSession(
        for quiz: QuizRecord,
        deck: SessionDeck,
        mode: SessionMode,
        in context: ModelContext
    ) {
        guard !deck.abandoned else { return }
        guard !deck.outcomes.isEmpty || mode != .quizVoice else {
            // Quiz mode with no graded outcomes — nothing meaningful to save.
            return
        }

        for (cardId, verdict) in deck.outcomes {
            guard let card = quiz.cards.first(where: { $0.id == cardId }) else { continue }
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

        try? context.save()
    }

    // MARK: - Weighting

    private static func smartWeightedOrder(_ cards: [CardRecord]) -> [CardRecord] {
        guard !cards.isEmpty else { return [] }
        let now = Date()
        var pool = cards
        var result: [CardRecord] = []
        result.reserveCapacity(pool.count)

        while !pool.isEmpty {
            let weights = pool.map { weight(for: $0, now: now) }
            let total = weights.reduce(0, +)
            guard total > 0 else {
                result.append(contentsOf: pool)
                break
            }
            let r = Double.random(in: 0..<total)
            var acc = 0.0
            var picked = pool.count - 1
            for (i, w) in weights.enumerated() {
                acc += w
                if r < acc { picked = i; break }
            }
            result.append(pool.remove(at: picked))
        }
        return result
    }

    static func weight(for card: CardRecord, now: Date) -> Double {
        let total = card.correctCount + card.partialCount + card.wrongCount
        let wrongish = Double(card.wrongCount) + 0.5 * Double(card.partialCount)
        let base = total == 0 ? 0.5 : (wrongish + 1.0) / (Double(total) + 2.0)
        let stale = card.lastSeenAt.map { now.timeIntervalSince($0) > 86_400 } ?? true
        return base * (stale ? 1.25 : 1.0)
    }
}
