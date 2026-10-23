import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

@Suite("Cloze (D-2)")
struct ClozeTests {
    @Test("segments, blanks and expected answers")
    func parsing() {
        let prompt = "Rome was founded in {{blank}} BC by {{blank}}."
        #expect(Cloze.blankCount(prompt) == 2)
        #expect(Cloze.segments(prompt) == ["Rome was founded in ", " BC by ", "."])
        #expect(Cloze.expected("753 | Romulus", blanks: 2) == ["753", "Romulus"])
        #expect(Cloze.expected("Romulus", blanks: 2) == ["Romulus", "Romulus"], "one answer fills every blank")
        #expect(Cloze.filled(prompt, with: ["753", "Romulus"]) == "Rome was founded in [753] BC by [Romulus].")
    }

    @Test("comparison ignores case and spacing, not spelling")
    func comparison() {
        #expect(Cloze.matches(["  753", "ROMULUS "], expected: ["753", "Romulus"]))
        #expect(Cloze.matches(["new   york"], expected: ["New York"]))
        #expect(!Cloze.matches(["Remus"], expected: ["Romulus"]))
        #expect(!Cloze.matches(["753"], expected: ["753", "Romulus"]), "every blank must be filled")
    }
}

@MainActor
private func mixedDeck() -> SessionDeck {
    SessionDeck(cards: [
        CardSnapshot(id: UUID(), prompt: "Who succeeded Augustus?", longAnswer: "Tiberius.", shortAnswer: "Tiberius", kind: .multipleChoice, options: ["Nero", "Tiberius", "Caligula"]),
        CardSnapshot(id: UUID(), prompt: "Rome was founded in {{blank}} BC.", longAnswer: "753 BC.", shortAnswer: "753", kind: .cloze),
        CardSnapshot(id: UUID(), prompt: "Nero was the first emperor.", longAnswer: "False; Augustus was.", shortAnswer: "false", kind: .trueFalse),
        CardSnapshot(id: UUID(), prompt: "Why did Rome fall?", longAnswer: "Many causes.", kind: .recall)
    ])
}

@Suite("ChoicePlayer (F-17)")
@MainActor
struct ChoicePlayerTests {
    @Test("multiple choice: options shuffled once, right is Correct, wrong is Wrong")
    func multipleChoice() {
        let player = ChoicePlayer(deck: mixedDeck(), generator: SeededGenerator(seed: 7))
        #expect(Set(player.shownOptions) == ["Nero", "Tiberius", "Caligula"])
        let order = player.shownOptions
        #expect(player.rightAnswer == "Tiberius")
        player.choose("Nero")
        #expect(player.stage == .checked)
        #expect(player.verdict == .wrong)
        #expect(player.chosen == "Nero")
        player.choose("Tiberius")
        #expect(player.verdict == .wrong, "one answer per card")
        #expect(player.shownOptions == order)
        player.next()
        #expect(player.deck.counts.wrong == 1)
    }

    @Test("fill in the blank checks every blank, ignoring case")
    func cloze() {
        let player = ChoicePlayer(deck: mixedDeck())
        player.choose("Tiberius")
        player.next()
        #expect(player.card?.kind == .cloze)
        #expect(player.blankAnswers.count == 1)
        player.blankAnswers = [" 753 "]
        player.checkBlanks()
        #expect(player.verdict == .correct)
        player.next()
        #expect(player.deck.counts.correct == 2)
    }

    @Test("true or false, and an override to Partial is recorded")
    func trueFalseAndOverride() {
        let player = ChoicePlayer(deck: mixedDeck())
        player.choose("Tiberius"); player.next()
        player.blankAnswers = ["754"]; player.checkBlanks()
        #expect(player.verdict == .wrong)
        player.override(.partial)
        #expect(player.verdict == .partial)
        #expect(player.overridden)
        player.next()
        #expect(player.shownOptions == ["True", "False"])
        player.choose("True")
        #expect(player.verdict == .wrong, "the statement is false")
        player.override(.wrong)
        #expect(!player.overridden, "choosing the same verdict is not an override")
        player.next()
        #expect(player.deck.counts.partial == 1)
    }

    @Test("recall cards flip and need a self-grade; the deck ends after the last card")
    func recallAndEnd() {
        let player = ChoicePlayer(deck: mixedDeck())
        player.choose("Tiberius"); player.next()
        player.blankAnswers = ["753"]; player.checkBlanks(); player.next()
        player.choose("False"); player.next()
        #expect(player.card?.kind == .recall)
        player.next()
        #expect(player.card?.kind == .recall, "no grade yet, so no move")
        player.reveal()
        player.next()
        #expect(player.card?.kind == .recall, "a recall card needs a grade")
        player.override(.correct)
        player.next()
        #expect(player.stage == .ended)
        #expect(player.deck.counts.correct == 4)
        #expect(player.deck.scorePercent == 1.0)
    }

    @Test("abandon discards")
    func abandon() {
        let player = ChoicePlayer(deck: mixedDeck())
        player.abandon()
        #expect(player.stage == .ended)
        #expect(player.deck.abandoned)
    }
}

@Suite("Generating card kinds (F-19, D-2)")
struct GeneratingKindsTests {
    static let mixed = #"{"quiz":{"name":"Rome","cards":[{"prompt":"Who succeeded Augustus?","long_answer":"Tiberius.","short_answer":"Tiberius","hint":null,"kind":"multipleChoice","options":["Nero","Tiberius"]},{"prompt":"Rome was founded in {{blank}} BC.","long_answer":"753 BC.","short_answer":"753","hint":null,"kind":"cloze","options":null},{"prompt":"Nero was first.","long_answer":"No.","short_answer":"false","hint":null,"kind":"trueFalse","options":null}]}}"#

    @Test("requested kinds reach the prompt and the schema carries kind and options")
    func promptAndSchema() async throws {
        let client = FakeLLMClient.scripted([Self.mixed])
        var request = QuizGenRequest(source: .topic, topic: "Rome", cardCount: 3)
        request.kinds = [.recall, .multipleChoice, .cloze, .trueFalse]
        let quiz = try await QuizGenerator.generate(request, using: client)
        #expect(quiz.cards.map(\.kind) == [.multipleChoice, .cloze, .trueFalse])
        let text = client.recorder.requests[0].messages[0].text
        #expect(text.contains("- multipleChoice:"))
        #expect(text.contains("- cloze:"))
        #expect(text.contains("- trueFalse:"))
        let schema = QuizGenerator.schema.jsonValue.encodedString(pretty: false)
        #expect(schema.contains("\"kind\""))
        #expect(schema.contains("multipleChoice"))
    }

    @Test("recall only by default")
    func recallOnly() async throws {
        let client = FakeLLMClient.scripted([#"{"quiz":{"name":"R","cards":[{"prompt":"Q?","long_answer":"A.","short_answer":null,"hint":null,"kind":"recall","options":null}]}}"#])
        _ = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "Rome"), using: client)
        #expect(client.recorder.requests[0].messages[0].text.contains("use \"recall\" for every card"))
    }

    @Test("a multiple-choice answer outside its options, or an unrequested kind, is retried")
    func validation() async throws {
        let badMCQ = #"{"quiz":{"name":"R","cards":[{"prompt":"Pick","long_answer":"C.","short_answer":"C","hint":null,"kind":"multipleChoice","options":["A","B"]}]}}"#
        let client = FakeLLMClient.scripted([badMCQ, Self.mixed])
        var request = QuizGenRequest(source: .topic, topic: "Rome")
        request.kinds = [.multipleChoice, .cloze, .trueFalse]
        let quiz = try await QuizGenerator.generate(request, using: client)
        #expect(quiz.cards.count == 3)
        #expect(client.recorder.requests[1].messages[0].text.contains("must be one of its options"))

        let unrequested = FakeLLMClient.scripted([Self.mixed, #"{"quiz":{"name":"R","cards":[{"prompt":"Q?","long_answer":"A.","short_answer":null,"hint":null,"kind":"recall","options":null}]}}"#])
        _ = try await QuizGenerator.generate(QuizGenRequest(source: .topic, topic: "Rome"), using: unrequested)
        #expect(unrequested.recorder.requests[1].messages[0].text.contains("which wasn't requested"))
    }

    @Test("convert a card into multiple choice")
    func convert() async throws {
        let client = FakeLLMClient.scripted([#"{"card":{"prompt":"Who succeeded Augustus?","long_answer":"Tiberius.","short_answer":"Tiberius","hint":null,"kind":"multipleChoice","options":["Tiberius","Nero","Claudius"]}}"#])
        let card = CardPayload(prompt: "Who succeeded Augustus?", longAnswer: "Tiberius.", shortAnswer: "Tiberius", mnemonic: "T")
        let converted = try await CardRewriter.rewrite(card, .convert(.multipleChoice), using: client)
        #expect(converted.kind == .multipleChoice)
        #expect(converted.options == ["Tiberius", "Nero", "Claudius"])
        #expect(converted.mnemonic == "T")
        #expect(client.recorder.requests[0].responseFormat?.name == "convert")
        #expect(client.recorder.requests[0].messages[0].text.contains("Turn it into a multipleChoice card"))
    }
}
