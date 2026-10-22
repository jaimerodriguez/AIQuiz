import Foundation

// Prompt: quiz generation (SPEC F-19). Version 1 — carried over from v1 unchanged.
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
            "short_answer": "optional one-line sharp answer",
            "hint": "optional one-line hint"
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
        case .markdown:
            lines.append("Read the following markdown content, then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-MARKDOWN---\n\(c)\n---END-SOURCE---") }
        case .article:
            lines.append("Read the following article (extracted from a web page), then produce a JSON quiz that best teaches its key ideas. Decide the card count, difficulty, language, tone, and focus from the content itself.")
            if let c = req.sourceContent { lines.append("\n---SOURCE-ARTICLE---\n\(c)\n---END-SOURCE---") }
        }
        lines.append("\n" + quizSchemaInstruction)
        return lines.joined(separator: "\n")
    }

    /// Appended to the user message on the single retry after a decode failure.
    static func retrySuffix(decodeError: String) -> String {
        "\n\nThe previous response could not be decoded: \(decodeError). Return only the JSON object exactly matching the schema."
    }
}
