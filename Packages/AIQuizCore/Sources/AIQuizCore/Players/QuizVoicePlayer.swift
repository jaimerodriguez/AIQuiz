import Foundation
import Observation

/// Quiz — Voice answer (SPEC F-14): listen, reveal, grade.
@Observable
@MainActor
public final class QuizVoicePlayer {
    public enum Phase: Sendable { case awaitingAnswer, listening, reveal, ended }

    public struct AIVerdict: Sendable, Equatable {
        public let verdict: CardVerdict
        public let reason: String
    }

    public let deck: SessionDeck
    public private(set) var phase: Phase = .awaitingAnswer
    public private(set) var transcript = ""
    public private(set) var hintRevealed = false
    public private(set) var sttError: String?
    public private(set) var aiVerdict: AIVerdict?
    public private(set) var aiJudging = false
    public private(set) var aiError: String?

    private let recognizer: any SpeechRecognizing
    private let locale: Locale

    public init(deck: SessionDeck, recognizer: any SpeechRecognizing, locale: Locale = .current) {
        self.deck = deck
        self.recognizer = recognizer
        self.locale = locale
    }

    public func startListening() async {
        guard phase == .awaitingAnswer else { return }
        sttError = nil
        transcript = ""
        aiVerdict = nil
        aiError = nil

        switch await recognizer.authorisation() {
        case .authorized:
            break
        case .microphoneDenied:
            sttError = "Microphone access denied. Enable it in Settings → AIQuiz."
            return
        case .speechDenied:
            sttError = "Speech recognition not authorised."
            return
        }
        guard phase == .awaitingAnswer else { return }

        do {
            phase = .listening
            try recognizer.start(
                locale: locale,
                onPartial: { [weak self] text in self?.transcript = text },
                onFinal: { [weak self] text in self?.transcript = text },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.sttError = Self.friendlyMessage(for: error)
                    if self.phase == .listening { self.phase = .reveal }
                }
            )
        } catch {
            sttError = Self.friendlyMessage(for: error)
            phase = .awaitingAnswer
        }
    }

    public func stopListeningAndReveal() {
        recognizer.stop()
        phase = .reveal
    }

    /// *Show answer*: skip the voice step (F-14.5).
    public func revealAnswerWithoutVoice() {
        recognizer.stop()
        phase = .reveal
    }

    public func toggleHint() {
        guard deck.current?.hint != nil else { return }
        hintRevealed.toggle()
    }

    public func record(_ verdict: CardVerdict) {
        deck.record(verdict)
        advance()
    }

    private func advance() {
        transcript = ""
        hintRevealed = false
        aiVerdict = nil
        aiError = nil
        sttError = nil
        deck.next()
        phase = deck.ended ? .ended : .awaitingAnswer
    }

    public func abandon() {
        recognizer.stop()
        deck.abandon()
        phase = .ended
    }

    /// *Ask AI to judge* (F-15): grades the transcript with the given judge.
    public func judge(with judge: (JudgeRequest) async throws -> JudgeVerdict) async {
        guard let card = deck.current, !transcript.isEmpty, !aiJudging else { return }
        aiError = nil
        aiJudging = true
        defer { aiJudging = false }
        do {
            let verdict = try await judge(JudgeRequest(
                prompt: card.prompt,
                userAnswer: transcript,
                correctShort: card.shortAnswer,
                correctLong: card.longAnswer
            ))
            aiVerdict = AIVerdict(verdict: verdict.verdict, reason: verdict.reason)
        } catch {
            aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("siri") && lower.contains("dictation") {
            return "Speech recognition needs Siri or Dictation enabled. Open Settings → Apple Intelligence & Siri (turn Siri on), or Settings → General → Keyboard → Dictation."
        }
        if lower.contains("not authorized") || lower.contains("denied") {
            return "Speech recognition isn't authorised. Enable it in Settings → AIQuiz."
        }
        if lower.contains("no speech") {
            return "Didn't catch any speech — tap the mic and try again."
        }
        return raw
    }
}
