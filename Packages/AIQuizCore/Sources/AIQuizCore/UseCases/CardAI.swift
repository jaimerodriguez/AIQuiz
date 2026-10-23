import Foundation
import LLMKit

// Card-level AI features (SPEC §7, PLAN Phase 4). Each one is a prompt file in Prompts/, a
// strict JSON schema, a Decodable output type and one function. All run through
// `LLMClient.run`, which validates and retries once on a malformed reply (§7.2).

private func requireText(_ text: String, _ field: String) throws {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw LLMResponseParseError("\(field) is empty")
    }
}

/// The card shape the generation-style features return.
enum CardSchema {
    static let card = JSONSchema.object(properties: [
        .init("prompt", .string(description: "A question")),
        .init("long_answer", .string(description: "2-4 sentence answer")),
        .init("short_answer", .nullable(.string(description: "A few words"))),
        .init("hint", .nullable(.string(description: "A nudge that does not give the answer away")))
    ])
}

// MARK: - F-23, F-16

public struct ExplanationJSON: Decodable, Sendable, Equatable {
    public let explanation: String
}

public enum Explainer {
    public static let schema = JSONSchema.object(properties: [.init("explanation", .string())])

    /// F-23: 3-6 sentences on the idea behind a card.
    public static func explain(_ card: CardPayload, quizName: String?, using client: LLMClient) async throws -> String {
        try await client.run(StructuredTask<ExplanationJSON>(
            name: "explain",
            system: PromptBuilder.explainSystem(),
            user: PromptBuilder.explainUser(card: card, quizName: quizName),
            schema: schema, maxTokens: 2_048, effort: .low, timeout: 60,
            validate: { try requireText($0.explanation, "explanation") }
        )).explanation
    }

    /// F-16: what the spoken answer missed, in 2-4 sentences.
    public static func whyWrong(_ card: CardPayload, answer: String, using client: LLMClient) async throws -> String {
        try await client.run(StructuredTask<ExplanationJSON>(
            name: "whyWrong",
            system: PromptBuilder.whyWrongSystem(),
            user: PromptBuilder.whyWrongUser(card: card, answer: answer),
            schema: schema, maxTokens: 2_048, effort: .low, timeout: 60,
            validate: { try requireText($0.explanation, "explanation") }
        )).explanation
    }
}

// MARK: - F-24

public struct HintJSON: Decodable, Sendable, Equatable {
    public let hint: String
}

public enum HintGenerator {
    /// Cards keep at most this many AI hints.
    public static let maxHints = 3
    public static let schema = JSONSchema.object(properties: [.init("hint", .string())])

    /// The next hint, stronger than `previous` (the author's hint, then earlier AI hints).
    public static func nextHint(for card: CardPayload, previous: [String], using client: LLMClient) async throws -> String {
        try await client.run(StructuredTask<HintJSON>(
            name: "hint",
            system: PromptBuilder.hintSystem(),
            user: PromptBuilder.hintUser(card: card, previous: previous),
            schema: schema, maxTokens: 1_024, effort: .low, timeout: 60,
            validate: { try requireText($0.hint, "hint") }
        )).hint
    }
}

// MARK: - F-25

public struct MnemonicJSON: Decodable, Sendable, Equatable {
    public let mnemonic: String
}

public enum MnemonicGenerator {
    public static let schema = JSONSchema.object(properties: [.init("mnemonic", .string())])

    public static func mnemonic(for card: CardPayload, using client: LLMClient) async throws -> String {
        try await client.run(StructuredTask<MnemonicJSON>(
            name: "mnemonic",
            system: PromptBuilder.mnemonicSystem(),
            user: PromptBuilder.mnemonicUser(card: card),
            schema: schema, maxTokens: 1_024, effort: .low, timeout: 60,
            validate: { try requireText($0.mnemonic, "mnemonic") }
        )).mnemonic
    }
}

// MARK: - F-26

public struct DifficultyJSON: Decodable, Sendable, Equatable {
    public struct Rating: Decodable, Sendable, Equatable {
        public let index: Int
        public let difficulty: Int
    }
    public let ratings: [Rating]
}

public enum DifficultyRater {
    public static let batchSize = 20
    public static let schema = JSONSchema.object(properties: [
        .init("ratings", .array(of: .object(properties: [
            .init("index", .integer(description: "Card index")),
            .init("difficulty", .integer(description: "1 easy to 5 very hard"))
        ])))
    ])

    /// One rating (1-5) per card, nil where the model skipped a card. Sends batches of 20.
    public static func rate(_ cards: [CardPayload], using client: LLMClient) async throws -> [Int?] {
        var result = [Int?](repeating: nil, count: cards.count)
        for start in stride(from: 0, to: cards.count, by: batchSize) {
            let batch = Array(cards[start..<min(start + batchSize, cards.count)])
            let json = try await client.run(StructuredTask<DifficultyJSON>(
                name: "difficulty",
                system: PromptBuilder.difficultySystem(),
                user: PromptBuilder.difficultyUser(cards: batch),
                schema: schema, maxTokens: 4_096, effort: .low, timeout: 90,
                validate: { json in
                    if json.ratings.filter({ batch.indices.contains($0.index) }).isEmpty {
                        throw LLMResponseParseError("no ratings for the cards given")
                    }
                }
            ))
            for rating in json.ratings where batch.indices.contains(rating.index) {
                result[start + rating.index] = min(5, max(1, rating.difficulty))
            }
        }
        return result
    }
}

// MARK: - F-27

public struct ExpandJSON: Decodable, Sendable, Equatable {
    public let cards: [CardPayload]
}

public enum CardExpander {
    public static let schema = JSONSchema.object(properties: [.init("cards", .array(of: CardSchema.card))])

    /// 3-5 prerequisite or deeper cards around `card`.
    public static func expand(_ card: CardPayload, quizName: String?, existingPrompts: [String], using client: LLMClient) async throws -> [CardPayload] {
        try await client.run(StructuredTask<ExpandJSON>(
            name: "expand",
            system: PromptBuilder.expandSystem(),
            user: PromptBuilder.expandUser(card: card, quizName: quizName, existingPrompts: existingPrompts),
            schema: schema, maxTokens: 8_000, effort: .medium, timeout: 120,
            validate: { json in
                guard (1...6).contains(json.cards.count) else { throw LLMResponseParseError("expected 3 to 5 cards, got \(json.cards.count)") }
                for (i, c) in json.cards.enumerated() {
                    if let problem = CardValidator.problem(with: c) { throw LLMResponseParseError("card \(i + 1): \(problem)") }
                }
            }
        )).cards
    }
}

// MARK: - F-28

public struct RewriteJSON: Decodable, Sendable, Equatable {
    public let card: CardPayload
}

public enum CardRewriter {
    public enum Instruction: Sendable, Hashable {
        case simplify
        case harder
        case shorten
        case translate(String)

        var promptText: String {
            switch self {
            case .simplify: return "Make it simpler: plainer words, one idea, for a beginner."
            case .harder: return "Make it harder: ask for a deeper or more precise understanding of the same idea."
            case .shorten: return "Make it shorter: trim the prompt and the long answer to the essentials."
            case .translate(let language): return "Translate every field into \(language). Keep the meaning exactly."
            }
        }

        public var label: String {
            switch self {
            case .simplify: return "Simplify"
            case .harder: return "Make harder"
            case .shorten: return "Shorten"
            case .translate(let language): return "Translate to \(language)"
            }
        }
    }

    public static let schema = JSONSchema.object(properties: [.init("card", CardSchema.card)])

    /// The rewritten card. Kind, options, explanation and mnemonic stay as they were.
    public static func rewrite(_ card: CardPayload, _ instruction: Instruction, using client: LLMClient) async throws -> CardPayload {
        let rewritten = try await client.run(StructuredTask<RewriteJSON>(
            name: "rewrite",
            system: PromptBuilder.rewriteSystem(),
            user: PromptBuilder.rewriteUser(card: card, instruction: instruction),
            schema: schema, maxTokens: 4_000, effort: .medium, timeout: 90,
            validate: { json in
                if let problem = CardValidator.problem(with: json.card) { throw LLMResponseParseError(problem) }
            }
        )).card
        var merged = card
        merged.prompt = rewritten.prompt
        merged.longAnswer = rewritten.longAnswer
        merged.shortAnswer = rewritten.shortAnswer
        merged.hint = rewritten.hint
        if card.kind != .recall, CardValidator.problem(with: merged) != nil {
            // A rewrite that breaks a choice card's rules falls back to a recall card.
            merged.kind = .recall
            merged.options = nil
        }
        return merged
    }
}

// MARK: - F-29

public struct LintIssue: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Codable { case warn, error }
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case ambiguous, duplicate, leakyHint, tooLong, answerMismatch

        public var label: String {
            switch self {
            case .ambiguous: return "Ambiguous"
            case .duplicate: return "Duplicate"
            case .leakyHint: return "Hint gives it away"
            case .tooLong: return "Too long"
            case .answerMismatch: return "Answer mismatch"
            }
        }
    }

    /// Index into the cards that were linted.
    public let index: Int
    public let severity: Severity
    public let kind: Kind
    public let message: String
    public let suggestedFix: CardPayload?

    public var id: String { "\(index)-\(kind.rawValue)" }

    public init(index: Int, severity: Severity, kind: Kind, message: String, suggestedFix: CardPayload?) {
        self.index = index
        self.severity = severity
        self.kind = kind
        self.message = message
        self.suggestedFix = suggestedFix
    }
}

public struct LintJSON: Decodable, Sendable, Equatable {
    public struct Issue: Decodable, Sendable, Equatable {
        public let index: Int
        public let severity: String
        public let kind: String
        public let message: String
        public let suggestedFix: CardPayload?

        enum CodingKeys: String, CodingKey {
            case index, severity, kind, message
            case suggestedFix = "suggested_fix"
        }
    }
    public let issues: [Issue]
}

public enum CardLinter {
    public static let batchSize = 40
    public static let schema = JSONSchema.object(properties: [
        .init("issues", .array(of: .object(properties: [
            .init("index", .integer(description: "Card index")),
            .init("severity", .string(enumValues: ["warn", "error"])),
            .init("kind", .string(enumValues: LintIssue.Kind.allCases.map(\.rawValue))),
            .init("message", .string(description: "One sentence for the learner")),
            .init("suggested_fix", .nullable(CardSchema.card))
        ])))
    ])

    /// Problems across the cards, with indices into `cards`. Sends batches of 40; issues
    /// with an unknown index or kind are dropped, and a fix that breaks D-2 is discarded.
    public static func lint(_ cards: [CardPayload], using client: LLMClient) async throws -> [LintIssue] {
        var issues: [LintIssue] = []
        for start in stride(from: 0, to: cards.count, by: batchSize) {
            let batch = Array(cards[start..<min(start + batchSize, cards.count)])
            let json = try await client.run(StructuredTask<LintJSON>(
                name: "lint",
                system: PromptBuilder.lintSystem(),
                user: PromptBuilder.lintUser(cards: batch),
                schema: schema, maxTokens: 16_000, effort: .medium, timeout: 180
            ))
            for raw in json.issues {
                guard batch.indices.contains(raw.index), let kind = LintIssue.Kind(rawValue: raw.kind) else { continue }
                var fix = raw.suggestedFix
                if let candidate = fix {
                    var merged = batch[raw.index]
                    merged.prompt = candidate.prompt
                    merged.longAnswer = candidate.longAnswer
                    merged.shortAnswer = candidate.shortAnswer
                    merged.hint = candidate.hint
                    fix = CardValidator.problem(with: merged) == nil ? merged : nil
                }
                issues.append(LintIssue(
                    index: start + raw.index,
                    severity: LintIssue.Severity(rawValue: raw.severity) ?? .warn,
                    kind: kind,
                    message: raw.message,
                    suggestedFix: fix
                ))
            }
        }
        return issues
    }
}

// MARK: - F-44

public struct RecapJSON: Decodable, Sendable, Equatable {
    public let recap: String
}

public enum SessionRecapper {
    public static let schema = JSONSchema.object(properties: [.init("recap", .string())])

    public static func recap(quizName: String?, results: [(card: CardPayload, verdict: CardVerdict)], using client: LLMClient) async throws -> String {
        try await client.run(StructuredTask<RecapJSON>(
            name: "recap",
            system: PromptBuilder.recapSystem(),
            user: PromptBuilder.recapUser(quizName: quizName, results: results),
            schema: schema, maxTokens: 1_024, effort: .low, timeout: 60,
            validate: { try requireText($0.recap, "recap") }
        )).recap
    }
}
