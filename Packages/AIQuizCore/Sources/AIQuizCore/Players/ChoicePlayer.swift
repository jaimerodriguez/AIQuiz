import Foundation
import Observation

/// Quiz — Choice (SPEC F-17): multiple choice, fill in the blank and true or false, checked
/// automatically; recall cards in the deck are flip cards with self-grade. A right answer is
/// Correct and a wrong one Wrong; the user can override any verdict, including to Partial.
@Observable
@MainActor
public final class ChoicePlayer {
    public enum Stage: Sendable, Equatable {
        /// Waiting for an answer (or, for recall, for the flip).
        case asking
        /// Answered: the verdict is shown with the right answer.
        case checked
        case ended
    }

    public let deck: SessionDeck
    public private(set) var stage: Stage = .asking
    /// Multiple-choice options in the order shown (shuffled once per card).
    public private(set) var shownOptions: [String] = []
    public private(set) var chosen: String?
    /// One entry per blank for fill-in-the-blank cards.
    public var blankAnswers: [String] = []
    /// The checked verdict; `override` changes it.
    public private(set) var verdict: CardVerdict?
    public private(set) var overridden = false
    public private(set) var hints = HintProgress(hints: [])

    private var generator: any RandomNumberGenerator

    public init(deck: SessionDeck, generator: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.deck = deck
        self.generator = generator
        prepareCard()
    }

    public var card: CardSnapshot? { deck.current }

    /// The right option text for multiple choice and true/false.
    public var rightAnswer: String? {
        guard let card else { return nil }
        switch card.kind {
        case .multipleChoice: return card.options.first { Self.same($0, card.shortAnswer ?? "") } ?? card.shortAnswer
        case .trueFalse: return Self.trueFalseValue(card.shortAnswer).map { $0 ? "True" : "False" }
        case .cloze: return Cloze.expected(card.shortAnswer, blanks: Cloze.blankCount(card.prompt)).joined(separator: " · ")
        case .recall: return card.shortAnswer
        }
    }

    // MARK: Answering

    /// Multiple choice or true/false: one tap checks.
    public func choose(_ option: String) {
        guard stage == .asking, let card, card.kind == .multipleChoice || card.kind == .trueFalse else { return }
        chosen = option
        let right: Bool
        if card.kind == .trueFalse {
            right = Self.trueFalseValue(option) == Self.trueFalseValue(card.shortAnswer)
        } else {
            right = Self.same(option, card.shortAnswer ?? "")
        }
        check(right ? .correct : .wrong)
    }

    /// Fill in the blank: compares every blank, ignoring case and spacing.
    public func checkBlanks() {
        guard stage == .asking, let card, card.kind == .cloze else { return }
        let expected = Cloze.expected(card.shortAnswer, blanks: Cloze.blankCount(card.prompt))
        check(Cloze.matches(blankAnswers, expected: expected) ? .correct : .wrong)
    }

    /// Recall: flip, then self-grade with `override`.
    public func reveal() {
        guard stage == .asking, card?.kind == .recall else { return }
        stage = .checked
    }

    /// The user's own verdict: for recall cards the grade, for the others an override (F-17).
    public func override(_ verdict: CardVerdict) {
        guard stage == .checked else { return }
        if card?.kind != .recall { overridden = verdict != self.verdict }
        self.verdict = verdict
    }

    /// Records the verdict and moves on. A recall card needs a grade first.
    public func next() {
        guard stage == .checked, let verdict else { return }
        deck.record(verdict)
        deck.next()
        if deck.ended {
            stage = .ended
        } else {
            prepareCard()
        }
    }

    public func toggleHint() {
        hints.advance()
    }

    public func abandon() {
        deck.abandon()
        stage = .ended
    }

    private func check(_ verdict: CardVerdict) {
        self.verdict = verdict
        overridden = false
        stage = .checked
    }

    private func prepareCard() {
        stage = deck.ended ? .ended : .asking
        chosen = nil
        verdict = nil
        overridden = false
        guard let card else { return }
        hints = HintProgress(hints: card.hints)
        switch card.kind {
        case .multipleChoice: shownOptions = card.options.shuffled(using: &generator)
        case .trueFalse: shownOptions = ["True", "False"]
        case .cloze, .recall: shownOptions = []
        }
        blankAnswers = Array(repeating: "", count: card.kind == .cloze ? max(1, Cloze.blankCount(card.prompt)) : 0)
    }

    /// Whether two option texts are the same answer (case and spacing ignored).
    public static func isSame(_ a: String, _ b: String) -> Bool { same(a, b) }

    static func same(_ a: String, _ b: String) -> Bool {
        Cloze.normalised(a) == Cloze.normalised(b)
    }

    static func trueFalseValue(_ text: String?) -> Bool? {
        switch (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "verdadero", "vrai", "wahr": return true
        case "false", "no", "falso", "faux", "falsch": return false
        default: return nil
        }
    }
}
