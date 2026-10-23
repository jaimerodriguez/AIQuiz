import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

@Suite("Oral examiner: questions, follow-ups and grading (F-45)")
@MainActor
struct OralExaminerTests {
    private let recall = CardSnapshot(id: UUID(), prompt: "What is ATP?", longAnswer: "The cell's energy currency.")

    @Test("the spoken question suits each card kind")
    func questions() {
        #expect(OralExaminer.question(for: recall) == "What is ATP?")
        let cloze = CardSnapshot(id: UUID(), prompt: "The capital of France is {{blank}}.", longAnswer: "Paris.", shortAnswer: "Paris", kind: .cloze)
        #expect(OralExaminer.question(for: cloze) == "Fill in the blank: The capital of France is blank.")
        let tf = CardSnapshot(id: UUID(), prompt: "The sun is a star.", longAnswer: "Yes.", shortAnswer: "true", kind: .trueFalse)
        #expect(OralExaminer.question(for: tf) == "True or false: The sun is a star.")
        let mc = CardSnapshot(id: UUID(), prompt: "Which is a mammal?", longAnswer: "The whale.", shortAnswer: "Whale", kind: .multipleChoice, options: ["Shark", "Whale", "Trout"])
        #expect(OralExaminer.question(for: mc) == "Which is a mammal? Is it Shark, Whale, or Trout?")
    }

    @Test("a follow-up decision carries its question; accept carries the acknowledgement")
    func decide() async throws {
        let recorder = RequestRecorder()
        let client = FakeLLMClient.scripted([.success(#"{"action":"follow_up","say":"Which molecule stores it?"}"#), .success(#"{"action":"accept","say":"Thank you."}"#)], recorder: recorder)
        let exchanges = [OralExchange(question: "What is ATP?", answer: "energy")]
        let first = try await OralExaminer.decide(card: recall, exchanges: exchanges, using: client)
        #expect(first == OralTurnDecision(followUp: "Which molecule stores it?", say: "Which molecule stores it?"))
        let second = try await OralExaminer.decide(card: recall, exchanges: exchanges, using: client)
        #expect(second == OralTurnDecision(followUp: nil, say: "Thank you."))
        let request = try #require(recorder.requests.first)
        #expect(request.responseFormat?.name == "oralExamTurn")
        #expect(request.messages[0].text.contains("Learner: energy"))
        #expect(request.messages[0].text.contains("Long answer: The cell's energy currency."))
    }

    @Test("an unknown action or an empty follow-up is retried")
    func decideValidation() async throws {
        let client = FakeLLMClient.scripted([#"{"action":"maybe","say":"?"}"#, #"{"action":"follow_up","say":"  "}"#])
        await #expect(throws: (any Error).self) {
            try await OralExaminer.decide(card: recall, exchanges: [OralExchange(question: "Q", answer: "A")], using: client)
        }
    }

    @Test("grading maps c1, c2… back to the cards and keeps the overall comment")
    func grade() async throws {
        let second = CardSnapshot(id: UUID(), prompt: "What is DNA?", longAnswer: "Genetic material.")
        let recorder = RequestRecorder()
        let client = FakeLLMClient.scripted([.success(#"{"cards":[{"card_id":"c1","verdict":"correct","reason":"Spot on."},{"card_id":"c2","verdict":"partial","reason":"Missed a part."}],"overall":"Good start. Revisit DNA."}"#)], recorder: recorder)
        let result = try await OralExaminer.grade([
            OralExamItem(card: recall, exchanges: [OralExchange(question: "What is ATP?", answer: "energy currency")]),
            OralExamItem(card: second, exchanges: [OralExchange(question: "What is DNA?", answer: "genes"), OralExchange(question: "Where is it?", answer: "")])
        ], using: client)
        #expect(result.grades[recall.id] == AIGrade(verdict: .correct, reason: "Spot on."))
        #expect(result.grades[second.id] == AIGrade(verdict: .partial, reason: "Missed a part."))
        #expect(result.overall == "Good start. Revisit DNA.")
        let prompt = try #require(recorder.requests.first?.messages.first?.text)
        #expect(prompt.contains("Card c2"))
        #expect(prompt.contains("Learner: (no answer)"))
        #expect(recorder.requests.first?.responseFormat?.name == "oralExamGrade")
    }

    @Test("a grade that leaves a card out is retried")
    func gradeMissingCard() async throws {
        let recorder = RequestRecorder()
        let client = FakeLLMClient.scripted([
            .success(#"{"cards":[],"overall":"x"}"#),
            .success(#"{"cards":[{"card_id":"c1","verdict":"wrong","reason":"Off."}],"overall":"Keep going."}"#)
        ], recorder: recorder)
        let result = try await OralExaminer.grade([OralExamItem(card: recall, exchanges: [OralExchange(question: "Q", answer: "no idea")])], using: client)
        #expect(result.grades[recall.id]?.verdict == .wrong)
        #expect(recorder.count == 2)
        #expect(recorder.requests[1].messages[0].text.contains("missing c1"))
    }
}

@Suite("OralExamPlayer state machine (F-45)")
@MainActor
struct OralExamPlayerTests {
    private func deck(_ n: Int) -> SessionDeck {
        SessionDeck(cards: (0..<n).map { CardSnapshot(id: UUID(), prompt: "P\($0)", longAnswer: "L\($0)") })
    }

    /// Records what the examiner was asked to decide and grade.
    @MainActor
    final class Examiner {
        var decisions: [OralTurnDecision?]
        var decideCalls: [(CardSnapshot, [OralExchange])] = []
        var gradeCalls: [[OralExamItem]] = []
        var gradeError: Error?
        var verdict: CardVerdict = .correct

        init(decisions: [OralTurnDecision?] = []) { self.decisions = decisions }

        func decide(_ card: CardSnapshot, _ exchanges: [OralExchange]) throws -> OralTurnDecision {
            decideCalls.append((card, exchanges))
            let next = decisions.isEmpty ? OralTurnDecision(followUp: nil, say: "") : decisions.removeFirst()
            guard let next else { throw LLMError.server(status: 503) }
            return next
        }

        func grade(_ items: [OralExamItem]) throws -> OralExamResult {
            gradeCalls.append(items)
            if let gradeError { throw gradeError }
            return OralExamResult(grades: Dictionary(uniqueKeysWithValues: items.map { ($0.card.id, AIGrade(verdict: verdict, reason: "R")) }), overall: "Overall.")
        }
    }

    private func player(
        _ deck: SessionDeck,
        examiner: Examiner,
        speech: ScriptedSynthesizer = ScriptedSynthesizer(),
        recognizer: ScriptedRecognizer = ScriptedRecognizer(partial: "my", final: "my answer", delay: .milliseconds(10)),
        audio: AudioSessionCoordinator? = nil
    ) -> OralExamPlayer {
        OralExamPlayer(
            deck: deck, speech: speech, recognizer: recognizer, audio: audio,
            silenceTimeout: .milliseconds(200), noSpeechTimeout: .milliseconds(400),
            decide: { try examiner.decide($0, $1) },
            grade: { try examiner.grade($0) }
        )
    }

    @Test("asks each card, accepts, grades at the end and records the verdicts")
    func acceptsAndGrades() async {
        let examiner = Examiner(decisions: [OralTurnDecision(followUp: nil, say: "Thanks."), OralTurnDecision(followUp: nil, say: "")])
        let speech = ScriptedSynthesizer()
        let p = player(deck(2), examiner: examiner, speech: speech)
        p.start()
        await waitUntil { p.phase == .finished }
        #expect(p.phase == .finished)
        #expect(speech.spoken == ["P0", "Thanks.", "P1"])
        #expect(examiner.decideCalls.count == 2)
        #expect(examiner.gradeCalls.first?.map(\.exchanges) == [[OralExchange(question: "P0", answer: "my answer")], [OralExchange(question: "P1", answer: "my answer")]])
        #expect(p.deck.outcomes.values.allSatisfy { $0 == .correct })
        #expect(p.deck.outcomes.count == 2)
        #expect(p.deck.aiGrades.count == 2)
        #expect(p.overall == "Overall.")
    }

    @Test("a follow-up is asked once; the second answer is not sent for another decision")
    func followUpTwoTurnsMax() async {
        let examiner = Examiner(decisions: [OralTurnDecision(followUp: "Say more?", say: "Say more?")])
        let speech = ScriptedSynthesizer()
        let p = player(deck(1), examiner: examiner, speech: speech)
        p.start()
        await waitUntil { p.phase == .finished }
        #expect(speech.spoken == ["P0", "Say more?"])
        #expect(examiner.decideCalls.count == 1, "two turns per card at most")
        #expect(examiner.gradeCalls.first?.first?.exchanges.map(\.question) == ["P0", "Say more?"])
    }

    @Test("no answer means no follow-up call")
    func silence() async {
        let examiner = Examiner()
        let recognizer = ScriptedRecognizer(partial: "", final: "", delay: .seconds(5))
        let p = player(deck(1), examiner: examiner, recognizer: recognizer)
        p.start()
        await waitUntil { p.phase == .finished }
        #expect(examiner.decideCalls.isEmpty)
        #expect(examiner.gradeCalls.first?.first?.exchanges == [OralExchange(question: "P0", answer: "")])
    }

    @Test("a failed follow-up decision moves on instead of blocking")
    func decisionFails() async {
        let examiner = Examiner(decisions: [nil])
        let p = player(deck(2), examiner: examiner)
        p.start()
        await waitUntil { p.phase == .finished }
        #expect(p.phase == .finished)
        #expect(examiner.gradeCalls.first?.count == 2)
    }

    @Test("Done ends the answer before the silence timeout")
    func done() async {
        let examiner = Examiner()
        let recognizer = ScriptedRecognizer(partial: "partial words", final: "never", delay: .seconds(10))
        let p = OralExamPlayer(
            deck: deck(1), speech: ScriptedSynthesizer(), recognizer: recognizer,
            silenceTimeout: .seconds(10), noSpeechTimeout: .seconds(10),
            decide: { try examiner.decide($0, $1) }, grade: { try examiner.grade($0) }
        )
        p.start()
        await waitUntil { p.transcript == "partial words" }
        p.finishAnswer()
        await waitUntil { p.phase == .finished }
        #expect(examiner.decideCalls.first?.1 == [OralExchange(question: "P0", answer: "partial words")])
        #expect(recognizer.stopCount >= 1)
    }

    @Test("Skip moves on and the skipped card is not graded")
    func skip() async {
        let examiner = Examiner()
        let speech = ScriptedSynthesizer(mode: .manual)
        let p = player(deck(2), examiner: examiner, speech: speech)
        p.start()
        await waitUntil { p.phase == .asking }
        p.skipCard()
        await waitUntil { speech.spoken.count == 2 }
        #expect(speech.spoken == ["P0", "P1"])
        speech.finishCurrent()
        await waitUntil { p.phase == .finished }
        #expect(examiner.gradeCalls.first?.map(\.card.prompt) == ["P1"])
        #expect(p.deck.outcomes.count == 1)
    }

    @Test("a failed grading can be retried")
    func gradingRetry() async {
        let examiner = Examiner()
        examiner.gradeError = LLMError.server(status: 500)
        let p = player(deck(1), examiner: examiner)
        p.start()
        await waitUntil { if case .gradingFailed = p.phase { return true } else { return false } }
        guard case .gradingFailed = p.phase else {
            Issue.record("expected gradingFailed, got \(p.phase)")
            return
        }
        #expect(p.deck.outcomes.isEmpty)
        examiner.gradeError = nil
        p.retryGrading()
        await waitUntil { p.phase == .finished }
        #expect(p.deck.outcomes.count == 1)
        #expect(examiner.gradeCalls.count == 2)
    }

    @Test("End abandons the exam and records nothing")
    func abandon() async {
        let examiner = Examiner()
        let speech = ScriptedSynthesizer(mode: .manual)
        let p = player(deck(3), examiner: examiner, speech: speech)
        p.start()
        await waitUntil { p.phase == .asking }
        p.abandon()
        #expect(p.phase == .ended)
        #expect(p.deck.abandoned)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(examiner.gradeCalls.isEmpty)
        #expect(p.phase == .ended)
    }

    @Test("without microphone access the exam does not start")
    func denied() async {
        let examiner = Examiner()
        let speech = ScriptedSynthesizer()
        let p = player(deck(1), examiner: examiner, speech: speech, recognizer: ScriptedRecognizer(access: .speechDenied))
        p.start()
        await waitUntil { if case .unavailable = p.phase { return true } else { return false } }
        guard case .unavailable(let message) = p.phase else {
            Issue.record("expected unavailable, got \(p.phase)")
            return
        }
        #expect(message.contains("speech recognition"))
        #expect(speech.spoken.isEmpty)
    }

    @Test("holds play-and-record for the exam and releases it before grading")
    func audio() async {
        let backend = RecordingAudioBackend()
        let coordinator = AudioSessionCoordinator(backend: backend)
        let examiner = Examiner()
        let speech = ScriptedSynthesizer(mode: .manual)
        let p = player(deck(1), examiner: examiner, speech: speech, audio: coordinator)
        p.start()
        await waitUntil { p.phase == .asking }
        #expect(coordinator.mode == .playAndRecord)
        speech.finishCurrent()
        await waitUntil { p.phase == .finished }
        #expect(coordinator.mode == .inactive)
        #expect(backend.applied == [.playAndRecord, .inactive])
    }
}
