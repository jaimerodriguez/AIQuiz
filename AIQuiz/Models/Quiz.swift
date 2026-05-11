import Foundation

struct QuizFile: Codable {
    let quiz: QuizPayload
}

struct QuizPayload: Codable {
    let name: String
    let cards: [CardPayload]
}

struct CardPayload: Codable {
    let prompt: String
    let longAnswer: String
    let shortAnswer: String?
    let hint: String?

    init(prompt: String, longAnswer: String, shortAnswer: String? = nil, hint: String? = nil) {
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum QuizDecoder {
    static func decode(_ data: Data) throws -> QuizPayload {
        let decoder = JSONDecoder()
        let file = try decoder.decode(QuizFile.self, from: data)
        return file.quiz
    }
}
