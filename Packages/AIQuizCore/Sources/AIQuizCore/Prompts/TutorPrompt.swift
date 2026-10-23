import Foundation

// Prompts: tutor chat (SPEC F-30, §9.1) and "Make cards from this chat". Version 1.
// Output contracts: the chat is free text, streamed; making cards uses F-27's ExpandJSON
// {cards:[{prompt, long_answer, short_answer?, hint?}]}, 3 to 5 cards.

public extension PromptBuilder {
    static func tutorSystem(_ context: TutorContext) -> String {
        var text = """
        You are a patient tutor helping a learner study a flashcard deck. Explain clearly and \
        briefly, check understanding with a question when it helps, and use examples and \
        analogies. Keep answers under 200 words unless asked for more. Reply in the language \
        the learner writes in. Use plain text with short paragraphs or lists; no tables.

        Quiz: \(context.quizName)
        """
        if let description = context.description, !description.isEmpty {
            text += "\nAbout the quiz: \(description)"
        }
        if let notes = context.studyNotes, !notes.isEmpty {
            text += "\n\nStudy notes for the quiz:\n\(notes)"
        }
        if let card = context.card {
            text += "\n\nThe learner opened this chat from a card they are studying:\n" + cardBlock(card, label: "Current card")
        }
        return text
    }

    static func chatCardsSystem() -> String {
        """
        You turn a tutoring conversation into flashcards. Write 3 to 5 new flashcards that \
        capture what the learner asked about or struggled with in the conversation. Do not \
        repeat any card already in the deck. Match the language of the conversation. \
        Each card has a prompt (a question), a long answer (2 to 4 sentences), an optional short \
        answer (a few words) and an optional hint. \
        Return JSON {"cards": [{"prompt": "...", "long_answer": "...", "short_answer": null, "hint": null}]}.
        """
    }

    static func chatCardsUser(transcript: String, quizName: String, existingPrompts: [String]) -> String {
        var text = quizLine(quizName) + "Conversation:\n" + transcript
        if !existingPrompts.isEmpty {
            text += "\n\nPrompts already in the deck (do not repeat):\n" + existingPrompts.prefix(80).map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }
}
