import Foundation

@Observable
final class SessionDeck {
    let cards: [CardRecord]
    let startedAt: Date
    private(set) var index: Int = 0
    private(set) var outcomes: [UUID: CardVerdict] = [:]
    private(set) var ended: Bool = false
    private(set) var abandoned: Bool = false

    init(cards: [CardRecord], startedAt: Date = .now) {
        self.cards = cards
        self.startedAt = startedAt
    }

    var current: CardRecord? {
        guard index < cards.count else { return nil }
        return cards[index]
    }

    var atStart: Bool { index == 0 }
    var atEnd: Bool { index >= cards.count - 1 }
    var progress: (current: Int, total: Int) { (min(index + 1, cards.count), cards.count) }

    func record(_ verdict: CardVerdict) {
        guard let card = current else { return }
        outcomes[card.id] = verdict
    }

    func next() {
        if index < cards.count - 1 {
            index += 1
        } else {
            ended = true
        }
    }

    func back() {
        if index > 0 { index -= 1 }
    }

    func abandon() {
        abandoned = true
        ended = true
    }

    var scorePercent: Double? {
        let scored = outcomes.values.compactMap { $0.score }
        guard !scored.isEmpty else { return nil }
        return scored.reduce(0, +) / Double(scored.count)
    }

    func toCardOutcomes() -> [CardOutcome] {
        cards.compactMap { card in
            guard let verdict = outcomes[card.id] else { return nil }
            return CardOutcome(cardId: card.id, verdict: verdict)
        }
    }
}
