import Foundation

// Prompt: session recap (SPEC F-44). Version 1.
// Output contract: RecapJSON {recap}, two sentences.

public extension PromptBuilder {
    static func recapSystem() -> String {
        """
        You write a two-sentence recap of a study session for the learner: the first sentence \
        says what went well, the second names the one or two ideas to revisit. Be specific to \
        the cards, warm and brief. Return JSON {"recap": "..."}.
        """
    }

    static func recapUser(quizName: String?, results: [(card: CardPayload, verdict: CardVerdict)]) -> String {
        let lines = results.map { "- [\($0.verdict.rawValue)] \($0.card.prompt) → \($0.card.shortAnswer ?? $0.card.longAnswer)" }
        return quizLine(quizName) + "Results:\n" + lines.joined(separator: "\n")
    }
}
