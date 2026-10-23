import Foundation
import Observation

/// Study read display style (SPEC S-10).
public enum StudyReadStyle: String, CaseIterable, Identifiable, Sendable {
    case flipCard
    case allAtOnce

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .flipCard: return "Flip card"
        case .allAtOnce: return "All at once"
        }
    }
}

/// Study — User-paced read (SPEC F-13).
@Observable
@MainActor
public final class StudyReadPlayer {
    public let deck: SessionDeck
    public var style: StudyReadStyle {
        didSet { if style != oldValue { revealed = false } }
    }
    public private(set) var revealed = false
    public private(set) var hints = HintProgress(hints: [])
    public var hintRevealed: Bool { hints.level > 0 }
    /// Set when the user goes past the last card.
    public private(set) var finished = false

    public init(deck: SessionDeck, style: StudyReadStyle) {
        self.deck = deck
        self.style = style
        hints = HintProgress(hints: deck.current?.hints ?? [])
    }

    /// Whether the answer shows on the current card.
    public var showsAnswer: Bool { style == .allAtOnce || revealed }

    public func reveal() { revealed = true }

    /// Reveals the next hint (F-24); after the last, hides them.
    public func toggleHint() {
        hints.advance()
    }

    /// Next card, or finish on the last one.
    public func next() {
        if deck.atEnd {
            finished = true
        } else {
            deck.next()
            resetCard()
        }
    }

    public func back() {
        guard !deck.atStart else { return }
        deck.back()
        resetCard()
    }

    public func abandon() {
        deck.abandon()
    }

    private func resetCard() {
        revealed = false
        hints = HintProgress(hints: deck.current?.hints ?? [])
    }
}
