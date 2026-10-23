import Foundation
import LLMKit

/// One question and the learner's spoken answer in an oral exam (SPEC F-45).
public struct OralExchange: Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// The examiner's move after a first answer: accept and move on, or ask one follow-up.
public struct OralTurnDecision: Sendable, Equatable {
    /// The follow-up question, or nil to move on.
    public var followUp: String?
    /// What the examiner says: the acknowledgement, or the follow-up itself.
    public var say: String

    public init(followUp: String?, say: String) {
        self.followUp = followUp
        self.say = say
    }
}

/// A card and its exchanges, for the final grading.
public struct OralExamItem: Sendable, Equatable {
    public var card: CardSnapshot
    public var exchanges: [OralExchange]

    public init(card: CardSnapshot, exchanges: [OralExchange]) {
        self.card = card
        self.exchanges = exchanges
    }
}

/// The final grading: a verdict per card that was asked, and two sentences overall.
public struct OralExamResult: Sendable, Equatable {
    public var grades: [UUID: AIGrade]
    public var overall: String

    public init(grades: [UUID: AIGrade], overall: String) {
        self.grades = grades
        self.overall = overall
    }
}

struct OralTurnJSON: Decodable, Sendable {
    let action: String
    let say: String
}

struct OralGradeJSON: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        let cardId: String
        let verdict: String
        let reason: String
        enum CodingKeys: String, CodingKey { case cardId = "card_id", verdict, reason }
    }
    let cards: [Card]
    let overall: String
}

/// The AI side of the oral exam (SPEC §9.2).
public enum OralExaminer {
    public static let turnSchema = JSONSchema.object(properties: [
        .init("action", .string(enumValues: ["accept", "follow_up"])),
        .init("say", .string())
    ])

    public static let gradeSchema = JSONSchema.object(properties: [
        .init("cards", .array(of: .object(properties: [
            .init("card_id", .string()),
            .init("verdict", .string(enumValues: ["correct", "partial", "wrong"])),
            .init("reason", .string())
        ]))),
        .init("overall", .string())
    ])

    /// The question the examiner reads aloud for a card: the prompt, with blanks spoken as
    /// "blank", options read out, and true-or-false said as such.
    public static func question(for card: CardSnapshot) -> String {
        switch card.kind {
        case .recall:
            return card.prompt
        case .cloze:
            return "Fill in the blank: " + card.prompt.replacingOccurrences(of: Cloze.marker, with: "blank")
        case .trueFalse:
            return "True or false: " + card.prompt
        case .multipleChoice:
            guard !card.options.isEmpty else { return card.prompt }
            var options = card.options
            let last = options.removeLast()
            let list = options.isEmpty ? last : options.joined(separator: ", ") + ", or " + last
            return card.prompt + " Is it " + list + "?"
        }
    }

    /// After the first answer: accept, or one follow-up aimed at the gap.
    public static func decide(card: CardSnapshot, exchanges: [OralExchange], using client: LLMClient) async throws -> OralTurnDecision {
        let json = try await client.run(StructuredTask<OralTurnJSON>(
            name: "oralExamTurn",
            system: PromptBuilder.oralTurnSystem(),
            user: PromptBuilder.oralTurnUser(card: card.payload, exchanges: exchanges),
            schema: turnSchema, maxTokens: 400, effort: .low, timeout: 30,
            validate: { json in
                guard ["accept", "follow_up"].contains(json.action) else { throw LLMResponseParseError("action must be accept or follow_up") }
                if json.action == "follow_up", json.say.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw LLMResponseParseError("a follow_up needs a question in say")
                }
            }
        ))
        let say = json.say.trimmingCharacters(in: .whitespacesAndNewlines)
        return OralTurnDecision(followUp: json.action == "follow_up" ? say : nil, say: say)
    }

    /// Grades every asked card at the end. Cards are referred to as c1, c2, … in order.
    public static func grade(_ items: [OralExamItem], using client: LLMClient) async throws -> OralExamResult {
        let ids = items.indices.map { "c\($0 + 1)" }
        let byId = Dictionary(uniqueKeysWithValues: zip(ids, items.map(\.card.id)))
        let json = try await client.run(StructuredTask<OralGradeJSON>(
            name: "oralExamGrade",
            system: PromptBuilder.oralGradeSystem(),
            user: PromptBuilder.oralGradeUser(zip(ids, items).map { (id: $0.0, card: $0.1.card.payload, exchanges: $0.1.exchanges) }),
            schema: gradeSchema, maxTokens: 4_000, effort: .medium, timeout: 120,
            validate: { json in
                let graded = Set(json.cards.compactMap { byId[$0.cardId] != nil && CardVerdict(rawValue: $0.verdict) != nil ? $0.cardId : nil })
                let missing = ids.filter { !graded.contains($0) }
                if !missing.isEmpty { throw LLMResponseParseError("grade every card; missing \(missing.joined(separator: ", "))") }
            }
        ))
        var grades: [UUID: AIGrade] = [:]
        for card in json.cards {
            guard let id = byId[card.cardId], let verdict = CardVerdict(rawValue: card.verdict), verdict != .skipped else { continue }
            grades[id] = AIGrade(verdict: verdict, reason: card.reason)
        }
        return OralExamResult(grades: grades, overall: json.overall.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public extension CardSnapshot {
    /// The card's content, for prompts.
    var payload: CardPayload {
        CardPayload(prompt: prompt, longAnswer: longAnswer, shortAnswer: shortAnswer, hint: hint, kind: kind,
                    options: options.isEmpty ? nil : options, explanation: explanation)
    }
}
