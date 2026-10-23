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

@Suite("Quiz file format v2 (SPEC §2)")
struct QuizFormatV2Tests {
    @Test("round trip keeps every new field")
    func roundTrip() throws {
        let payload = QuizPayload(
            name: "Roman Emperors",
            description: "Who ruled when.",
            tags: ["history", "rome"],
            language: "en",
            cards: [
                CardPayload(prompt: "Who succeeded Augustus?", longAnswer: "Tiberius, 14–37 AD.", shortAnswer: "Tiberius", hint: "Capri",
                            kind: .multipleChoice, options: ["Tiberius", "Caligula", "Nero"], explanation: "Stepson.", mnemonic: "T follows A"),
                CardPayload(prompt: "Rome fell in {{blank}} AD", longAnswer: "476 in the West.", shortAnswer: "476", kind: .cloze),
                CardPayload(prompt: "Nero was emperor.", longAnswer: "Yes, 54–68 AD.", shortAnswer: "true", kind: .trueFalse)
            ]
        )
        let data = try QuizDecoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"long_answer\""), "always writes underscore keys")
        #expect(!text.contains("long-answer"))
        #expect(try QuizDecoder.decode(data) == payload)
    }

    @Test("recall cards and empty tags are not written")
    func compactEncoding() throws {
        let data = try QuizDecoder.encode(QuizPayload(name: "T", cards: [CardPayload(prompt: "p", longAnswer: "l")]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("kind"))
        #expect(!text.contains("tags"))
    }

    @Test("v1 files without the new fields still decode")
    func v1File() throws {
        let quiz = try QuizDecoder.decode(Data(#"{"quiz":{"name":"T","cards":[{"prompt":"p","long-answer":"l"}]}}"#.utf8))
        #expect(quiz.tags == [])
        #expect(quiz.description == nil)
        #expect(quiz.cards[0].kind == .recall)
    }

    @Test("a multiple-choice card without options is an error naming the card")
    func mcqWithoutOptions() {
        let json = #"{"quiz":{"name":"T","cards":[{"prompt":"a","long_answer":"b"},{"prompt":"Pick","long_answer":"x","kind":"multipleChoice","short_answer":"x"}]}}"#
        #expect(throws: CardValidationError(cardNumber: 2, problem: "a multiple-choice card needs 2 to 6 options; it has 0.")) {
            _ = try QuizDecoder.decode(Data(json.utf8))
        }
        let error = CardValidationError(cardNumber: 2, problem: "a multiple-choice card needs 2 to 6 options; it has 0.")
        #expect(error.localizedDescription == "Card 2: a multiple-choice card needs 2 to 6 options; it has 0.")
    }

    @Test("multiple-choice answer must be an option; cloze needs a blank; true/false needs true or false")
    func kindRules() {
        #expect(CardValidator.problem(with: CardPayload(prompt: "p", longAnswer: "l", shortAnswer: "z", kind: .multipleChoice, options: ["a", "b"])) != nil)
        #expect(CardValidator.problem(with: CardPayload(prompt: "p", longAnswer: "l", shortAnswer: "a", kind: .multipleChoice, options: ["a", "b"])) == nil)
        #expect(CardValidator.problem(with: CardPayload(prompt: "no blank", longAnswer: "l", shortAnswer: "x", kind: .cloze)) != nil)
        #expect(CardValidator.problem(with: CardPayload(prompt: "p", longAnswer: "l", shortAnswer: "maybe", kind: .trueFalse)) != nil)
        #expect(CardValidator.problem(with: CardPayload(prompt: "p", longAnswer: "l", shortAnswer: "False", kind: .trueFalse)) == nil)
    }

    @Test("an unknown kind is a decoding error")
    func unknownKind() {
        #expect(throws: DecodingError.self) {
            _ = try QuizDecoder.decode(Data(#"{"quiz":{"name":"T","cards":[{"prompt":"p","long_answer":"l","kind":"essay"}]}}"#.utf8))
        }
    }

    @Test("tag search text and tag parsing")
    func tagsSearch() {
        #expect(TagsSearch.make(name: "Roman Emperors", tags: ["History", "ancient rome"]) == " roman emperors #history #ancient-rome ")
        #expect(TagsSearch.needle(forTag: "#History") == " #history ")
        #expect(TagsSearch.parse("rome, History #latin rome") == ["rome", "History", "latin"])
        #expect(TagsSearch.clean(["#Ancient Rome", " ", "ancient-rome", "art"]) == ["Ancient-Rome", "art"])
    }
}

@Suite("Stored quiz counters (SPEC D-11)")
struct QuizCountersTests {
    @Test("counts, scores, due cards and last studied")
    func compute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let counters = QuizCounters.compute(
            cardDueDates: [nil, now.addingTimeInterval(-60), now.addingTimeInterval(3600)],
            sessions: [
                .init(abandoned: false, scorePercent: 0.5, startedAt: now.addingTimeInterval(-500), endedAt: now.addingTimeInterval(-400)),
                .init(abandoned: false, scorePercent: 1.0, startedAt: now.addingTimeInterval(-300), endedAt: nil),
                .init(abandoned: true, scorePercent: 0.0, startedAt: now.addingTimeInterval(-10), endedAt: now)
            ],
            now: now
        )
        #expect(counters == QuizCounters(cardCount: 3, sessionCount: 2, bestScore: 1.0, averageScore: 0.75, dueCount: 2,
                                         lastStudiedAt: now.addingTimeInterval(-300)))
    }

    @Test("an empty quiz has zero counts and no scores")
    func empty() {
        #expect(QuizCounters.compute(cardDueDates: [], sessions: [], now: .now) == QuizCounters())
    }
}
