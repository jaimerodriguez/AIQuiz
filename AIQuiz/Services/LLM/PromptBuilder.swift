import Foundation

enum PromptBuilder {
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

    static func judgeSystem() -> String {
        """
        You grade short spoken or written answers to study prompts. Return strict JSON of the form:

        {"verdict":"correct|partial|wrong","reason":"one short sentence"}

        Treat the candidate as correct when it captures the key idea, even if phrasing differs. \
        Use partial when half the idea is right but something material is missing or wrong. \
        Use wrong when the candidate is off-topic, contradicts the answer, or is empty. \
        Never include any text outside the JSON.
        """
    }

    static func judgeUser(_ req: JudgeRequest) -> String {
        var lines: [String] = []
        lines.append("Prompt: \(req.prompt)")
        if let s = req.correctShort, !s.isEmpty {
            lines.append("Reference short answer: \(s)")
        }
        lines.append("Reference long answer: \(req.correctLong)")
        let answer = req.userAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Candidate answer: \(answer.isEmpty ? "(empty)" : answer)")
        return lines.joined(separator: "\n")
    }
}

enum LLMResponseParser {
    /// Find the first {...} block in the text and decode it as `T`.
    static func decode<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
        guard let json = extractJSONObject(from: raw) else {
            throw LLMError.malformedResponse("no JSON object found")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw LLMError.malformedResponse(String(describing: error))
        }
    }

    static func extractJSONObject(from raw: String) -> String? {
        // Strip markdown fences first.
        var text = raw
        if let start = text.range(of: "```") {
            let after = text[start.upperBound...]
            // skip optional language tag on same line
            if let newline = after.firstIndex(of: "\n") {
                text = String(after[after.index(after: newline)...])
            } else {
                text = String(after)
            }
            if let end = text.range(of: "```") {
                text = String(text[..<end.lowerBound])
            }
        }

        var depth = 0
        var startIdx: String.Index?
        for idx in text.indices {
            let ch = text[idx]
            if ch == "{" {
                if depth == 0 { startIdx = idx }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let start = startIdx {
                    return String(text[start...idx])
                }
            }
        }
        return nil
    }
}

struct JudgeJSON: Decodable {
    let verdict: String
    let reason: String

    func toVerdict() -> JudgeVerdict {
        let v: CardVerdict
        switch verdict.lowercased() {
        case "correct": v = .correct
        case "partial": v = .partial
        default: v = .wrong
        }
        return JudgeVerdict(verdict: v, reason: reason)
    }
}
