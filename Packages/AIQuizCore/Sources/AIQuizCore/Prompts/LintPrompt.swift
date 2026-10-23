import Foundation

// Prompt: lint cards (SPEC F-29). Version 1. Batches of up to 40 cards.
// Output contract: LintJSON {issues:[{index, severity, kind, message, suggested_fix?}]}.

public extension PromptBuilder {
    static func lintSystem() -> String {
        """
        You review flashcards for problems a learner would trip over. Report only real problems:
        - ambiguous: the prompt has more than one reasonable answer.
        - duplicate: the card asks the same thing as another card (name the other index in the message).
        - leakyHint: the hint gives the answer away.
        - tooLong: the long answer is far longer than needed to answer the prompt.
        - answerMismatch: the short answer disagrees with the long answer, or the answer is wrong.
        severity is "error" when the card is wrong or unusable, otherwise "warn". message is one \
        sentence for the learner. When a rewrite would fix it, give suggested_fix as the whole \
        corrected card; otherwise null. Return {"issues": []} when the cards are fine.
        Return JSON {"issues": [{"index": 0, "severity": "warn", "kind": "leakyHint", "message": "...", \
        "suggested_fix": {"prompt": "...", "long_answer": "...", "short_answer": null, "hint": null}}]}.
        """
    }

    static func lintUser(cards: [CardPayload]) -> String {
        numberedCards(cards)
    }
}
