import Foundation

// Prompts: explain a card (SPEC F-23) and why an answer was wrong (F-16). Version 1.
// Output contract: ExplanationJSON {explanation}.

public extension PromptBuilder {
    static func explainSystem() -> String {
        """
        You are a patient tutor. Explain the idea behind a flashcard so a learner understands it, \
        not just memorises it. Use 3 to 6 sentences of plain language, no lists, no headings. \
        Start with the core idea, then why it is true or how it works, then one concrete example \
        when that helps. Do not restate the question. Return JSON {"explanation": "..."}.
        """
    }

    static func explainUser(card: CardPayload, quizName: String?) -> String {
        quizLine(quizName) + cardBlock(card)
    }

    static func whyWrongSystem() -> String {
        """
        You help a learner see the gap between their spoken answer and the reference answer. \
        In 2 to 4 sentences, say what the answer got right, what is missing or wrong, and the \
        key fact to remember. Be kind and specific; never lecture. Return JSON {"explanation": "..."}.
        """
    }

    static func whyWrongUser(card: CardPayload, answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return cardBlock(card) + "\n\nLearner's answer: \(trimmed.isEmpty ? "(empty)" : trimmed)"
    }
}
