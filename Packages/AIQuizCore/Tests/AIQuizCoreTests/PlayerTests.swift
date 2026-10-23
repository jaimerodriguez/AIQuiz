import Foundation
import Testing
@testable import AIQuizCore

@MainActor
private func deck(_ n: Int, hints: Bool = true) -> SessionDeck {
    SessionDeck(cards: (0..<n).map {
        CardSnapshot(id: UUID(), prompt: "P\($0)", longAnswer: "L\($0)", shortAnswer: "S\($0)", hint: hints ? "H\($0)" : nil)
    })
}

/// Lets queued main-actor tasks run.
@MainActor
private func settle(_ rounds: Int = 20) async {
    for _ in 0..<rounds { await Task.yield() }
}

@Suite("StudyVoicePlayer with scripted speech (F-11)")
@MainActor
struct StudyVoicePlayerTests {
    @Test("reads prompt, short and long answer for every card, then ends")
    func readsEverything() async {
        let speech = ScriptedSynthesizer()
        let player = StudyVoicePlayer(deck: deck(2), speech: speech, pauseSeconds: 0, repeatCount: 1)
        player.start()
        for _ in 0..<50 where player.state != .ended { await settle() }
        #expect(player.state == .ended)
        #expect(speech.spoken == ["P0", "S0", "L0", "P1", "S1", "L1"])
        #expect(player.deck.ended)
        #expect(!player.deck.abandoned)
    }

    @Test("repeat count reads each card N times")
    func repeatCount() async {
        let speech = ScriptedSynthesizer()
        let player = StudyVoicePlayer(deck: deck(1), speech: speech, pauseSeconds: 0, repeatCount: 2)
        player.start()
        for _ in 0..<50 where player.state != .ended { await settle() }
        #expect(speech.spoken == ["P0", "S0", "L0", "P0", "S0", "L0"])
    }

    @Test("pause and resume reach the synthesizer and hold the loop")
    func pauseResume() async {
        let speech = ScriptedSynthesizer(mode: .manual)
        let player = StudyVoicePlayer(deck: deck(2), speech: speech, pauseSeconds: 0, repeatCount: 1)
        player.start()
        await settle()
        #expect(speech.spoken == ["P0"])
        player.pause()
        #expect(player.state == .paused)
        #expect(speech.pauseCount == 1)
        speech.finishCurrent()
        await settle()
        #expect(speech.spoken == ["P0"], "nothing new is read while paused")
        player.resume()
        #expect(speech.resumeCount == 1)
        try? await Task.sleep(for: .milliseconds(250))
        await settle()
        #expect(speech.spoken == ["P0", "S0"])
        player.stop()
    }

    @Test("skip, back and repeat restart reading at the right card")
    func navigation() async {
        let speech = ScriptedSynthesizer(mode: .manual)
        let player = StudyVoicePlayer(deck: deck(3), speech: speech, pauseSeconds: 0, repeatCount: 1)
        player.start()
        await settle()
        player.skip()
        await settle()
        #expect(player.deck.index == 1)
        #expect(speech.spoken.last == "P1")
        player.repeatCard()
        await settle()
        #expect(player.deck.index == 1)
        #expect(speech.spoken.suffix(2) == ["P1", "P1"])
        player.back()
        await settle()
        #expect(player.deck.index == 0)
        #expect(speech.spoken.last == "P0")
        player.stop()
        #expect(player.state == .ended)
    }

    @Test("skipping past the last card ends the session; abandon discards it")
    func endAndAbandon() async {
        let speech = ScriptedSynthesizer(mode: .manual)
        let player = StudyVoicePlayer(deck: deck(1), speech: speech, pauseSeconds: 0, repeatCount: 1)
        player.start()
        await settle()
        player.skip()
        #expect(player.state == .ended)
        #expect(player.deck.ended && !player.deck.abandoned)

        let other = StudyVoicePlayer(deck: deck(2), speech: speech, pauseSeconds: 0, repeatCount: 1)
        other.start()
        await settle()
        other.abandon()
        #expect(other.state == .ended)
        #expect(other.deck.abandoned)
    }

    @Test("the hint toggles, says Hint, and resets on the next card")
    func hint() async {
        let speech = ScriptedSynthesizer(mode: .manual)
        let player = StudyVoicePlayer(deck: deck(2), speech: speech, pauseSeconds: 0, repeatCount: 1)
        player.start()
        await settle()
        player.toggleHint()
        await settle()
        #expect(player.hintRevealed)
        #expect(speech.spoken.contains("Hint."))
        player.skip()
        #expect(!player.hintRevealed)
        player.stop()
    }
}

@Suite("StudyReadPlayer (F-13)")
@MainActor
struct StudyReadPlayerTests {
    @Test("flip card reveals per card; all at once always shows")
    func reveal() {
        let player = StudyReadPlayer(deck: deck(3), style: .flipCard)
        #expect(!player.showsAnswer)
        player.reveal()
        #expect(player.showsAnswer)
        player.next()
        #expect(!player.showsAnswer, "each card starts hidden")
        player.style = .allAtOnce
        #expect(player.showsAnswer)
    }

    @Test("next, back, hint reset and finishing on the last card")
    func navigation() {
        let player = StudyReadPlayer(deck: deck(2), style: .flipCard)
        player.back()
        #expect(player.deck.index == 0)
        player.toggleHint()
        #expect(player.hintRevealed)
        player.next()
        #expect(player.deck.index == 1)
        #expect(!player.hintRevealed)
        player.next()
        #expect(player.finished)
        #expect(!player.deck.abandoned)
    }

    @Test("a card without a hint can't reveal one; abandon discards")
    func noHintAndAbandon() {
        let player = StudyReadPlayer(deck: deck(1, hints: false), style: .flipCard)
        player.toggleHint()
        #expect(!player.hintRevealed)
        player.abandon()
        #expect(player.deck.abandoned)
    }
}

@Suite("QuizVoicePlayer with scripted recognition (F-14)")
@MainActor
struct QuizVoicePlayerTests {
    @Test("listen, transcript, reveal, grade, end")
    func happyPath() async throws {
        let recognizer = ScriptedRecognizer(delay: .milliseconds(10))
        let player = QuizVoicePlayer(deck: deck(2), recognizer: recognizer, locale: Locale(identifier: "es-ES"))
        await player.startListening()
        #expect(player.phase == .listening)
        #expect(recognizer.startedLocales == [Locale(identifier: "es-ES")], "the STT language setting reaches the recognizer")
        try await Task.sleep(for: .milliseconds(60))
        #expect(player.transcript == "Fixture answer")
        player.stopListeningAndReveal()
        #expect(player.phase == .reveal)
        player.record(.correct)
        #expect(player.phase == .awaitingAnswer)
        #expect(player.transcript.isEmpty)
        player.revealAnswerWithoutVoice()
        player.record(.wrong)
        #expect(player.phase == .ended)
        #expect(player.deck.counts.correct == 1)
        #expect(player.deck.counts.wrong == 1)
    }

    @Test("denied microphone explains itself and stays put")
    func denied() async {
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(access: .microphoneDenied))
        await player.startListening()
        #expect(player.phase == .awaitingAnswer)
        #expect(player.sttError?.contains("Microphone") == true)
    }

    @Test("AI judge sets a verdict; failures show a message")
    func judge() async {
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(delay: .zero))
        await player.startListening()
        try? await Task.sleep(for: .milliseconds(20))
        player.stopListeningAndReveal()
        await player.judge { request in
            #expect(request.userAnswer == "Fixture answer")
            return JudgeVerdict(verdict: .partial, reason: "Close.")
        }
        #expect(player.aiVerdict == .init(verdict: .partial, reason: "Close."))
        struct Boom: LocalizedError { var errorDescription: String? { "The endpoint is down." } }
        await player.judge { _ in throw Boom() }
        #expect(player.aiError == "The endpoint is down.")
    }

    @Test("abandon stops listening and discards")
    func abandon() async {
        let recognizer = ScriptedRecognizer()
        let player = QuizVoicePlayer(deck: deck(2), recognizer: recognizer)
        await player.startListening()
        player.abandon()
        #expect(player.phase == .ended)
        #expect(player.deck.abandoned)
        #expect(recognizer.stopCount >= 1)
    }

    @Test("practice missed: a new deck of exactly the wrong and partial cards")
    func practiceMissed() {
        let d = deck(4)
        let player = QuizVoicePlayer(deck: d, recognizer: ScriptedRecognizer())
        for verdict in [CardVerdict.correct, .wrong, .partial, .correct] {
            player.revealAnswerWithoutVoice()
            player.record(verdict)
        }
        #expect(d.missedCards.map(\.prompt) == ["P1", "P2"])
        let practice = SessionDeck(cards: d.missedCards)
        #expect(practice.cards.map(\.prompt) == ["P1", "P2"])
        #expect(!practice.recorded, "a practice session is recorded on its own")
    }
}

/// A judge the test resolves by hand.
@MainActor
private final class ManualJudge {
    private var pending: CheckedContinuation<JudgeVerdict, Error>?
    private(set) var calls = 0

    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func resolve(_ verdict: CardVerdict, _ reason: String = "Because.") {
        pending?.resume(returning: JudgeVerdict(verdict: verdict, reason: reason))
        pending = nil
    }

    func fail(_ error: Error) {
        pending?.resume(throwing: error)
        pending = nil
    }
}

private struct Down: LocalizedError { var errorDescription: String? { "The grading endpoint is down." } }

@Suite("QuizVoicePlayer auto-grade (F-15, F-16, S-3)")
@MainActor
struct QuizVoiceAutoGradeTests {
    private func answered(_ player: QuizVoicePlayer) async throws {
        await player.startListening()
        try await Task.sleep(for: .milliseconds(40))
        player.stopListeningAndReveal()
        await settle()
    }

    @Test("a verdict pre-selects; a different tap records an override")
    func overrideRecorded() async throws {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(2), recognizer: ScriptedRecognizer(delay: .milliseconds(5)), autoJudge: judge.judge)
        #expect(player.autoGrades)
        try await answered(player)
        #expect(player.aiJudging)
        judge.resolve(.partial, "Missed the date.")
        await settle()
        #expect(player.aiVerdict == AIGrade(verdict: .partial, reason: "Missed the date."))
        #expect(!player.aiJudging)
        player.record(.correct)
        let outcome = try #require(player.deck.toCardOutcomes().first)
        #expect(outcome.verdict == .correct)
        #expect(outcome.aiVerdict == .partial)
        #expect(outcome.aiReason == "Missed the date.")
        #expect(outcome.userOverrode)
    }

    @Test("agreeing with the AI is not an override")
    func agreement() async throws {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(delay: .milliseconds(5)), autoJudge: judge.judge)
        try await answered(player)
        judge.resolve(.wrong)
        await settle()
        player.record(.wrong)
        #expect(player.deck.toCardOutcomes().first?.userOverrode == false)
    }

    @Test("grading before the AI answers works, and the late verdict is ignored")
    func lateVerdictIgnored() async throws {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(2), recognizer: ScriptedRecognizer(delay: .milliseconds(5)), autoJudge: judge.judge)
        try await answered(player)
        player.record(.correct)
        #expect(player.phase == .awaitingAnswer)
        #expect(!player.aiJudging, "advance cancels the pending judge")
        judge.resolve(.wrong)
        await settle()
        #expect(player.aiVerdict == nil, "the old card's verdict never lands on the new card")
        #expect(player.deck.toCardOutcomes().first?.aiVerdict == nil)
    }

    @Test("an AI error leaves self-grading working")
    func errorDoesNotBlock() async throws {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(delay: .milliseconds(5)), autoJudge: judge.judge)
        try await answered(player)
        judge.fail(Down())
        await settle()
        #expect(player.aiError == "The grading endpoint is down.")
        player.record(.partial)
        #expect(player.phase == .ended)
        #expect(player.deck.counts.partial == 1)
    }

    @Test("no auto-grade without a transcript (Show answer) or when S-3 is off")
    func noTranscriptNoJudge() async {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(), autoJudge: judge.judge)
        player.revealAnswerWithoutVoice()
        await settle()
        #expect(judge.calls == 0)
        #expect(!QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer()).autoGrades)
    }

    @Test("two seconds of silence after speech stops listening and reveals")
    func silenceStops() async throws {
        let recognizer = ScriptedRecognizer(delay: .milliseconds(5))
        let player = QuizVoicePlayer(deck: deck(1), recognizer: recognizer, silenceTimeout: .milliseconds(80))
        await player.startListening()
        #expect(player.phase == .listening)
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.phase == .reveal)
        #expect(recognizer.stopCount >= 1)
        #expect(player.transcript == "Fixture answer")
    }

    @Test("why-wrong appears after a partial or wrong verdict and is kept on the outcome")
    func whyWrong() async throws {
        let judge = ManualJudge()
        let player = QuizVoicePlayer(deck: deck(1), recognizer: ScriptedRecognizer(delay: .milliseconds(5)), autoJudge: judge.judge)
        try await answered(player)
        #expect(!player.canAskWhyWrong)
        judge.resolve(.wrong)
        await settle()
        #expect(player.canAskWhyWrong)
        await player.explainWhyWrong { card, answer in "You said \(answer); the answer is \(card.shortAnswer ?? "")." }
        #expect(player.whyWrong == "You said Fixture answer; the answer is S0.")
        player.record(.wrong)
        #expect(player.deck.toCardOutcomes().first?.explanation == "You said Fixture answer; the answer is S0.")
    }
}
