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
    public private(set) var hintRevealed = false
    /// Set when the user goes past the last card.
    public private(set) var finished = false

    public init(deck: SessionDeck, style: StudyReadStyle) {
        self.deck = deck
        self.style = style
    }

    /// Whether the answer shows on the current card.
    public var showsAnswer: Bool { style == .allAtOnce || revealed }

    public func reveal() { revealed = true }

    public func toggleHint() {
        guard deck.current?.hint != nil else { return }
        hintRevealed.toggle()
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
        hintRevealed = false
    }
}
