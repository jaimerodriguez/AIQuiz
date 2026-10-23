import Foundation
import Testing
@testable import AIQuizCore

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("AudioSessionCoordinator (F-50)")
@MainActor
struct AudioSessionCoordinatorTests {
    @Test("each transition is applied once and logged; repeating a request does nothing")
    func idempotent() throws {
        let backend = RecordingAudioBackend()
        var log: [String] = []
        let audio = AudioSessionCoordinator(backend: backend, log: { log.append($0) })
        try audio.beginPlayback()
        try audio.beginPlayback()
        try audio.beginRecording()
        try audio.beginRecording()
        audio.endRecording()
        audio.end()
        #expect(backend.applied == [.playback, .recording, .inactive])
        #expect(audio.mode == .inactive)
        #expect(log == ["audio: inactive → playback", "audio: playback → recording", "audio: recording → inactive"])
    }

    @Test("playback → record → playAndRecord → end, as a voice session runs")
    func fullCycle() throws {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        try audio.beginPlayback()
        try audio.beginRecording()
        try audio.beginPlayAndRecord()
        try audio.beginPlayAndRecord()
        audio.end()
        audio.end()
        #expect(backend.applied == [.playback, .recording, .playAndRecord, .inactive])
    }

    @Test("a play-and-record session satisfies playback and recording until it ends")
    func holdsPlayAndRecord() throws {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        try audio.beginPlayAndRecord()
        try audio.beginPlayback()
        try audio.beginRecording()
        audio.endRecording()
        #expect(audio.mode == .playAndRecord, "recognition stopping does not release the held session")
        #expect(backend.applied == [.playAndRecord])
        audio.end()
        try audio.beginPlayback()
        #expect(backend.applied == [.playAndRecord, .inactive, .playback])
    }

    @Test("endRecording releases only a record-only session")
    func endRecordingOnlyForRecording() throws {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        try audio.beginPlayback()
        audio.endRecording()
        #expect(audio.mode == .playback)
        try audio.beginRecording()
        audio.endRecording()
        #expect(audio.mode == .inactive)
    }

    @Test("a failed transition throws, is logged, and keeps the previous mode")
    func failure() throws {
        let backend = RecordingAudioBackend()
        backend.failing = [.recording]
        var log: [String] = []
        let audio = AudioSessionCoordinator(backend: backend, log: { log.append($0) })
        try audio.beginPlayback()
        #expect(throws: RecordingAudioBackend.Failure.self) { try audio.beginRecording() }
        #expect(audio.mode == .playback)
        #expect(log.last?.contains("failed") == true)
    }

    @Test("ending when deactivation fails still forgets the mode")
    func endFailure() throws {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        try audio.beginPlayback()
        backend.failing = [.inactive]
        audio.end()
        #expect(audio.mode == .inactive)
        backend.failing = []
        try audio.beginPlayback()
        #expect(backend.applied == [.playback, .playback], "the next request sets the session up again")
    }

    @Test("after a system reset the next request sets the session up again, keeping a held play-and-record")
    func reset() throws {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        try audio.beginPlayAndRecord()
        audio.sessionWasReset()
        #expect(audio.mode == .inactive)
        try audio.beginPlayback()
        #expect(audio.mode == .playAndRecord)
        #expect(backend.applied == [.playAndRecord, .playAndRecord])
    }
}

@Suite("Spoken hint command (F-12)")
struct HintCommandTests {
    @Test("matches the word hint in any case, alone or in a phrase",
          arguments: ["hint", "Hint", "HINT please", "give me a hint.", "hints", "um, hint?"])
    func matches(_ text: String) {
        #expect(HintCommand.matches(text))
    }

    @Test("ignores other words, including ones that contain hint",
          arguments: ["", "the answer is mitochondria", "hinted", "chinti", "behind"])
    func ignores(_ text: String) {
        #expect(!HintCommand.matches(text))
    }
}

@Suite("Study — Voice with the spoken hint (F-12)")
@MainActor
struct StudyVoiceHintTests {
    private func deck(_ n: Int, hints: Bool = true) -> SessionDeck {
        SessionDeck(cards: (0..<n).map {
            CardSnapshot(id: UUID(), prompt: "P\($0)", longAnswer: "L\($0)", shortAnswer: "S\($0)", hint: hints ? "H\($0)" : nil)
        })
    }

    private func player(_ deck: SessionDeck, listener: ScriptedRecognizer?, audio: AudioSessionCoordinator? = nil, speech: ScriptedSynthesizer = ScriptedSynthesizer()) -> StudyVoicePlayer {
        StudyVoicePlayer(deck: deck, speech: speech, pauseSeconds: 0, repeatCount: 1, hintListener: listener, audio: audio, hintWindow: .milliseconds(300))
    }

    @Test("saying hint between cards reveals and reads the hint, then moves on")
    func saysHint() async {
        let speech = ScriptedSynthesizer()
        let listener = ScriptedRecognizer(partial: "hint", final: "hint", delay: .milliseconds(20))
        let p = player(deck(2), listener: listener, speech: speech)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(speech.spoken == ["P0", "S0", "L0", "Hint. H0", "P1", "S1", "L1", "Hint. H1"])
        #expect(listener.startedLocales.count == 2, "one window per card; a card with no more hints is not listened for")
        #expect(!p.listeningForHint)
    }

    @Test("other speech in the window reveals nothing")
    func otherWords() async {
        let speech = ScriptedSynthesizer()
        let listener = ScriptedRecognizer(partial: "what was that", final: "what was that", delay: .milliseconds(20))
        let p = player(deck(1), listener: listener, speech: speech)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(speech.spoken == ["P0", "S0", "L0"])
        #expect(listener.startedLocales.count == 1)
        #expect(listener.stopCount >= 1, "the window closes the recognizer")
    }

    @Test("cards without hints are not listened for")
    func noHints() async {
        let listener = ScriptedRecognizer(partial: "hint", final: "hint")
        let p = player(deck(2, hints: false), listener: listener)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(listener.startedLocales.isEmpty)
    }

    @Test("denied access turns the command off with a message; reading carries on")
    func denied() async {
        let speech = ScriptedSynthesizer()
        let listener = ScriptedRecognizer(access: .microphoneDenied, partial: "hint", final: "hint")
        let p = player(deck(1), listener: listener, speech: speech)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(speech.spoken == ["P0", "S0", "L0"])
        #expect(listener.startedLocales.isEmpty)
        #expect(p.voiceHintMessage?.contains("microphone") == true)
        #expect(!p.listensForHint)
    }

    @Test("a recognizer that cannot start turns the command off")
    func startFails() async {
        let listener = ScriptedRecognizer(partial: "hint", final: "hint")
        listener.startError = RecordingAudioBackend.Failure()
        let p = player(deck(2), listener: listener)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(p.voiceHintMessage != nil)
        #expect(!p.listensForHint)
    }

    @Test("the session holds play-and-record while it runs and releases it at the end")
    func holdsAudio() async {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        let speech = ScriptedSynthesizer(mode: .manual)
        let listener = ScriptedRecognizer(partial: "nothing", final: "nothing", delay: .milliseconds(20))
        let p = player(deck(1), listener: listener, audio: audio, speech: speech)
        p.start()
        #expect(audio.mode == .playAndRecord)
        p.stop()
        #expect(audio.mode == .inactive)
        #expect(backend.applied == [.playAndRecord, .inactive])
    }

    @Test("without the command the player never touches the audio session")
    func noCommandNoAudio() async {
        let backend = RecordingAudioBackend()
        let audio = AudioSessionCoordinator(backend: backend)
        let p = StudyVoicePlayer(deck: deck(1), speech: ScriptedSynthesizer(), pauseSeconds: 0, repeatCount: 1, audio: audio)
        p.start()
        await waitUntil { p.state == .ended }
        #expect(backend.applied.isEmpty)
    }

    @Test("pausing during the window stops listening; resuming listens again")
    func pauseInWindow() async {
        let speech = ScriptedSynthesizer()
        let listener = ScriptedRecognizer(partial: "nothing", final: "nothing", delay: .milliseconds(20))
        let p = StudyVoicePlayer(deck: deck(1), speech: speech, pauseSeconds: 0, repeatCount: 1, hintListener: listener, hintWindow: .seconds(2))
        p.start()
        await waitUntil { p.listeningForHint }
        p.pause()
        await waitUntil { !p.listeningForHint }
        #expect(!p.listeningForHint)
        p.resume()
        await waitUntil { listener.startedLocales.count == 2 }
        #expect(listener.startedLocales.count == 2)
        p.stop()
    }
}
