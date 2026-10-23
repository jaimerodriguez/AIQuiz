import Foundation

// Prompt: quiz generation (SPEC F-19). Version 4 — 2026-10-23.
// v4: card kinds (D-2, F-19 toggles): kind and options on every card.
// v3: document sources (PDF, scanned photo) and "part i of n" for long sources (§7.4).
// v2: optional fields are now `null` rather than omitted, matching the strict JSON schema in
// QuizGenerator.schema. Wording otherwise unchanged from v1.
// Output contract: QuizFile JSON (see Models/QuizPayload.swift).

public enum PromptBuilder {}

public extension PromptBuilder {
    static let quizSchemaInstruction = """
    Return ONLY a JSON object with this shape (no prose, no markdown fences):

    {
      "quiz": {
        "name": "<short title>",
        "cards": [
          {
            "prompt": "front of the card (20-200 chars)",
            "long_answer": "fuller explanation (20-400 chars, can be multi-sentence)",
            "short_answer": "one-line sharp answer, or null",
            "hint": "one-line hint, or null",
            "kind": "recall",
            "options": null
          }
        ]
      }
    }
    """

    /// The card-kind rules (SPEC D-2) for the kinds the user asked for.
    static func kindsInstruction(_ kinds: Set<CardKind>) -> String {
        let extra = kinds.subtracting([.recall])
        guard !extra.isEmpty else {
            return "Card kinds: use \"recall\" for every card and set options to null."
        }
        var rules = ["- recall: a question answered from memory; options null."]
        if extra.contains(.multipleChoice) {
            rules.append("- multipleChoice: 2 to 6 plausible options; short_answer must be exactly one of the options, copied character for character.")
        }
        if extra.contains(.cloze) {
            rules.append("- cloze: the prompt is a sentence with one or more {{blank}} markers where key words were removed; short_answer holds the removed words, joined with | when there are several blanks, in order; options null.")
        }
        if extra.contains(.trueFalse) {
            rules.append("- trueFalse: the prompt is a statement; short_answer is exactly true or false; options null. Make some statements false.")
        }
        return "Card kinds: mix these kinds roughly evenly, following each one's rules:\n" + rules.joined(separator: "\n")
    }

    static func quizSystem() -> String {
        """
        You generate study quizzes as strict JSON. Cards should test understanding, \
        not trivia recall, and short_answer (when provided) must be punchy and unambiguous. \
        Avoid duplicate prompts. Never include explanations, code fences, or commentary outside \
        the required JSON object.
        """
    }

    static func quizUser(_ req: QuizGenRequest) -> String {
        var lines: [String] = []
        switch req.source {
        case .topic:
            lines.append("Topic: \(req.topic)")
            if let n = req.cardCount { lines.append("Card count: \(n)") }
            if let d = req.difficulty { lines.append("Difficulty: \(d)") }
            if let l = req.language { lines.append("Output language: \(l)") }
            if let t = req.tone { lines.append("Tone: \(t)") }
            if let f = req.focus, !f.isEmpty { lines.append("Focus areas: \(f)") }
            if let e = req.exclude, !e.isEmpty { lines.append("Exclude: \(e)") }
        case .markdown:
            lines.append("Read the following markdown content, then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-MARKDOWN---\n\(c)\n---END-SOURCE---") }
        case .article:
            lines.append("Read the following article (extracted from a web page), then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-ARTICLE---\n\(c)\n---END-SOURCE---") }
        case .document:
            lines.append("Read the following document text (from a PDF or a scanned page; ignore page numbers, headers and OCR noise), then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-DOCUMENT---\n\(c)\n---END-SOURCE---") }
        }
        lines.append("\n" + kindsInstruction(req.kinds))
        if let part = req.part {
            lines.append("\nThis is part \(part.index) of \(part.count) of a longer source. Write cards about this part only.\(req.cardCount.map { " Write about \($0) cards." } ?? "")")
        }
        lines.append("\n" + quizSchemaInstruction)
        return lines.joined(separator: "\n")
    }
}
