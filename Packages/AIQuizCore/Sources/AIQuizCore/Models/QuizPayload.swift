import Foundation

/// Top-level shape of a quiz JSON file: `{ "quiz": { ... } }`.
public struct QuizFile: Codable, Hashable, Sendable {
    public let quiz: QuizPayload

    public init(quiz: QuizPayload) {
        self.quiz = quiz
    }
}

/// A quiz as it appears in a JSON file or in a model response. Pure value type.
/// `study_notes` (Markdown) is optional; it round-trips through export and import (CR-006).
public struct QuizPayload: Codable, Hashable, Sendable {
    public let name: String
    public let cards: [CardPayload]
    public var studyNotes: String?

    public init(name: String, cards: [CardPayload], studyNotes: String? = nil) {
        self.name = name
        self.cards = cards
        self.studyNotes = studyNotes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = try c.decode(String.self, forKey: AnyKey("name"))
        cards = try c.decode([CardPayload].self, forKey: AnyKey("cards"))
        let notes = (try? c.decode(String.self, forKey: AnyKey("study_notes")))
            ?? (try? c.decode(String.self, forKey: AnyKey("study-notes")))
        studyNotes = (notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : notes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(cards, forKey: AnyKey("cards"))
        try c.encodeIfPresent(studyNotes, forKey: AnyKey("study_notes"))
    }
}

/// One card. Accepts both `long_answer` and `long-answer` key styles on decode;
/// always encodes underscore style (SPEC D-1).
public struct CardPayload: Codable, Hashable, Sendable {
    public let prompt: String
    public let longAnswer: String
    public let shortAnswer: String?
    public let hint: String?

    public init(prompt: String, longAnswer: String, shortAnswer: String? = nil, hint: String? = nil) {
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
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
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(prompt, forKey: AnyKey("prompt"))
        try c.encode(longAnswer, forKey: AnyKey("long_answer"))
        try c.encodeIfPresent(shortAnswer, forKey: AnyKey("short_answer"))
        try c.encodeIfPresent(hint, forKey: AnyKey("hint"))
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

public enum QuizDecoder {
    /// Decode a quiz file. Throws `DecodingError` with a readable description on malformed input.
    public static func decode(_ data: Data) throws -> QuizPayload {
        try JSONDecoder().decode(QuizFile.self, from: data).quiz
    }

    /// Pretty-printed, sorted-key JSON for export.
    public static func encode(_ payload: QuizPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(QuizFile(quiz: payload))
    }
}
