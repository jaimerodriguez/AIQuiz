import Foundation
import Observation

/// Quiz — Voice answer (SPEC F-14, F-15, F-16): listen, reveal, grade.
///
/// With auto-grade on (S-3), revealing a spoken answer asks the AI for a verdict in the
/// background; the verdict pre-selects a grade, and the user's tap always wins. The AI never
/// blocks grading: errors and slow replies leave the three grade buttons working.
@Observable
@MainActor
public final class QuizVoicePlayer {
    public enum Phase: Sendable { case awaitingAnswer, listening, reveal, ended }

    public typealias Judge = (JudgeRequest) async throws -> JudgeVerdict
    public typealias Explain = (CardSnapshot, String) async throws -> String

    public let deck: SessionDeck
    public private(set) var phase: Phase = .awaitingAnswer
    public private(set) var transcript = ""
    public private(set) var hints = HintProgress(hints: [])
    public var hintRevealed: Bool { hints.level > 0 }
    public private(set) var sttError: String?
    public private(set) var aiVerdict: AIGrade?
    public private(set) var aiJudging = false
    public private(set) var aiError: String?
    /// "Why was I wrong?" for the current card (F-16).
    public private(set) var whyWrong: String?
    public private(set) var whyWrongLoading = false
    public private(set) var whyWrongError: String?

    /// Whether answers are graded automatically (S-3 on and a grading endpoint exists).
    public var autoGrades: Bool { autoJudge != nil }

    private let recognizer: any SpeechRecognizing
    private let locale: Locale
    private let autoJudge: Judge?
    private let silenceTimeout: Duration?
    private var judgeTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    public init(
        deck: SessionDeck,
        recognizer: any SpeechRecognizing,
        locale: Locale = .current,
        autoJudge: Judge? = nil,
        silenceTimeout: Duration? = .seconds(2)
    ) {
        self.deck = deck
        self.recognizer = recognizer
        self.locale = locale
        self.autoJudge = autoJudge
        self.silenceTimeout = silenceTimeout
        hints = HintProgress(hints: deck.current?.hints ?? [])
    }

    // MARK: Listening

    public func startListening() async {
        guard phase == .awaitingAnswer else { return }
        sttError = nil
        transcript = ""
        clearAI()

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
                onPartial: { [weak self] text in self?.heard(text) },
                onFinal: { [weak self] text in self?.heard(text) },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.sttError = Self.friendlyMessage(for: error)
                    if self.phase == .listening { self.reveal() }
                }
            )
        } catch {
            sttError = Self.friendlyMessage(for: error)
            phase = .awaitingAnswer
        }
    }

    /// A new transcript; restarts the silence timer (F-14: stop after 2 s of silence).
    private func heard(_ text: String) {
        guard phase == .listening else { return }
        transcript = text
        silenceTask?.cancel()
        guard let silenceTimeout, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: silenceTimeout)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.stopListeningAndReveal()
        }
    }

    public func stopListeningAndReveal() {
        recognizer.stop()
        reveal()
    }

    /// *Show answer*: skip the voice step (F-14.5).
    public func revealAnswerWithoutVoice() {
        recognizer.stop()
        reveal()
    }

    private func reveal() {
        silenceTask?.cancel()
        phase = .reveal
        startAutoGrade()
    }

    // MARK: AI

    private func startAutoGrade() {
        guard let autoJudge, let request = judgeRequest() else { return }
        judgeTask?.cancel()
        aiError = nil
        aiJudging = true
        let cardId = deck.current?.id
        judgeTask = Task { [weak self] in
            do {
                let verdict = try await autoJudge(request)
                guard !Task.isCancelled, let self, self.deck.current?.id == cardId else { return }
                self.aiVerdict = AIGrade(verdict: verdict.verdict, reason: verdict.reason)
                self.aiJudging = false
            } catch {
                guard !Task.isCancelled, let self, self.deck.current?.id == cardId else { return }
                self.aiError = Self.message(for: error)
                self.aiJudging = false
            }
        }
    }

    /// *Ask AI to judge* (S-3 off, or after an auto-grade error).
    public func judge(with judge: Judge) async {
        guard let request = judgeRequest(), !aiJudging else { return }
        aiError = nil
        aiJudging = true
        defer { aiJudging = false }
        do {
            let verdict = try await judge(request)
            aiVerdict = AIGrade(verdict: verdict.verdict, reason: verdict.reason)
        } catch {
            aiError = Self.message(for: error)
        }
    }

    /// Whether *Why was I wrong?* is offered: the AI judged the answer partial or wrong.
    public var canAskWhyWrong: Bool {
        guard let aiVerdict else { return false }
        return aiVerdict.verdict == .partial || aiVerdict.verdict == .wrong
    }

    /// F-16: a short contrast between the answer and the reference, kept for the summary.
    public func explainWhyWrong(with explain: Explain) async {
        guard let card = deck.current, canAskWhyWrong, !whyWrongLoading else { return }
        whyWrongError = nil
        whyWrongLoading = true
        defer { whyWrongLoading = false }
        do {
            let text = try await explain(card, transcript)
            guard deck.current?.id == card.id else { return }
            whyWrong = text
            deck.setExplanation(text, for: card.id)
        } catch {
            whyWrongError = Self.message(for: error)
        }
    }

    private func judgeRequest() -> JudgeRequest? {
        guard let card = deck.current, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return JudgeRequest(prompt: card.prompt, userAnswer: transcript, correctShort: card.shortAnswer, correctLong: card.longAnswer)
    }

    private func clearAI() {
        judgeTask?.cancel()
        judgeTask = nil
        aiVerdict = nil
        aiJudging = false
        aiError = nil
        whyWrong = nil
        whyWrongLoading = false
        whyWrongError = nil
    }

    // MARK: Grading

    public func toggleHint() {
        hints.advance()
    }

    /// Records the user's grade with the AI's, if any; a different grade counts as an override.
    public func record(_ verdict: CardVerdict) {
        deck.record(verdict, ai: aiVerdict)
        advance()
    }

    private func advance() {
        clearAI()
        silenceTask?.cancel()
        transcript = ""
        sttError = nil
        deck.next()
        hints = HintProgress(hints: deck.current?.hints ?? [])
        phase = deck.ended ? .ended : .awaitingAnswer
    }

    public func abandon() {
        recognizer.stop()
        clearAI()
        silenceTask?.cancel()
        deck.abandon()
        phase = .ended
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func friendlyMessage(for error: Error) -> String {
        let raw = message(for: error)
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
