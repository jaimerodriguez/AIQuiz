import Foundation

// Prompt: expand a card (SPEC F-27). Version 1.
// Output contract: ExpandJSON {cards:[{prompt, long_answer, short_answer?, hint?}]}, 3 to 5 cards.

public extension PromptBuilder {
    static func expandSystem() -> String {
        """
        You extend a flashcard deck around one card. Write 3 to 5 new flashcards: some cover the \
        prerequisites a learner needs to understand the card, others go one step deeper. Do not \
        repeat the original card or any existing card. Match the language and tone of the deck. \
        Each card has a prompt (a question), a long answer (2 to 4 sentences), an optional short \
        answer (a few words) and an optional hint. \
        Return JSON {"cards": [{"prompt": "...", "long_answer": "...", "short_answer": null, "hint": null}]}.
        """
    }

    static func expandUser(card: CardPayload, quizName: String?, existingPrompts: [String]) -> String {
        var text = quizLine(quizName) + cardBlock(card, label: "Card to expand")
        if !existingPrompts.isEmpty {
            text += "\n\nPrompts already in the deck (do not repeat):\n" + existingPrompts.prefix(80).map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }
}
