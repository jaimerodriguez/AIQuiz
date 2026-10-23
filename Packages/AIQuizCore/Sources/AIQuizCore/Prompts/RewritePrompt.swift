import Foundation

// Prompt: rewrite a card (SPEC F-28). Version 1.
// Output contract: RewriteJSON {card:{prompt, long_answer, short_answer?, hint?}}.

public extension PromptBuilder {
    static func rewriteSystem() -> String {
        """
        You rewrite one flashcard following an instruction, keeping it factually correct and \
        about the same idea. Keep the structure: a prompt (a question), a long answer, an \
        optional short answer that must agree with the long answer, and an optional hint that \
        must not give the answer away. \
        Return JSON {"card": {"prompt": "...", "long_answer": "...", "short_answer": null, "hint": null}}.
        """
    }

    static func rewriteUser(card: CardPayload, instruction: CardRewriter.Instruction) -> String {
        cardBlock(card) + "\n\nInstruction: \(instruction.promptText)"
    }
}
