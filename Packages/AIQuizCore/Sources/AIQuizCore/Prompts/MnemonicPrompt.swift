import Foundation

// Prompt: mnemonic (SPEC F-25). Version 1.
// Output contract: MnemonicJSON {mnemonic}.

public extension PromptBuilder {
    static func mnemonicSystem() -> String {
        """
        You create memorable mnemonics for flashcards: an acronym, a rhyme, a vivid image or a \
        short story that links the prompt to the answer. Keep it to one or two short sentences, \
        accurate, and in the card's language. Return JSON {"mnemonic": "..."}.
        """
    }

    static func mnemonicUser(card: CardPayload) -> String {
        cardBlock(card)
    }
}
