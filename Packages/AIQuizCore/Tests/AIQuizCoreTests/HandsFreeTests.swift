import Foundation
import Testing
@testable import AIQuizCore

@Suite("Quiz — Voice auto-listen (S-18, CR-019)")
@MainActor
struct AutoListenTests {
    private func deck(_ n: Int) -> SessionDeck {
        SessionDeck(cards: (0..<n).map { CardSnapshot(id: UUID(), prompt: "P\($0)", longAnswer: "L\($0)") })
    }

    private func player(_ deck: SessionDeck, _ recognizer: ScriptedRecognizer, seconds: Int? = 3) -> QuizVoicePlayer {
        QuizVoicePlayer(deck: deck, recognizer: recognizer, silenceTimeout: .milliseconds(50), autoListenSeconds: seconds, tick: .milliseconds(20))
    }

    @Test("counts down from the setting to zero, then listens without a tap")
    func countsDownThenListens() async {
        let recognizer = ScriptedRecognizer(partial: "my", final: "my answer", delay: .milliseconds(10))
        let p = player(deck(2), recognizer)
        #expect(p.autoListens)
        p.beginAutoListen()
        #expect(p.countdown == 3)
        var seen: [Int] = []
        await waitUntil {
            if let c = p.countdown, seen.last != c { seen.append(c) }
            return p.phase != .awaitingAnswer
        }
        #expect(seen.first == 3 && seen.contains(1), "counted \(seen)")
        #expect(recognizer.startedLocales.count == 1)
        await waitUntil { p.phase == .reveal }
        #expect(p.transcript == "my answer")
        #expect(p.countdown == nil)
    }

    @Test("tapping to answer early stops the countdown and listens once")
    func tapEarly() async {
        let recognizer = ScriptedRecognizer(delay: .seconds(5))
        let p = player(deck(1), recognizer, seconds: 2)
        p.beginAutoListen()
        await p.startListening()
        #expect(p.countdown == nil)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(recognizer.startedLocales.count == 1, "the countdown doesn't start a second recognition")
    }

    @Test("showing the answer or ending stops the countdown; nothing listens")
    func cancel() async {
        let recognizer = ScriptedRecognizer()
        let shown = player(deck(1), recognizer, seconds: 1)
        shown.beginAutoListen()
        shown.revealAnswerWithoutVoice()
        let ended = player(deck(1), recognizer, seconds: 1)
        ended.beginAutoListen()
        ended.abandon()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recognizer.startedLocales.isEmpty)
        #expect(shown.countdown == nil && ended.countdown == nil)
    }

    @Test("the next card starts its own countdown")
    func nextCard() async {
        let recognizer = ScriptedRecognizer(partial: "a", final: "answer", delay: .milliseconds(10))
        let p = player(deck(2), recognizer, seconds: 1)
        p.beginAutoListen()
        await waitUntil { p.phase == .reveal }
        p.record(.correct)
        #expect(p.phase == .awaitingAnswer)
        #expect(p.countdown == 1)
        await waitUntil { recognizer.startedLocales.count == 2 }
        #expect(recognizer.startedLocales.count == 2)
    }

    @Test("pausing stops the countdown; beginning again restarts it")
    func pauseResume() async {
        let recognizer = ScriptedRecognizer()
        let p = player(deck(1), recognizer, seconds: 2)
        p.beginAutoListen()
        p.pauseAutoListen()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recognizer.startedLocales.isEmpty)
        #expect(p.countdown == nil)
        p.beginAutoListen()
        #expect(p.countdown == 2)
        await waitUntil { !recognizer.startedLocales.isEmpty }
        #expect(recognizer.startedLocales.count == 1)
    }

    @Test("off unless set: no countdown, no listening")
    func offByDefault() async {
        let recognizer = ScriptedRecognizer()
        let p = player(deck(1), recognizer, seconds: nil)
        #expect(!p.autoListens)
        p.beginAutoListen()
        #expect(p.countdown == nil)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(recognizer.startedLocales.isEmpty)
    }

    @Test("a quiz that has closed never turns the microphone on")
    func closedQuiz() async {
        let recognizer = ScriptedRecognizer()
        do {
            let p = player(deck(1), recognizer, seconds: 1)
            p.beginAutoListen()
        }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(recognizer.startedLocales.isEmpty)
    }

    @Test("without microphone access it tries once, shows why, and doesn't loop")
    func deniedOnce() async {
        let recognizer = ScriptedRecognizer(access: .microphoneDenied)
        let p = player(deck(1), recognizer, seconds: 1)
        p.beginAutoListen()
        await waitUntil { p.sttError != nil }
        #expect(p.sttError?.contains("Microphone") == true)
        p.beginAutoListen()
        #expect(p.countdown == nil, "no new countdown after a failed attempt")
    }

    @Test("the setting is kept between 1 and 30 seconds")
    func clamped() {
        let recognizer = ScriptedRecognizer()
        let low = player(deck(1), recognizer, seconds: 0)
        low.beginAutoListen()
        #expect(low.countdown == 1)
        low.pauseAutoListen()
        let high = player(deck(1), recognizer, seconds: 99)
        high.beginAutoListen()
        #expect(high.countdown == 30)
        high.pauseAutoListen()
    }
}

@Suite("Hint button only where hints exist")
@MainActor
struct DeckHintsTests {
    @Test("a deck has hints when any card has its own or a stored AI hint")
    func hasHints() {
        let plain = CardSnapshot(id: UUID(), prompt: "P", longAnswer: "L")
        #expect(!SessionDeck(cards: [plain, plain]).hasHints)
        #expect(SessionDeck(cards: [plain, CardSnapshot(id: UUID(), prompt: "P", longAnswer: "L", hint: "H")]).hasHints)
        #expect(SessionDeck(cards: [CardSnapshot(id: UUID(), prompt: "P", longAnswer: "L", aiHints: ["AI"])]).hasHints)
        #expect(!SessionDeck(cards: [CardSnapshot(id: UUID(), prompt: "P", longAnswer: "L", hint: "  ")]).hasHints, "a blank hint is no hint")
    }
}
