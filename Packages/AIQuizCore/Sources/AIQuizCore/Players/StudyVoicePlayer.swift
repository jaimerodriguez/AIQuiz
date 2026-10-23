import Foundation
import Observation

/// Study — Voice auto-read (SPEC F-11): reads each card's prompt, short and long answer,
/// `repeatCount` times with `pauseSeconds` between parts, then moves on.
///
/// With a `hintListener` (F-12), after a card with hints has been read the player listens
/// for `hintWindow`; saying "hint" reveals and reads the next hint. It only listens in that
/// gap, never while speaking, and holds the audio session in play-and-record meanwhile.
@Observable
@MainActor
public final class StudyVoicePlayer {
    public enum State: Sendable { case idle, playing, paused, ended }

    public let deck: SessionDeck
    public private(set) var state: State = .idle
    public private(set) var hints = HintProgress(hints: [])
    public var hintRevealed: Bool { hints.level > 0 }
    /// Listening for the spoken "hint" command right now (F-12).
    public private(set) var listeningForHint = false
    /// Why the spoken command is off for this session (access denied, recognizer failed).
    public private(set) var voiceHintMessage: String?

    private let speech: any SpeechSynthesizing
    private let pauseSeconds: Double
    private let repeatCount: Int
    private var hintListener: (any SpeechRecognizing)?
    private let audio: AudioSessionCoordinator?
    private let locale: Locale
    private let hintWindow: Duration
    private var task: Task<Void, Never>?
    @ObservationIgnored private var heardHint = false
    @ObservationIgnored private var hintAccessChecked = false
    @ObservationIgnored private var holdsAudio = false

    public init(
        deck: SessionDeck,
        speech: any SpeechSynthesizing,
        pauseSeconds: Double,
        repeatCount: Int,
        hintListener: (any SpeechRecognizing)? = nil,
        audio: AudioSessionCoordinator? = nil,
        locale: Locale = .current,
        hintWindow: Duration = .seconds(2.5)
    ) {
        self.deck = deck
        self.speech = speech
        self.pauseSeconds = pauseSeconds
        self.repeatCount = max(1, repeatCount)
        self.hintListener = hintListener
        self.audio = audio
        self.locale = locale
        self.hintWindow = hintWindow
        resetHints()
    }

    /// Whether the spoken "hint" command is on for this session.
    public var listensForHint: Bool { hintListener != nil }

    private func resetHints() {
        hints = HintProgress(hints: deck.current?.hints ?? [])
    }

    public func start() {
        guard state == .idle || state == .paused else { return }
        if state == .paused { resume(); return }
        state = .playing
        holdAudioForHints()
        runLoop()
    }

    public func pause() {
        guard state == .playing else { return }
        state = .paused
        speech.pause()
    }

    public func resume() {
        guard state == .paused else { return }
        state = .playing
        speech.resume()
    }

    /// Stops speaking; the session ends without changing the deck.
    public func stop() {
        task?.cancel()
        speech.stop()
        stopListeningForHint()
        if state != .ended { state = .ended }
        releaseAudio()
    }

    /// Ends early and discards the session (SPEC §5).
    public func abandon() {
        stop()
        deck.abandon()
    }

    public func repeatCard() {
        restart { }
    }

    public func skip() {
        restart { deck.next() }
    }

    public func back() {
        guard !deck.atStart else { return }
        restart { deck.back() }
    }

    /// Reveals the next hint and says "Hint." (F-11, F-24); after the last, hides them.
    public func toggleHint() {
        if hints.advance() {
            Task { await speech.speak("Hint.") }
        }
    }

    private func restart(_ move: () -> Void) {
        task?.cancel()
        speech.stop()
        stopListeningForHint()
        move()
        resetHints()
        if deck.ended {
            state = .ended
            releaseAudio()
        } else {
            state = .playing
            runLoop()
        }
    }

    private func runLoop() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.playFromCurrentCard()
        }
    }

    private func playFromCurrentCard() async {
        await checkHintAccess()
        while !Task.isCancelled, let card = deck.current {
            let parts = [card.prompt, card.shortAnswer, card.longAnswer].compactMap { $0 }.filter { !$0.isEmpty }
            // The listening window replaces the pause after the card's last part.
            let listens = hintListener != nil && hints.hasMore
            for round in 0..<repeatCount {
                for (index, part) in parts.enumerated() {
                    if Task.isCancelled { return }
                    await speech.speak(part)
                    if Task.isCancelled { return }
                    await waitWhilePaused()
                    let last = round == repeatCount - 1 && index == parts.count - 1
                    if pauseSeconds > 0, !(last && listens) { try? await Task.sleep(for: .seconds(pauseSeconds)) }
                }
            }
            if listens { await listenForHint() }
            if Task.isCancelled { return }
            deck.next()
            resetHints()
            if deck.ended {
                state = .ended
                releaseAudio()
                return
            }
        }
    }

    // MARK: Spoken "hint" (F-12)

    /// Asks for microphone and speech access once, before the first card is read.
    private func checkHintAccess() async {
        guard let hintListener, !hintAccessChecked else { return }
        hintAccessChecked = true
        switch await hintListener.authorisation() {
        case .authorized:
            break
        case .microphoneDenied:
            disableVoiceHints("Saying “hint” needs microphone access. Enable it in Settings → AIQuiz.")
        case .speechDenied:
            disableVoiceHints("Saying “hint” needs speech recognition. Enable it in Settings → AIQuiz.")
        }
    }

    /// Listens for `hintWindow`; each "hint" heard reveals and reads the next hint, then
    /// listens again while hints remain. Pausing stops listening; resuming opens a new window.
    private func listenForHint() async {
        while let listener = hintListener, hints.hasMore, !Task.isCancelled {
            heardHint = false
            do {
                try listener.start(
                    locale: locale,
                    onPartial: { [weak self] text in self?.heard(text) },
                    onFinal: { [weak self] text in self?.heard(text) },
                    onError: { _ in }
                )
            } catch {
                disableVoiceHints("Saying “hint” is off: the speech recognizer could not start.")
                return
            }
            listeningForHint = true
            let deadline = ContinuousClock.now + max(hintWindow, .seconds(pauseSeconds))
            while !heardHint, !Task.isCancelled, state != .paused, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            stopListeningForHint()
            if Task.isCancelled { return }
            if state == .paused {
                await waitWhilePaused()
                continue
            }
            guard heardHint else { return }
            if hints.advance(), let hint = hints.shown.last {
                await speech.speak("Hint. \(hint)")
                // A breath after the hint, as after any part, before listening or moving on.
                if !Task.isCancelled, pauseSeconds > 0 { try? await Task.sleep(for: .seconds(pauseSeconds)) }
            }
        }
    }

    private func heard(_ text: String) {
        guard listeningForHint, HintCommand.matches(text) else { return }
        heardHint = true
    }

    private func stopListeningForHint() {
        guard listeningForHint else { return }
        hintListener?.stop()
        listeningForHint = false
    }

    private func disableVoiceHints(_ message: String) {
        hintListener = nil
        voiceHintMessage = message
        releaseAudio()
    }

    /// One play-and-record session for the whole study session, instead of switching
    /// categories around every listening window (F-50).
    private func holdAudioForHints() {
        guard hintListener != nil, let audio, !holdsAudio else { return }
        do {
            try audio.beginPlayAndRecord()
            holdsAudio = true
        } catch {
            // Speech and recognition still ask for their own sessions.
        }
    }

    private func releaseAudio() {
        guard holdsAudio else { return }
        holdsAudio = false
        audio?.end()
    }

    /// Holds the loop between parts while paused, so a pause never skips ahead.
    private func waitWhilePaused() async {
        while state == .paused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
