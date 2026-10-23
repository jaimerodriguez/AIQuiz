import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

private let card = CardPayload(prompt: "Who succeeded Augustus?", longAnswer: "Tiberius, his stepson, ruled 14-37 AD.", shortAnswer: "Tiberius", hint: "Capri")

private func cards(_ n: Int) -> [CardPayload] {
    (0..<n).map { CardPayload(prompt: "Q\($0)?", longAnswer: "Answer \($0).", shortAnswer: "A\($0)") }
}

@Suite("Card AI use cases with FakeLLMClient (F-16, F-23..F-29, F-44)")
struct CardAITests {
    @Test("explain and why-wrong send the card and return the explanation")
    func explain() async throws {
        let client = FakeLLMClient.scripted([#"{"explanation":"Tiberius followed because Augustus adopted him."}"#, #"{"explanation":"You named Caligula; it was Tiberius."}"#])
        #expect(try await Explainer.explain(card, quizName: "Rome", using: client) == "Tiberius followed because Augustus adopted him.")
        #expect(try await Explainer.whyWrong(card, answer: "Caligula", using: client) == "You named Caligula; it was Tiberius.")
        let requests = client.recorder.requests
        #expect(requests[0].responseFormat?.name == "explain")
        #expect(requests[0].messages[0].text.contains("Quiz: Rome"))
        #expect(requests[0].messages[0].text.contains("Long answer: Tiberius"))
        #expect(requests[0].effort == .low)
        #expect(requests[1].responseFormat?.name == "whyWrong")
        #expect(requests[1].messages[0].text.contains("Learner's answer: Caligula"))
    }

    @Test("an empty explanation is retried, then malformed twice fails")
    func schemaViolation() async throws {
        let client = FakeLLMClient.scripted([#"{"explanation":"  "}"#, #"{"explanation":"Fine."}"#])
        #expect(try await Explainer.explain(card, quizName: nil, using: client) == "Fine.")
        #expect(client.recorder.requests[1].messages[0].text.contains("explanation is empty"))

        let bad = FakeLLMClient.scripted([#"{"wrong":"shape"}"#, "not json"])
        await #expect(throws: LLMError.self) { _ = try await MnemonicGenerator.mnemonic(for: card, using: bad) }
    }

    @Test("hints build on the ones already shown")
    func hints() async throws {
        let client = FakeLLMClient.scripted([#"{"hint":"His name starts with T."}"#])
        #expect(try await HintGenerator.nextHint(for: card, previous: ["Capri", "Stepson"], using: client) == "His name starts with T.")
        let text = client.recorder.requests[0].messages[0].text
        #expect(text.contains("1. Capri"))
        #expect(text.contains("2. Stepson"))
        #expect(text.contains("Write hint 3"))
    }

    @Test("mnemonic and recap")
    func mnemonicAndRecap() async throws {
        let client = FakeLLMClient.scripted([#"{"mnemonic":"Tiberius Takes over."}"#, #"{"recap":"You knew the early emperors. Revisit Nero's dates."}"#])
        #expect(try await MnemonicGenerator.mnemonic(for: card, using: client) == "Tiberius Takes over.")
        let recap = try await SessionRecapper.recap(quizName: "Rome", results: [(card, .correct), (cards(1)[0], .wrong)], using: client)
        #expect(recap.hasPrefix("You knew"))
        #expect(client.recorder.requests[1].messages[0].text.contains("[wrong] Q0?"))
    }

    @Test("difficulty is batched by 20, clamped to 1-5, and skips unknown indices")
    func difficulty() async throws {
        let client = FakeLLMClient(endpoint: .fake()) { request in
            let count = request.messages[0].text.components(separatedBy: "\nCard ").count
            let ratings = (0..<count).map { #"{"index":\#($0),"difficulty":\#($0 == 0 ? 9 : 3)}"# } + [#"{"index":99,"difficulty":2}"#]
            return #"{"ratings":["# + ratings.joined(separator: ",") + "]}"
        }
        let result = try await DifficultyRater.rate(cards(45), using: client)
        #expect(client.recorder.count == 3, "45 cards → 3 batches")
        #expect(result.count == 45)
        #expect(result[0] == 5, "9 is clamped to 5")
        #expect(result[1] == 3)
        #expect(result[20] == 5, "index 0 of the second batch maps to card 20")
        #expect(result.allSatisfy { $0 != nil })
    }

    @Test("expand returns valid cards and retries when a card breaks the rules")
    func expand() async throws {
        let good = #"{"cards":[{"prompt":"Who was Livia?","long_answer":"Augustus's wife and Tiberius's mother.","short_answer":null,"hint":null},{"prompt":"Where did Tiberius retire?","long_answer":"To Capri.","short_answer":"Capri","hint":null},{"prompt":"When did Tiberius die?","long_answer":"In 37 AD.","short_answer":"37 AD","hint":null}]}"#
        let client = FakeLLMClient.scripted([#"{"cards":[{"prompt":"","long_answer":"x","short_answer":null,"hint":null}]}"#, good])
        let added = try await CardExpander.expand(card, quizName: "Rome", existingPrompts: ["Who was Nero?"], using: client)
        #expect(added.count == 3)
        #expect(added[1].shortAnswer == "Capri")
        #expect(client.recorder.requests[0].messages[0].text.contains("- Who was Nero?"))
        #expect(client.recorder.requests[1].messages[0].text.contains("the prompt is empty"))
        #expect(client.recorder.requests[0].responseFormat?.name == "expand")
    }

    @Test("rewrite keeps kind and extras, and falls back to recall when a choice card breaks")
    func rewrite() async throws {
        let client = FakeLLMClient.scripted([#"{"card":{"prompt":"Who came after Augustus?","long_answer":"Tiberius.","short_answer":"Tiberius","hint":null}}"#])
        var source = card
        source.mnemonic = "T after A"
        let rewritten = try await CardRewriter.rewrite(source, .shorten, using: client)
        #expect(rewritten.prompt == "Who came after Augustus?")
        #expect(rewritten.mnemonic == "T after A", "fields the rewrite doesn't cover are kept")
        #expect(client.recorder.requests[0].messages[0].text.contains("Instruction: Make it shorter"))

        let mcq = CardPayload(prompt: "Pick", longAnswer: "B.", shortAnswer: "B", kind: .multipleChoice, options: ["A", "B"])
        let client2 = FakeLLMClient.scripted([#"{"card":{"prompt":"Pick one","long_answer":"C is right.","short_answer":"C","hint":null}}"#])
        let broken = try await CardRewriter.rewrite(mcq, .translate("Spanish"), using: client2)
        #expect(broken.kind == .recall, "an answer outside the options would break D-2")
        #expect(broken.options == nil)
        #expect(client2.recorder.requests[0].messages[0].text.contains("into Spanish"))
    }

    @Test("lint maps batch indices, drops unknown kinds and invalid fixes")
    func lint() async throws {
        let client = FakeLLMClient(endpoint: .fake()) { request in
            if request.messages[0].text.contains("Q40?") {
                return #"{"issues":[{"index":0,"severity":"error","kind":"answerMismatch","message":"Short and long disagree.","suggested_fix":{"prompt":"Q40?","long_answer":"Answer 40.","short_answer":"Answer 40","hint":null}}]}"#
            }
            return #"{"issues":[{"index":1,"severity":"warn","kind":"leakyHint","message":"The hint says it.","suggested_fix":{"prompt":"","long_answer":"x","short_answer":null,"hint":null}},{"index":2,"severity":"warn","kind":"spelling","message":"?","suggested_fix":null},{"index":77,"severity":"warn","kind":"tooLong","message":"?","suggested_fix":null}]}"#
        }
        let issues = try await CardLinter.lint(cards(45), using: client)
        #expect(client.recorder.count == 2, "45 cards → 2 batches of 40")
        #expect(issues.count == 2)
        #expect(issues[0].index == 1)
        #expect(issues[0].kind == .leakyHint)
        #expect(issues[0].suggestedFix == nil, "a fix with an empty prompt is discarded")
        #expect(issues[1].index == 40, "second batch offsets its indices")
        #expect(issues[1].severity == .error)
        #expect(issues[1].suggestedFix?.shortAnswer == "Answer 40")
    }

    @Test("every schema is strict-mode shaped")
    func schemas() {
        for schema in [Explainer.schema, HintGenerator.schema, MnemonicGenerator.schema, DifficultyRater.schema, CardExpander.schema, CardRewriter.schema, CardLinter.schema, SessionRecapper.schema] {
            let text = schema.jsonValue.encodedString(pretty: false)
            #expect(text.contains("\"additionalProperties\":false"))
            #expect(!text.contains("minItems"))
        }
    }
}

@Suite("Outcomes and hints (F-15, F-24)")
@MainActor
struct OutcomeAndHintTests {
    @Test("old outcomes decode without AI fields")
    func oldOutcome() throws {
        let id = UUID()
        let old = try JSONDecoder().decode([CardOutcome].self, from: Data(#"[{"cardId":"\#(id.uuidString)","verdict":"wrong"}]"#.utf8))
        #expect(old == [CardOutcome(cardId: id, verdict: .wrong)])
        #expect(!old[0].userOverrode)
    }

    @Test("progressive hints: author's first, then AI hints, then hide")
    func progressive() {
        var p = HintProgress(hints: CardSnapshot(id: UUID(), prompt: "p", longAnswer: "l", hint: "Capri", aiHints: ["Stepson", "Starts with T"]).hints)
        #expect(p.buttonLabel == "Hint")
        let first = p.advance()
        #expect(first)
        #expect(p.shown == ["Capri"])
        #expect(p.buttonLabel == "Another hint")
        p.advance(); p.advance()
        #expect(p.shown == ["Capri", "Stepson", "Starts with T"])
        #expect(p.buttonLabel == "Hide hints")
        let afterLast = p.advance()
        #expect(!afterLast)
        #expect(p.shown.isEmpty)
        #expect(!HintProgress(hints: []).isAvailable)
    }
}
