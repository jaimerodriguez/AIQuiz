import Foundation
import LLMKit

/// Inputs for the insights digest (SPEC F-43): what the app knows about each quiz.
public struct InsightsQuiz: Sendable {
    public struct Session: Sendable {
        public var date: Date
        public var mode: String
        public var score: Double?
        public init(date: Date, mode: String, score: Double?) { self.date = date; self.mode = mode; self.score = score }
    }

    public struct Card: Sendable {
        public var id: UUID
        public var prompt: String
        public var correct: Int
        public var partial: Int
        public var wrong: Int
        public var lapses: Int
        public init(id: UUID, prompt: String, correct: Int, partial: Int, wrong: Int, lapses: Int) {
            self.id = id; self.prompt = prompt; self.correct = correct; self.partial = partial; self.wrong = wrong; self.lapses = lapses
        }
        /// How much trouble the card gives: wrong answers and lapses weigh most.
        var trouble: Int { wrong * 2 + partial + lapses * 2 }
    }

    public var name: String
    public var sessions: [Session]
    public var cards: [Card]

    public init(name: String, sessions: [Session], cards: [Card]) {
        self.name = name
        self.sessions = sessions
        self.cards = cards
    }
}

public struct InsightsReport: Sendable, Equatable {
    public struct Confusion: Sendable, Equatable {
        public var description: String
        public var cardIds: [UUID]
    }

    public var headline: String
    public var strengths: [String]
    public var confusions: [Confusion]
    public var recommendations: [String]
    public var drillCards: [CardPayload]
}

struct InsightsJSON: Decodable, Sendable {
    struct Confusion: Decodable, Sendable {
        let description: String
        let cardIds: [String]
        enum CodingKeys: String, CodingKey { case description; case cardIds = "card_ids" }
    }
    let headline: String
    let strengths: [String]
    let confusions: [Confusion]
    let recommendations: [String]
    let drillCards: [CardPayload]
    enum CodingKeys: String, CodingKey { case headline, strengths, confusions, recommendations; case drillCards = "drill_cards" }
}

public enum InsightsReporter {
    /// The digest stays under this many tokens (characters / 4, §7.4).
    public static let tokenBudget = 6_000

    public static let schema = JSONSchema.object(properties: [
        .init("headline", .string()),
        .init("strengths", .array(of: .string())),
        .init("confusions", .array(of: .object(properties: [
            .init("description", .string()),
            .init("card_ids", .array(of: .string(description: "Short card ids from the digest")))
        ]))),
        .init("recommendations", .array(of: .string())),
        .init("drill_cards", .array(of: CardSchema.card))
    ])

    /// Short id used in the digest (first 8 characters of the UUID).
    public static func shortId(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// A compact history: per quiz, the last 10 sessions and its most troublesome cards,
    /// quizzes in order of how much trouble they give. Stops before `tokenBudget`.
    public static func digest(_ quizzes: [InsightsQuiz], tokenBudget: Int = tokenBudget) -> String {
        let budget = tokenBudget * 4
        var out = ""
        let ranked = quizzes.sorted { $0.cards.map(\.trouble).reduce(0, +) > $1.cards.map(\.trouble).reduce(0, +) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for quiz in ranked {
            var block = "## \(quiz.name)\n"
            let sessions = quiz.sessions.sorted { $0.date > $1.date }.prefix(10)
            if !sessions.isEmpty {
                block += "Sessions: " + sessions.map { "\(formatter.string(from: $0.date)) \($0.mode) \($0.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "-")" }.joined(separator: "; ") + "\n"
            }
            for card in quiz.cards.filter({ $0.trouble > 0 }).sorted(by: { $0.trouble > $1.trouble }).prefix(15) {
                block += "- [\(shortId(card.id))] \(card.prompt.prefix(140)) — right \(card.correct), partly \(card.partial), wrong \(card.wrong), lapses \(card.lapses)\n"
            }
            if out.count + block.count + 1 > budget {
                if out.isEmpty { out = String(block.prefix(budget)) }
                break
            }
            out += block + "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func report(_ quizzes: [InsightsQuiz], using client: LLMClient) async throws -> InsightsReport {
        let digest = digest(quizzes)
        guard !digest.isEmpty else { throw LLMError.malformedResponse("there is no study history yet") }
        let ids = Dictionary(quizzes.flatMap(\.cards).map { (shortId($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
        let json = try await client.run(StructuredTask<InsightsJSON>(
            name: "insights",
            system: PromptBuilder.insightsSystem(),
            user: PromptBuilder.insightsUser(digest: digest),
            schema: schema, maxTokens: 8_000, effort: .medium, timeout: 120,
            validate: { json in
                if json.headline.trimmingCharacters(in: .whitespaces).isEmpty { throw LLMResponseParseError("headline is empty") }
                let valid = json.drillCards.filter { CardValidator.problem(with: $0) == nil }.count
                if valid == 0 {
                    throw LLMResponseParseError("drill_cards has \(json.drillCards.count) usable cards; write 3 to 8, each with a prompt and a long_answer")
                }
            }
        ))
        return InsightsReport(
            headline: json.headline,
            strengths: json.strengths,
            confusions: json.confusions.map { .init(description: $0.description, cardIds: $0.cardIds.compactMap { ids[$0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))] }) },
            recommendations: json.recommendations,
            drillCards: json.drillCards.filter { CardValidator.problem(with: $0) == nil }
        )
    }
}
