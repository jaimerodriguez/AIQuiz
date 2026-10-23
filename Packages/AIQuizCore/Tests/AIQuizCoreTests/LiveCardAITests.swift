import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

/// Opt-in: the Phase 4 features against real APIs (PLAN §1.6), so their strict schemas and
/// prompts are proven on Anthropic and OpenAI. Run with `scripts/live-test.sh`, which reads
/// the keys from the Keychain. Spends a few cents.
private let env = ProcessInfo.processInfo.environment
private let liveEnabled = env["AIQUIZ_LIVE_TESTS"] == "1"

private func liveClients() -> [LLMClient] {
    var clients: [LLMClient] = []
    if let key = env["AIQuiz_Ant_test_key"], !key.isEmpty {
        let model = env["AIQuiz_Ant_test_model"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5"
        clients.append(AnthropicClient(endpoint: LLMEndpoint(kind: .anthropic, name: "Anthropic", model: model, contextWindowTokens: 1_000_000), apiKey: key))
    }
    if let key = env["AIQuiz_Oai_test_key"], !key.isEmpty, let model = env["AIQuiz_Oai_test_model"], !model.isEmpty {
        clients.append(OpenAICompatibleClient(
            endpoint: LLMEndpoint(kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1"), model: model, contextWindowTokens: 128_000),
            apiKey: key
        ))
    }
    return clients
}

private let tiberius = CardPayload(prompt: "Who succeeded Augustus as Roman emperor?", longAnswer: "Tiberius, Augustus's stepson and adopted heir, ruled from 14 to 37 AD.", shortAnswer: "Tiberius", hint: "He later retired to Capri.")
private let deck = [
    tiberius,
    CardPayload(prompt: "Who was the first Roman emperor?", longAnswer: "Augustus, from 27 BC.", shortAnswer: "Augustus"),
    CardPayload(prompt: "Which emperor is famous?", longAnswer: "Nero fiddled while Rome burned; it is a legend.", shortAnswer: "Caligula", hint: "Nero"),
    CardPayload(prompt: "Who was the first emperor of Rome?", longAnswer: "Augustus became the first emperor in 27 BC.", shortAnswer: "Augustus")
]

@Suite("Live card AI (Phase 4)", .enabled(if: liveEnabled))
struct LiveCardAITests {
    @Test("judge, explain, why-wrong, hint, mnemonic, difficulty, expand, rewrite, lint and recap")
    func everyFeature() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty, "set AIQuiz_Ant_test_key and/or AIQuiz_Oai_test_key + AIQuiz_Oai_test_model")
        for client in clients {
            let name = client.endpoint.name
            let wrong = try await AnswerJudge.judge(JudgeRequest(prompt: tiberius.prompt, userAnswer: "Caligula", correctShort: "Tiberius", correctLong: tiberius.longAnswer), using: client)
            #expect(wrong.verdict == .wrong, "\(name) judged Caligula \(wrong.verdict): \(wrong.reason)")

            let explanation = try await Explainer.explain(tiberius, quizName: "Roman emperors", using: client)
            #expect(explanation.count > 40, "\(name) explain: \(explanation)")
            let why = try await Explainer.whyWrong(tiberius, answer: "Caligula", using: client)
            #expect(why.localizedCaseInsensitiveContains("tiberius"), "\(name) why-wrong: \(why)")

            let hint = try await HintGenerator.nextHint(for: tiberius, previous: ["He later retired to Capri."], using: client)
            #expect(!hint.isEmpty, "\(name) hint")
            let mnemonic = try await MnemonicGenerator.mnemonic(for: tiberius, using: client)
            #expect(!mnemonic.isEmpty, "\(name) mnemonic")

            let ratings = try await DifficultyRater.rate(deck, using: client)
            #expect(ratings.compactMap { $0 }.count == deck.count, "\(name) rated \(ratings)")

            let expanded = try await CardExpander.expand(tiberius, quizName: "Roman emperors", existingPrompts: deck.map(\.prompt), using: client)
            #expect((3...5).contains(expanded.count), "\(name) expanded to \(expanded.count)")

            let simpler = try await CardRewriter.rewrite(tiberius, .translate("Spanish"), using: client)
            #expect(simpler.longAnswer != tiberius.longAnswer, "\(name) rewrite")

            let issues = try await CardLinter.lint(deck, using: client)
            #expect(issues.contains { $0.index == 2 }, "\(name) lint should flag the mismatched card 2: \(issues.map { "\($0.index) \($0.kind)" })")
            #expect(issues.contains { $0.index == 3 || $0.index == 1 }, "\(name) lint should flag the duplicate: \(issues.map { "\($0.index) \($0.kind)" })")

            let recap = try await SessionRecapper.recap(quizName: "Roman emperors", results: [(tiberius, .wrong), (deck[1], .correct)], using: client)
            #expect(!recap.isEmpty, "\(name) recap")
            print("LIVE \(name): judge=\(wrong.verdict) ratings=\(ratings) expanded=\(expanded.count) lint=\(issues.map { "\($0.index):\($0.kind.rawValue)" })")
        }
    }

    @Test("reader mode on a real Wikipedia page, then a quiz from the article (Phase 5)")
    func realPage() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        var request = URLRequest(url: URL(string: "https://en.wikipedia.org/wiki/Tiberius")!)
        request.setValue(ReaderModeExtractor.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let html = ReaderModeExtractor.decode(data, contentType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
        let article = try ReaderModeExtractor.extract(html: html)
        #expect(article.text.contains("Tiberius"))
        #expect(article.text.count > 5_000, "the whole article: \(article.text.count) characters")
        #expect(!article.text.contains("Jump to content"), "navigation is dropped")
        print("LIVE reader mode: \(article.title ?? "-"), \(article.text.count) characters")
        for client in clients {
            let quiz = try await QuizGenerator.generateFromSource(QuizGenRequest(source: .article, topic: article.title ?? "Tiberius", sourceContent: article.text), using: client)
            #expect(quiz.cards.count >= 5, "\(client.endpoint.name) made \(quiz.cards.count) cards")
            print("LIVE \(client.endpoint.name) quiz from the page: \(quiz.name), \(quiz.cards.count) cards")
        }
    }

    @Test("a mixed-kind quiz and a conversion (Phase 6)")
    func mixedKinds() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        for client in clients {
            var request = QuizGenRequest(source: .topic, topic: "Roman emperors", cardCount: 8, difficulty: "intermediate", language: "en", tone: "formal")
            request.kinds = [.recall, .multipleChoice, .cloze, .trueFalse]
            let quiz = try await QuizGenerator.generate(request, using: client)
            let kinds = Set(quiz.cards.map(\.kind))
            #expect(kinds.count >= 3, "\(client.endpoint.name) used kinds \(kinds)")
            #expect(quiz.cards.allSatisfy { CardValidator.problem(with: $0) == nil }, "every card follows D-2")
            let converted = try await CardRewriter.rewrite(tiberius, .convert(.multipleChoice), using: client)
            #expect(converted.kind == .multipleChoice && converted.options?.contains(converted.shortAnswer ?? "") == true)
            print("LIVE \(client.endpoint.name) mixed quiz: \(quiz.cards.map(\.kind.rawValue)); converted options \(converted.options ?? [])")
        }
    }

    @Test("an insights report from a small history (Phase 7)")
    func insights() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        let cards = deck.enumerated().map { InsightsQuiz.Card(id: UUID(), prompt: $0.element.prompt, correct: 2, partial: $0.offset == 2 ? 2 : 0, wrong: $0.offset == 2 ? 3 : 0, lapses: $0.offset == 2 ? 2 : 0) }
        let history = [InsightsQuiz(name: "Roman emperors", sessions: (0..<4).map { .init(date: Date(timeIntervalSinceNow: Double(-$0) * 86_400), mode: "quizVoice", score: 0.6 + Double($0) * 0.05) }, cards: cards)]
        for client in clients {
            let report = try await InsightsReporter.report(history, using: client)
            #expect(!report.headline.isEmpty)
            #expect(!report.drillCards.isEmpty, "\(client.endpoint.name) wrote drill cards")
            #expect(report.confusions.contains { $0.cardIds.contains(cards[2].id) }, "\(client.endpoint.name) points at the troublesome card")
            print("LIVE \(client.endpoint.name) insights: \(report.headline) — \(report.drillCards.count) drill cards")
        }
    }

    @Test("tutor chat streams a reply and makes cards from it (Phase 8)")
    @MainActor
    func tutorChat() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        for client in clients {
            let chat = TutorChat(context: TutorContext(quizName: "Roman emperors", description: "The first emperors of Rome", card: tiberius))
            var updates = 0
            let watcher = Task { @MainActor in
                var last = ""
                while !Task.isCancelled {
                    let text = chat.messages.last?.text ?? ""
                    if text != last { updates += 1; last = text }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await chat.send("Explain this card", using: client)
            watcher.cancel()
            #expect(chat.error == nil, "\(client.endpoint.name): \(chat.error ?? "")")
            let reply = chat.messages.last?.text ?? ""
            #expect(chat.messages.last?.role == .assistant)
            #expect(reply.localizedCaseInsensitiveContains("Tiberius"), "\(client.endpoint.name) talks about the card")
            let cards = try await chat.makeCards(existingPrompts: deck.map(\.prompt), using: client)
            #expect((1...6).contains(cards.count))
            print("LIVE \(client.endpoint.name) tutor: \(reply.count) chars in \(updates) visible updates; \(cards.count) cards: \(cards.map(\.prompt))")
        }
    }

    @Test("oral exam: follow-up decisions and the final grading (Phase 8)")
    func oralExam() async throws {
        let clients = liveClients()
        try #require(!clients.isEmpty)
        let card = CardSnapshot(id: UUID(), prompt: tiberius.prompt, longAnswer: tiberius.longAnswer, shortAnswer: tiberius.shortAnswer)
        let first = CardSnapshot(id: UUID(), prompt: "Who was the first Roman emperor?", longAnswer: "Augustus, from 27 BC.", shortAnswer: "Augustus")
        for client in clients {
            let vague = try await OralExaminer.decide(card: card, exchanges: [OralExchange(question: card.prompt, answer: "um it was his son I think, someone in his family")], using: client)
            let good = try await OralExaminer.decide(card: first, exchanges: [OralExchange(question: first.prompt, answer: "That was Augustus, starting in 27 BC")], using: client)
            #expect(!good.say.isEmpty || good.followUp == nil)
            if let followUp = vague.followUp { #expect(!followUp.isEmpty) }
            let result = try await OralExaminer.grade([
                OralExamItem(card: first, exchanges: [OralExchange(question: first.prompt, answer: "That was Augustus, starting in 27 BC")]),
                OralExamItem(card: card, exchanges: [OralExchange(question: card.prompt, answer: "")])
            ], using: client)
            #expect(result.grades[first.id]?.verdict == .correct, "\(client.endpoint.name) grades the right answer correct")
            #expect(result.grades[card.id]?.verdict == .wrong, "\(client.endpoint.name) grades no answer wrong")
            #expect(!result.overall.isEmpty)
            print("LIVE \(client.endpoint.name) oral exam: vague → \(vague.followUp.map { "follow-up \"\($0)\"" } ?? "accept"); good → \(good.followUp == nil ? "accept \"\(good.say)\"" : "follow-up"); overall: \(result.overall)")
        }
    }
}
