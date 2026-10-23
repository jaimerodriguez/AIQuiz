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
                .init("hint", .nullable(.string(description: "One-line hint"))),
                .init("kind", .string(enumValues: CardKind.allCases.map(\.rawValue))),
                .init("options", .nullable(.array(of: .string(), description: "Multiple-choice options")))
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
                let allowed = request.kinds.union([.recall])
                for (index, card) in file.quiz.cards.enumerated() {
                    if !allowed.contains(card.kind) {
                        throw LLMResponseParseError("card \(index + 1) is \(card.kind.rawValue), which wasn't requested")
                    }
                    if let problem = CardValidator.problem(with: card) {
                        throw LLMResponseParseError("card \(index + 1): \(problem)")
                    }
                }
            }
        )
    }

    public static func generate(_ request: QuizGenRequest, using client: LLMClient) async throws -> QuizPayload {
        let task = task(for: request)
        try ContextBudget.check(system: task.system, user: task.user, contextWindow: client.endpoint.contextWindowTokens)
        return try await client.run(task).quiz
    }

    /// Generates from a source of any length (SPEC §7.4). A source that fits goes in one
    /// request; a longer one is split into parts of at most 40 % of the context window, each
    /// part gets its share of the cards, and the decks are merged without repeated prompts.
    /// No study notes are written (F-20 is on hold, CR-007).
    public static func generateFromSource(
        _ request: QuizGenRequest,
        using client: LLMClient,
        progress: (@Sendable (_ part: Int, _ of: Int) -> Void)? = nil
    ) async throws -> QuizPayload {
        let window = client.endpoint.contextWindowTokens
        let probe = task(for: request)
        let fits = ContextBudget.estimateTokens(probe.system) + ContextBudget.estimateTokens(probe.user) <= Int(Double(window) * ContextBudget.inputShare)
        guard !fits, let content = request.sourceContent else {
            progress?(1, 1)
            return try await generate(request, using: client)
        }
        let parts = Chunker.chunks(content, maxCharacters: Int(Double(window) * ContextBudget.chunkShare) * 4)
        var merged: QuizPayload?
        var seen = Set<String>()
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress?(index + 1, parts.count)
            var partRequest = request
            partRequest.sourceContent = part
            partRequest.part = .init(index: index + 1, count: parts.count)
            if let total = request.cardCount { partRequest.cardCount = max(2, Int((Double(total) / Double(parts.count)).rounded(.up))) }
            let quiz = try await generate(partRequest, using: client)
            let fresh = quiz.cards.filter { seen.insert(normalised($0.prompt)).inserted }
            if merged == nil {
                merged = QuizPayload(name: quiz.name, description: quiz.description, tags: quiz.tags, language: quiz.language, cards: fresh)
            } else {
                merged?.cards += fresh
            }
        }
        guard let result = merged, !result.cards.isEmpty else { throw LLMError.malformedResponse("the source produced no cards") }
        return result
    }

    static func normalised(_ prompt: String) -> String {
        prompt.lowercased().filter { $0.isLetter || $0.isNumber }
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
    /// Each part of a long source is at most this share of the context window (§7.4).
    public static let chunkShare = 0.4

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
