import Foundation

// Prompt: insights report (SPEC F-43). Version 1.
// Output contract: InsightsJSON {headline, strengths, confusions[{description, card_ids}],
// recommendations, drill_cards}.

public extension PromptBuilder {
    static func insightsSystem() -> String {
        """
        You coach a learner from their flashcard history. You get, per quiz, recent session \
        scores and the cards they get wrong most (with short ids in brackets). Write: a one-line \
        headline; 2-4 strengths; 1-4 confusions, each a short description of an idea they mix up \
        or keep missing with the ids of the cards involved; 2-4 concrete recommendations; and \
        3-8 new drill cards that target the confusions (prompt, long answer, optional short \
        answer and hint, kind "recall"). Be specific and kind. Return JSON only.
        """
    }

    static func insightsUser(digest: String) -> String {
        "Study history:\n\n" + digest
    }
}
