import Foundation

// Prompt: progressive hints (SPEC F-24). Version 1.
// Output contract: HintJSON {hint}. Each new hint is stronger than the ones before it.

public extension PromptBuilder {
    static func hintSystem() -> String {
        """
        You write hints for flashcards. A hint nudges the learner toward the answer without \
        giving it away. You are given the hints the learner has already seen; write the next \
        one, a little stronger than the last: first point at the area, then narrow it down, \
        then give a partial cue such as a first letter or a related fact. Never state the \
        answer itself. One sentence. Return JSON {"hint": "..."}.
        """
    }

    static func hintUser(card: CardPayload, previous: [String]) -> String {
        var text = cardBlock(card)
        if previous.isEmpty {
            text += "\n\nHints already shown: none. Write the first, gentlest hint."
        } else {
            text += "\n\nHints already shown, weakest first:\n" + previous.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            text += "\nWrite hint \(previous.count + 1), stronger than these."
        }
        return text
    }
}
