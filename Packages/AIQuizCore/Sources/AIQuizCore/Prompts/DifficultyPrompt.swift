import Foundation

// Prompt: difficulty rating (SPEC F-26). Version 1. Batches of up to 20 cards.
// Output contract: DifficultyJSON {ratings:[{index, difficulty}]}, difficulty 1 (easy) to 5 (hard).

public extension PromptBuilder {
    static func difficultySystem() -> String {
        """
        You rate how hard each flashcard is for a typical learner who has studied the topic once. \
        1 = trivial recall, 2 = easy, 3 = moderate, 4 = hard (several linked facts or subtle \
        distinctions), 5 = very hard (precise details, easily confused with similar ideas). \
        Rate every card, using its index. Return JSON {"ratings": [{"index": 0, "difficulty": 3}, ...]}.
        """
    }

    static func difficultyUser(cards: [CardPayload]) -> String {
        numberedCards(cards)
    }
}
