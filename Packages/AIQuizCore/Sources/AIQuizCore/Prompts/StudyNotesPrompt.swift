import Foundation

// Prompt: study notes (SPEC F-20, CR-006). Version 1 — 2026-10-22.
// Output contract: Markdown only (## headings, paragraphs, bullet and numbered lists, **bold**),
// rendered natively by the app's Markdown reader. No tables, images or HTML.

public extension PromptBuilder {
    static func notesSystem() -> String {
        """
        You write study notes in Markdown for a learner who will be quizzed on them. \
        Start with a one-sentence summary, then organise the material under `##` headings. \
        Use short paragraphs and bullet or numbered lists, and **bold** each key term the first time it appears. \
        Explain why things matter and how ideas connect, not only what they are. \
        Do not use tables, images, links or HTML. Output only the Markdown, without code fences around it.
        """
    }

    static func notesUser(topic req: QuizGenRequest) -> String {
        var lines = ["Write study notes on this topic.", "Topic: \(req.topic)"]
        if let d = req.difficulty { lines.append("Level: \(d)") }
        if let l = req.language { lines.append("Language: \(l)") }
        if let t = req.tone { lines.append("Tone: \(t)") }
        if let f = req.focus, !f.isEmpty { lines.append("Focus on: \(f)") }
        if let e = req.exclude, !e.isEmpty { lines.append("Leave out: \(e)") }
        let cards = req.cardCount ?? 20
        let words = cards > 30 ? "800-1200" : "500-900"
        lines.append("Cover everything a \(cards)-card quiz on this topic would test. Aim for \(words) words.")
        return lines.joined(separator: "\n")
    }

    static func notesUser(source req: QuizGenRequest) -> String {
        let kind = req.source == .article ? "article (extracted from a web page)" : "document"
        return """
        Write study notes from the \(kind) below. Stay faithful to it: do not add facts that are not in the source. \
        Write in the source's language. Aim for 400-900 words, shorter if the source is short.

        ---SOURCE---
        \(req.sourceContent ?? "")
        ---END-SOURCE---
        """
    }

    static func notesUser(quizName: String, cards: [CardPayload]) -> String {
        var lines = [
            "Write study notes that teach everything these flashcards test, for a quiz titled \"\(quizName)\".",
            "Organise the notes by theme rather than by card order, and add the context that connects the facts. Aim for 400-900 words.",
            "",
            "---FLASHCARDS---"
        ]
        for (i, c) in cards.enumerated() {
            var card = "\(i + 1). Q: \(c.prompt)\n   A: \(c.longAnswer)"
            if let s = c.shortAnswer, !s.isEmpty { card += " (short: \(s))" }
            lines.append(card)
        }
        lines.append("---END-FLASHCARDS---")
        return lines.joined(separator: "\n")
    }
}
