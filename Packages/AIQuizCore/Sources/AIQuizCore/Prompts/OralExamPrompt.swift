import Foundation

// Prompts: oral exam (SPEC F-45, §9.2). Version 1.
// Output contracts: OralTurnJSON {action: accept|follow_up, say} after the learner's first
// answer to a card; OralGradeJSON {cards:[{card_id, verdict, reason}], overall} at the end.

public extension PromptBuilder {
    static func oralTurnSystem() -> String {
        """
        You are a friendly oral examiner. You asked the learner a question drawn from a \
        flashcard and they answered aloud (the answer is a speech transcript, so ignore \
        filler words and small transcription slips). Decide what to do next:
        - "accept" when the answer captures the key idea, or when it is so far off that a \
        follow-up would not help. Then "say" is a short neutral acknowledgement of at most six \
        words, such as "Thank you." or "Okay, next one.", and never reveals the answer.
        - "follow_up" when the answer is partly right or vague. Then "say" is one short \
        follow-up question aimed at the gap, without giving the answer away.
        Return JSON {"action": "accept" or "follow_up", "say": "..."}.
        """
    }

    static func oralTurnUser(card: CardPayload, exchanges: [OralExchange]) -> String {
        cardBlock(card, label: "Card (the examiner sees this; the learner does not)") + "\n\n" + exchangeLines(exchanges)
    }

    static func oralGradeSystem() -> String {
        """
        You grade an oral exam. For each card you get the reference answer and the exchange \
        with the learner (speech transcripts; ignore filler words and small transcription \
        slips). Grade the learner's understanding across the whole exchange: "correct" when \
        they captured the key idea, "partial" when part of it is missing or wrong, "wrong" \
        when it is off, contradicts the answer or is empty. Give one short reason per card, \
        addressed to the learner. Then write "overall": two sentences, what went well and \
        what to revisit. Grade every card, using its card_id.
        Return JSON {"cards": [{"card_id": "c1", "verdict": "correct|partial|wrong", "reason": "..."}], "overall": "..."}.
        """
    }

    static func oralGradeUser(_ items: [(id: String, card: CardPayload, exchanges: [OralExchange])]) -> String {
        items.map { cardBlock($0.card, label: "Card \($0.id)") + "\n" + exchangeLines($0.exchanges) }
            .joined(separator: "\n\n")
    }

    private static func exchangeLines(_ exchanges: [OralExchange]) -> String {
        exchanges.map { exchange in
            let answer = exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Examiner: \(exchange.question)\nLearner: \(answer.isEmpty ? "(no answer)" : answer)"
        }
        .joined(separator: "\n")
    }
}
