import Foundation
import LLMKit

/// SPEC F-19. Generates a quiz from a topic or source text through any `LLMClient`.
public enum QuizGenerator {
    public static let schema = JSONSchema.object(properties: [
        .init("quiz", .object(properties: [
            .init("name", .string(description: "Short quiz title")),
            .init("cards", .array(of: .object(properties: [
                .init("prompt", .string(description: "Front of the card, 20-200 characters")),
                .init("long_answer", .string(description: "Fuller explanation, 20-400 characters")),
                .init("short_answer", .nullable(.string(description: "One-line sharp answer"))),
                .init("hint", .nullable(.string(description: "One-line hint")))
            ])))
        ]))
    ])

    public static func task(for request: QuizGenRequest) -> StructuredTask<QuizFile> {
        StructuredTask<QuizFile>(
            name: "quiz",
            system: PromptBuilder.quizSystem(),
            user: PromptBuilder.quizUser(request),
            schema: schema,
            maxTokens: 32_000,
            effort: .medium,
            timeout: 300,
            useStreaming: true,
            maxRetries: 1,
            validate: { file in
                guard !file.quiz.cards.isEmpty else {
                    throw LLMResponseParseError("the quiz has no cards")
                }
                if file.quiz.cards.contains(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    throw LLMResponseParseError("a card has an empty prompt")
                }
            }
        )
    }

    public static func generate(_ request: QuizGenRequest, using client: LLMClient) async throws -> QuizPayload {
        let task = task(for: request)
        try ContextBudget.check(system: task.system, user: task.user, contextWindow: client.endpoint.contextWindowTokens)
        return try await client.run(task).quiz
    }
}

/// SPEC F-15. Grades a spoken or typed answer against the card's reference answer.
public enum AnswerJudge {
    public static let verdicts = ["correct", "partial", "wrong"]

    public static let schema = JSONSchema.object(properties: [
        .init("verdict", .string(enumValues: verdicts)),
        .init("reason", .string(description: "One short sentence"))
    ])

    public static func task(for request: JudgeRequest) -> StructuredTask<JudgeJSON> {
        StructuredTask<JudgeJSON>(
            name: "judge",
            system: PromptBuilder.judgeSystem(),
            user: PromptBuilder.judgeUser(request),
            schema: schema,
            maxTokens: 4_096,
            effort: .low,
            timeout: 60,
            useStreaming: false,
            maxRetries: 1,
            validate: { json in
                guard verdicts.contains(json.verdict.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw LLMResponseParseError("verdict must be one of correct, partial, wrong")
                }
            }
        )
    }

    public static func judge(_ request: JudgeRequest, using client: LLMClient) async throws -> JudgeVerdict {
        try await client.run(task(for: request)).toVerdict()
    }
}

/// SPEC §7.4. Rejects inputs that would use more than 80 % of the model's context window.
/// Chunked summarisation for long sources arrives in PLAN Phase 5.
public enum ContextBudget {
    public static let inputShare = 0.8

    public static func estimateTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    public static func check(system: String, user: String, contextWindow: Int) throws {
        let estimate = estimateTokens(system) + estimateTokens(user)
        if estimate > Int(Double(contextWindow) * inputShare) {
            throw LLMError.contextTooLong
        }
    }
}
