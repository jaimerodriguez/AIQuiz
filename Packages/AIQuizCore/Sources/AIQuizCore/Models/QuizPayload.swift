import Foundation

/// Top-level shape of a quiz JSON file: `{ "quiz": { ... } }`.
public struct QuizFile: Codable, Hashable, Sendable {
    public let quiz: QuizPayload

    public init(quiz: QuizPayload) {
        self.quiz = quiz
    }
}

/// A quiz as it appears in a JSON file or in a model response. Pure value type (SPEC §2).
public struct QuizPayload: Codable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var tags: [String]
    public var language: String?
    public var cards: [CardPayload]

    public init(name: String, description: String? = nil, tags: [String] = [], language: String? = nil, cards: [CardPayload]) {
        self.name = name
        self.description = description
        self.tags = tags
        self.language = language
        self.cards = cards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = try c.decode(String.self, forKey: AnyKey("name"))
        description = try? c.decodeIfPresent(String.self, forKey: AnyKey("description"))
        tags = ((try? c.decodeIfPresent([String].self, forKey: AnyKey("tags"))) ?? nil) ?? []
        language = try? c.decodeIfPresent(String.self, forKey: AnyKey("language"))
        cards = try c.decode([CardPayload].self, forKey: AnyKey("cards"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(description, forKey: AnyKey("description"))
        if !tags.isEmpty { try c.encode(tags, forKey: AnyKey("tags")) }
        try c.encodeIfPresent(language, forKey: AnyKey("language"))
        try c.encode(cards, forKey: AnyKey("cards"))
    }
}

/// How a card is asked and graded (SPEC D-2).
public enum CardKind: String, Codable, Hashable, Sendable, CaseIterable {
    case recall
    case multipleChoice
    case cloze
    case trueFalse

    public var label: String {
        switch self {
        case .recall: return "Recall"
        case .multipleChoice: return "Multiple choice"
        case .cloze: return "Fill in the blank"
        case .trueFalse: return "True or false"
        }
    }
}

/// One card. Accepts both `long_answer` and `long-answer` key styles on decode;
/// always encodes underscore style (SPEC D-1).
public struct CardPayload: Codable, Hashable, Sendable {
    public var prompt: String
    public var longAnswer: String
    public var shortAnswer: String?
    public var hint: String?
    public var kind: CardKind
    public var options: [String]?
    public var explanation: String?
    public var mnemonic: String?

    public init(
        prompt: String,
        longAnswer: String,
        shortAnswer: String? = nil,
        hint: String? = nil,
        kind: CardKind = .recall,
        options: [String]? = nil,
        explanation: String? = nil,
        mnemonic: String? = nil
    ) {
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
        self.kind = kind
        self.options = options
        self.explanation = explanation
        self.mnemonic = mnemonic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        prompt = try c.decode(String.self, forKey: AnyKey("prompt"))

        guard let long = Self.firstString(in: c, keys: ["long_answer", "long-answer"]) else {
            throw DecodingError.keyNotFound(
                AnyKey("long_answer"),
                .init(codingPath: c.codingPath, debugDescription: "Missing required key: long_answer / long-answer")
            )
        }
        longAnswer = long
        shortAnswer = Self.firstString(in: c, keys: ["short_answer", "short-answer"])
        hint = Self.firstString(in: c, keys: ["hint"])
        if let raw = Self.firstString(in: c, keys: ["kind"]) {
            guard let parsed = CardKind(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: c.codingPath + [AnyKey("kind")],
                    debugDescription: "Unknown card kind \"\(raw)\". Use recall, multipleChoice, cloze or trueFalse."
                ))
            }
            kind = parsed
        } else {
            kind = .recall
        }
        options = (try? c.decodeIfPresent([String].self, forKey: AnyKey("options"))) ?? nil
        explanation = Self.firstString(in: c, keys: ["explanation"])
        mnemonic = Self.firstString(in: c, keys: ["mnemonic"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(prompt, forKey: AnyKey("prompt"))
        try c.encode(longAnswer, forKey: AnyKey("long_answer"))
        try c.encodeIfPresent(shortAnswer, forKey: AnyKey("short_answer"))
        try c.encodeIfPresent(hint, forKey: AnyKey("hint"))
        if kind != .recall { try c.encode(kind, forKey: AnyKey("kind")) }
        try c.encodeIfPresent(options, forKey: AnyKey("options"))
        try c.encodeIfPresent(explanation, forKey: AnyKey("explanation"))
        try c.encodeIfPresent(mnemonic, forKey: AnyKey("mnemonic"))
    }

    private static func firstString(in c: KeyedDecodingContainer<AnyKey>, keys: [String]) -> String? {
        for key in keys {
            if let value = try? c.decode(String.self, forKey: AnyKey(key)) {
                return value
            }
        }
        return nil
    }
}

/// Dynamic coding key used to accept alternative key spellings.
public struct AnyKey: CodingKey, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

/// A rule in SPEC D-2 that a card breaks. The message names the card and the problem.
public struct CardValidationError: LocalizedError, Equatable, Sendable {
    /// 1-based card number in the file.
    public let cardNumber: Int
    public let problem: String

    public init(cardNumber: Int, problem: String) {
        self.cardNumber = cardNumber
        self.problem = problem
    }

    public var errorDescription: String? { "Card \(cardNumber): \(problem)" }
}

public enum CardValidator {
    /// The first rule the card breaks, or nil (SPEC D-1, D-2).
    public static func problem(with card: CardPayload) -> String? {
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if trim(card.prompt).isEmpty { return "the prompt is empty." }
        if trim(card.longAnswer).isEmpty { return "the long answer is empty." }
        switch card.kind {
        case .recall:
            return nil
        case .multipleChoice:
            let options = (card.options ?? []).map { trim($0) }.filter { !$0.isEmpty }
            guard (2...6).contains(options.count) else {
                return "a multiple-choice card needs 2 to 6 options; it has \(options.count)."
            }
            guard options.contains(trim(card.shortAnswer)) else {
                return "the short answer of a multiple-choice card must be one of its options."
            }
            return nil
        case .cloze:
            guard card.prompt.contains("{{blank}}") else {
                return "a fill-in-the-blank card needs at least one {{blank}} in its prompt."
            }
            guard !trim(card.shortAnswer).isEmpty else {
                return "a fill-in-the-blank card needs the blanked text as its short answer."
            }
            return nil
        case .trueFalse:
            guard ["true", "false"].contains(trim(card.shortAnswer).lowercased()) else {
                return "the short answer of a true-or-false card must be true or false."
            }
            return nil
        }
    }

    public static func validate(_ payload: QuizPayload) throws {
        for (index, card) in payload.cards.enumerated() {
            if let problem = problem(with: card) {
                throw CardValidationError(cardNumber: index + 1, problem: problem)
            }
        }
    }
}

public enum QuizDecoder {
    /// Decode and validate a quiz file. Throws `DecodingError` on malformed JSON and
    /// `CardValidationError` when a card breaks SPEC D-2.
    public static func decode(_ data: Data) throws -> QuizPayload {
        let payload = try JSONDecoder().decode(QuizFile.self, from: data).quiz
        try CardValidator.validate(payload)
        return payload
    }

    /// Pretty-printed, sorted-key JSON for export.
    public static func encode(_ payload: QuizPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(QuizFile(quiz: payload))
    }
}

/// Lowercased text the library search and tag filter match with `contains` (SPEC §3).
/// Shape: ` name #tag1 #tag2 `, so a tag filter can match ` #tag ` exactly.
public enum TagsSearch {
    public static func make(name: String, tags: [String]) -> String {
        " " + ([name] + tags.map { "#" + normalize($0) }).joined(separator: " ").lowercased() + " "
    }

    /// The needle for an exact tag match.
    public static func needle(forTag tag: String) -> String {
        " #" + normalize(tag).lowercased() + " "
    }

    /// Tags are single words: spaces become hyphens, a leading # is dropped.
    public static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Parses typed text such as "rome, history #latin" into ["rome", "history", "latin"]:
    /// commas, spaces and # all separate tags.
    public static func parse(_ text: String) -> [String] {
        clean(text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "#" })
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map(String.init))
    }

    /// Normalises a list of tags (a tag with spaces becomes hyphenated) and drops empty and
    /// duplicate ones, keeping the first spelling.
    public static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(normalize).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
