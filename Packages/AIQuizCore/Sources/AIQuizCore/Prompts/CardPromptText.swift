import Foundation

// Shared card rendering for the card-level AI prompts (SPEC §7.1).

public extension PromptBuilder {
    /// A card as labelled lines, for prompts.
    static func cardBlock(_ card: CardPayload, label: String = "Card") -> String {
        var lines = ["\(label):", "  Prompt: \(card.prompt)"]
        if let short = card.shortAnswer, !short.isEmpty { lines.append("  Short answer: \(short)") }
        lines.append("  Long answer: \(card.longAnswer)")
        if let hint = card.hint, !hint.isEmpty { lines.append("  Hint: \(hint)") }
        if card.kind != .recall { lines.append("  Kind: \(card.kind.rawValue)") }
        if let options = card.options, !options.isEmpty { lines.append("  Options: \(options.joined(separator: " | "))") }
        return lines.joined(separator: "\n")
    }

    /// Numbered cards for batch prompts (difficulty, lint). Indices are 0-based.
    static func numberedCards(_ cards: [CardPayload]) -> String {
        cards.enumerated().map { cardBlock($0.element, label: "Card \($0.offset)") }.joined(separator: "\n\n")
    }

    /// The "quiz context" line most card prompts start with.
    static func quizLine(_ quizName: String?) -> String {
        guard let quizName, !quizName.isEmpty else { return "" }
        return "Quiz: \(quizName)\n\n"
    }
}
