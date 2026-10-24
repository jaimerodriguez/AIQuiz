import Foundation
import Observation

/// Ordered set of cards for one session plus the verdicts recorded so far.
/// Pure state machine; no persistence, no UI.
@MainActor
@Observable
public final class SessionDeck {
    public let cards: [CardSnapshot]
    public let startedAt: Date
    public private(set) var index: Int = 0
    public private(set) var outcomes: [UUID: CardVerdict] = [:]
    public private(set) var ended: Bool = false
    public private(set) var abandoned: Bool = false
    /// AI grades and "why wrong" explanations, by card (F-15, F-16).
    public private(set) var aiGrades: [UUID: AIGrade] = [:]
    public private(set) var explanations: [UUID: String] = [:]
    /// Cards graded Easy (long-press Correct in review sessions, §10).
    public private(set) var easyCards: Set<UUID> = []
    /// Set once the session has been saved, so no screen records it twice.
    public private(set) var recorded: Bool = false

    public init(cards: [CardSnapshot], startedAt: Date = .now) {
        self.cards = cards
        self.startedAt = startedAt
    }

    public var current: CardSnapshot? {
        guard index < cards.count else { return nil }
        return cards[index]
    }

    public var atStart: Bool { index == 0 }
    public var atEnd: Bool { index >= cards.count - 1 }
    public var isEmpty: Bool { cards.isEmpty }
    /// Whether any card has a hint (its own or a stored AI hint). Sessions show no Hint button
    /// for a deck without any, such as most Anki imports.
    public var hasHints: Bool { cards.contains { !$0.hints.isEmpty } }
    public var progress: (current: Int, total: Int) { (min(index + 1, cards.count), cards.count) }

    /// Record a verdict for the current card, with the AI's grade when there was one.
    /// Overwrites any earlier verdict for it.
    public func record(_ verdict: CardVerdict, ai: AIGrade? = nil) {
        guard let card = current else { return }
        outcomes[card.id] = verdict
        if let ai { aiGrades[card.id] = ai } else { aiGrades[card.id] = nil }
    }

    /// Records a verdict for a card by id (used to split a review across quizzes).
    public func recordAll(_ verdict: CardVerdict, for cardId: UUID, ai: AIGrade? = nil, easy: Bool = false) {
        guard cards.contains(where: { $0.id == cardId }) else { return }
        outcomes[cardId] = verdict
        aiGrades[cardId] = ai
        if easy { easyCards.insert(cardId) }
    }

    public func markEasy(_ cardId: UUID) {
        easyCards.insert(cardId)
    }

    public func setExplanation(_ text: String, for cardId: UUID) {
        explanations[cardId] = text
    }

    /// Advance. On the last card the deck ends instead.
    public func next() {
        if index < cards.count - 1 {
            index += 1
        } else {
            ended = true
        }
    }

    public func back() {
        if index > 0 { index -= 1 }
    }

    public func markRecorded() {
        recorded = true
    }

    /// End early and discard the result (SPEC §5: abandon).
    public func abandon() {
        abandoned = true
        ended = true
    }

    /// Mean of scored verdicts, or nil when nothing was scored.
    public var scorePercent: Double? {
        let scored = outcomes.values.compactMap(\.score)
        guard !scored.isEmpty else { return nil }
        return scored.reduce(0, +) / Double(scored.count)
    }

    /// Outcomes in deck order, only for cards that received a verdict.
    public func toCardOutcomes() -> [CardOutcome] {
        cards.compactMap { card in
            guard let verdict = outcomes[card.id] else { return nil }
            let ai = aiGrades[card.id]
            return CardOutcome(
                cardId: card.id,
                verdict: verdict,
                aiVerdict: ai?.verdict,
                aiReason: ai?.reason,
                userOverrode: ai.map { $0.verdict != verdict } ?? false,
                explanation: explanations[card.id]
            )
        }
    }

    /// Cards with a verdict, paired with it, in deck order.
    public var scoredCards: [(card: CardSnapshot, verdict: CardVerdict)] {
        cards.compactMap { card in
            guard let v = outcomes[card.id] else { return nil }
            return (card, v)
        }
    }

    /// Cards graded wrong or partial, in deck order. Input for "Practice missed cards".
    public var missedCards: [CardSnapshot] {
        scoredCards.compactMap { $0.verdict == .wrong || $0.verdict == .partial ? $0.card : nil }
    }

    public var counts: (correct: Int, partial: Int, wrong: Int, skipped: Int) {
        var c = 0, p = 0, w = 0, s = 0
        for (_, v) in scoredCards {
            switch v {
            case .correct: c += 1
            case .partial: p += 1
            case .wrong: w += 1
            case .skipped: s += 1
            }
        }
        return (c, p, w, s)
    }
}
