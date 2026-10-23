import Foundation

// Prompt: answer judging (SPEC F-15). Version 1 — carried over from v1 unchanged; the verdict
// enum is now also enforced by AnswerJudge.schema.
// Output contract: JudgeJSON (see LLM/Requests.swift).

public extension PromptBuilder {
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
