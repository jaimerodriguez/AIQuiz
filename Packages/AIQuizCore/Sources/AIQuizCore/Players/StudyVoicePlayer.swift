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
    public private(set) var hints = HintProgress(hints: [])
    public var hintRevealed: Bool { hints.level > 0 }

    private let speech: any SpeechSynthesizing
    private let pauseSeconds: Double
    private let repeatCount: Int
    private var task: Task<Void, Never>?

    public init(deck: SessionDeck, speech: any SpeechSynthesizing, pauseSeconds: Double, repeatCount: Int) {
        self.deck = deck
        self.speech = speech
        self.pauseSeconds = pauseSeconds
        self.repeatCount = max(1, repeatCount)
        resetHints()
    }

    private func resetHints() {
        hints = HintProgress(hints: deck.current?.hints ?? [])
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

    /// Reveals the next hint and says "Hint." (F-11, F-24); after the last, hides them.
    public func toggleHint() {
        if hints.advance() {
            Task { await speech.speak("Hint.") }
        }
    }

    private func restart(_ move: () -> Void) {
        task?.cancel()
        speech.stop()
        move()
        resetHints()
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
            deck.next()
            resetHints()
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
