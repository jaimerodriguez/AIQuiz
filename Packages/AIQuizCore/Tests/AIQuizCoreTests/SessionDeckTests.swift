import Foundation
import Testing
@testable import AIQuizCore

@Suite("SessionDeck")
@MainActor
struct SessionDeckTests {
    private func cards(_ n: Int) -> [CardSnapshot] {
        (0..<n).map { CardSnapshot(id: UUID(), prompt: "p\($0)", longAnswer: "l\($0)") }
    }

    @Test("starts at first card")
    func start() {
        let deck = SessionDeck(cards: cards(3))
        #expect(deck.atStart)
        #expect(!deck.atEnd)
        #expect(deck.current?.prompt == "p0")
        #expect(deck.progress == (1, 3))
    }

    @Test("next advances and ends after the last card")
    func nextAndEnd() {
        let deck = SessionDeck(cards: cards(2))
        deck.next()
        #expect(deck.atEnd)
        #expect(!deck.ended)
        deck.next()
        #expect(deck.ended)
        #expect(!deck.abandoned)
    }

    @Test("back does not go below zero")
    func back() {
        let deck = SessionDeck(cards: cards(2))
        deck.back()
        #expect(deck.index == 0)
        deck.next()
        deck.back()
        #expect(deck.index == 0)
    }

    @Test("record stores verdict for current card and overwrites")
    func record() {
        let deck = SessionDeck(cards: cards(2))
        deck.record(.wrong)
        deck.record(.correct)
        #expect(deck.outcomes[deck.cards[0].id] == .correct)
        #expect(deck.outcomes.count == 1)
    }

    @Test("score excludes skipped and averages the rest")
    func score() {
        let deck = SessionDeck(cards: cards(4))
        deck.record(.correct); deck.next()
        deck.record(.partial); deck.next()
        deck.record(.skipped); deck.next()
        deck.record(.wrong)
        #expect(deck.scorePercent == 0.5)
        let c = deck.counts
        #expect(c == (1, 1, 1, 1))
    }

    @Test("score is nil with no scored outcomes")
    func scoreNil() {
        let deck = SessionDeck(cards: cards(2))
        #expect(deck.scorePercent == nil)
        deck.record(.skipped)
        #expect(deck.scorePercent == nil)
    }

    @Test("abandon ends and flags")
    func abandon() {
        let deck = SessionDeck(cards: cards(2))
        deck.abandon()
        #expect(deck.ended)
        #expect(deck.abandoned)
    }

    @Test("outcomes and missed cards are in deck order")
    func order() {
        let deck = SessionDeck(cards: cards(3))
        deck.next(); deck.record(.wrong)
        deck.back(); deck.record(.partial)
        deck.next(); deck.next(); deck.record(.correct)
        let outcomes = deck.toCardOutcomes()
        #expect(outcomes.map(\.verdict) == [.partial, .wrong, .correct])
        #expect(deck.missedCards.map(\.prompt) == ["p0", "p1"])
    }

    @Test("empty deck")
    func empty() {
        let deck = SessionDeck(cards: [])
        #expect(deck.isEmpty)
        #expect(deck.current == nil)
        #expect(deck.progress == (0, 0))
    }
}
