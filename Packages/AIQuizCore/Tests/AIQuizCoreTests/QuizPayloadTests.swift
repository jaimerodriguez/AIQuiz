import Foundation
import Testing
@testable import AIQuizCore

@Suite("QuizPayload decoding and encoding")
struct QuizPayloadTests {
    @Test("underscore keys decode")
    func underscoreKeys() throws {
        let json = """
        {"quiz":{"name":"T","cards":[{"prompt":"p","long_answer":"l","short_answer":"s","hint":"h"}]}}
        """
        let quiz = try QuizDecoder.decode(Data(json.utf8))
        #expect(quiz.name == "T")
        #expect(quiz.cards.count == 1)
        #expect(quiz.cards[0].prompt == "p")
        #expect(quiz.cards[0].longAnswer == "l")
        #expect(quiz.cards[0].shortAnswer == "s")
        #expect(quiz.cards[0].hint == "h")
    }

    @Test("hyphen keys decode")
    func hyphenKeys() throws {
        let json = """
        {"quiz":{"name":"T","cards":[{"prompt":"p","long-answer":"l","short-answer":"s"}]}}
        """
        let quiz = try QuizDecoder.decode(Data(json.utf8))
        #expect(quiz.cards[0].longAnswer == "l")
        #expect(quiz.cards[0].shortAnswer == "s")
        #expect(quiz.cards[0].hint == nil)
    }

    @Test("missing long_answer is an error naming the key")
    func missingLongAnswer() {
        let json = """
        {"quiz":{"name":"T","cards":[{"prompt":"p"}]}}
        """
        #expect(throws: DecodingError.self) {
            _ = try QuizDecoder.decode(Data(json.utf8))
        }
    }

    @Test("missing prompt is an error")
    func missingPrompt() {
        let json = """
        {"quiz":{"name":"T","cards":[{"long_answer":"l"}]}}
        """
        #expect(throws: DecodingError.self) {
            _ = try QuizDecoder.decode(Data(json.utf8))
        }
    }

    @Test("unknown keys such as score are ignored")
    func extraKeysIgnored() throws {
        let json = """
        {"quiz":{"name":"T","score":{"best":100,"average":50},"cards":[{"prompt":"p","long_answer":"l","extra":1}]}}
        """
        let quiz = try QuizDecoder.decode(Data(json.utf8))
        #expect(quiz.cards.count == 1)
    }

    @Test("encode writes underscore keys and omits nil optionals")
    func encodeStyle() throws {
        let payload = QuizPayload(name: "T", cards: [CardPayload(prompt: "p", longAnswer: "l")])
        let data = try QuizDecoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"long_answer\""))
        #expect(!text.contains("long-answer"))
        #expect(!text.contains("short_answer"))
        #expect(!text.contains("hint"))
    }

    @Test("round trip preserves content")
    func roundTrip() throws {
        let payload = QuizPayload(name: "Round", cards: [
            CardPayload(prompt: "p1", longAnswer: "l1", shortAnswer: "s1", hint: "h1"),
            CardPayload(prompt: "p2", longAnswer: "l2")
        ])
        let data = try QuizDecoder.encode(payload)
        let back = try QuizDecoder.decode(data)
        #expect(back == payload)
    }
}
