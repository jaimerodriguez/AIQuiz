import Foundation

// Prompt: quiz generation (SPEC F-19). Version 3 — 2026-10-22.
// v2: optional fields are now `null` rather than omitted, matching the strict JSON schema in
// QuizGenerator.schema.
// v3: when study notes were written first (CR-006), they are included and every card must be
// answerable from them. A source may be dropped (notes only) when both don't fit.
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
            "hint": "one-line hint, or null"
          }
        ]
      }
    }
    """

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
        case .markdown where req.sourceContent == nil && req.studyNotes != nil,
             .article where req.sourceContent == nil && req.studyNotes != nil:
            lines.append("Read the following study notes, then produce a JSON quiz that best teaches their key ideas. Decide the card count, difficulty, language, tone, and focus from the notes.")
        case .markdown:
            lines.append("Read the following markdown content, then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-MARKDOWN---\n\(c)\n---END-SOURCE---") }
        case .article:
            lines.append("Read the following article (extracted from a web page), then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-ARTICLE---\n\(c)\n---END-SOURCE---") }
        }
        if let notes = req.studyNotes {
            lines.append("\nThe learner studies from these notes. Every card must be answerable from them, and the cards together should cover their main points.")
            lines.append("---STUDY-NOTES---\n\(notes)\n---END-NOTES---")
        }
        lines.append("\n" + quizSchemaInstruction)
        return lines.joined(separator: "\n")
    }
}
