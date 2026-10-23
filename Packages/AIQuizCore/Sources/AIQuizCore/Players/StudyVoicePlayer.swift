import Foundation
import Observation

/// Study — Voice auto-read (SPEC F-11): reads each card's prompt, short and long answer,
/// `repeatCount` times with `pauseSeconds` between parts, then moves on.
@Observable
@MainActor
public final class StudyVoicePlayer {
    public enum State: Sendable { case idle, playing, paused, ended }

    public let deck: SessionDeck
    public private(set) var state: State = .idle
    public private(set) var hintRevealed = false

    private let speech: any SpeechSynthesizing
    private let pauseSeconds: Double
    private let repeatCount: Int
    private var task: Task<Void, Never>?

    public init(deck: SessionDeck, speech: any SpeechSynthesizing, pauseSeconds: Double, repeatCount: Int) {
        self.deck = deck
        self.speech = speech
        self.pauseSeconds = pauseSeconds
        self.repeatCount = max(1, repeatCount)
    }

    public func start() {
        guard state == .idle || state == .paused else { return }
        if state == .paused { resume(); return }
        state = .playing
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
        if state != .ended { state = .ended }
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

    /// Reveals the hint and says "Hint." (F-11); a second tap hides it.
    public func toggleHint() {
        guard deck.current?.hint != nil else { return }
        hintRevealed.toggle()
        if hintRevealed {
            Task { await speech.speak("Hint.") }
        }
    }

    private func restart(_ move: () -> Void) {
        task?.cancel()
        speech.stop()
        hintRevealed = false
        move()
        if deck.ended {
            state = .ended
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
        while !Task.isCancelled, let card = deck.current {
            let parts = [card.prompt, card.shortAnswer, card.longAnswer].compactMap { $0 }.filter { !$0.isEmpty }
            for _ in 0..<repeatCount {
                for part in parts {
                    if Task.isCancelled { return }
                    await speech.speak(part)
                    if Task.isCancelled { return }
                    await waitWhilePaused()
                    if pauseSeconds > 0 { try? await Task.sleep(for: .seconds(pauseSeconds)) }
                }
            }
            if Task.isCancelled { return }
            hintRevealed = false
            deck.next()
            if deck.ended {
                state = .ended
                return
            }
        }
    }

    /// Holds the loop between parts while paused, so a pause never skips ahead.
    private func waitWhilePaused() async {
        while state == .paused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
