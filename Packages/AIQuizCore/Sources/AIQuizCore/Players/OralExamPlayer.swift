import Foundation
import Observation

/// Oral exam (SPEC F-45, §9.2): the examiner reads a question from each card aloud, listens,
/// and either moves on or asks one follow-up aimed at the gap (two turns per card at most).
/// At the end the model grades every card and the session is recorded with its verdicts.
///
/// The exam holds one play-and-record audio session from start to finish (F-50). The AI
/// never blocks the exam: a failed follow-up decision just moves on; only the final grading
/// waits, and it can be retried.
@Observable
@MainActor
public final class OralExamPlayer {
    public enum Phase: Equatable, Sendable {
        case ready
        /// The examiner is speaking.
        case asking
        case listening
        /// Deciding whether to follow up.
        case thinking
        case grading
        case finished
        case gradingFailed(String)
        /// Listening is not possible (access denied); the exam cannot run.
        case unavailable(String)
        /// Ended early; nothing is recorded.
        case ended
    }

    public typealias Decide = (CardSnapshot, [OralExchange]) async throws -> OralTurnDecision
    public typealias Grade = ([OralExamItem]) async throws -> OralExamResult

    public static let maxTurns = 2

    public let deck: SessionDeck
    public private(set) var phase: Phase = .ready
    /// 1 for the card's question, 2 for the follow-up.
    public private(set) var turn = 1
    /// What the examiner asked or said last.
    public private(set) var spoken = ""
    /// The learner's answer so far, while listening.
    public private(set) var transcript = ""
    public private(set) var exchanges: [UUID: [OralExchange]] = [:]
    /// Two sentences from the grader (F-45 `overall`).
    public private(set) var overall: String?

    private let speech: any SpeechSynthesizing
    private let recognizer: any SpeechRecognizing
    private let audio: AudioSessionCoordinator?
    private let locale: Locale
    private let silenceTimeout: Duration
    private let noSpeechTimeout: Duration
    private let decide: Decide
    private let grade: Grade
    private var task: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<String, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var skipRequested = false
    @ObservationIgnored private var pendingDecision: Task<OralTurnDecision, Error>?
    @ObservationIgnored private var holdsAudio = false

    public init(
        deck: SessionDeck,
        speech: any SpeechSynthesizing,
        recognizer: any SpeechRecognizing,
        audio: AudioSessionCoordinator? = nil,
        locale: Locale = .current,
        silenceTimeout: Duration = .seconds(2.5),
        noSpeechTimeout: Duration = .seconds(12),
        decide: @escaping Decide,
        grade: @escaping Grade
    ) {
        self.deck = deck
        self.speech = speech
        self.recognizer = recognizer
        self.audio = audio
        self.locale = locale
        self.silenceTimeout = silenceTimeout
        self.noSpeechTimeout = noSpeechTimeout
        self.decide = decide
        self.grade = grade
    }

    /// Cards asked so far, including the current one.
    public var askedCount: Int { deck.progress.current }

    public func start() {
        guard phase == .ready else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// *Done*: the learner finished answering before the silence timeout.
    public func finishAnswer() {
        guard phase == .listening else { return }
        completeAnswer()
    }

    /// *Skip*: moves to the next card; a card with no answer is not graded.
    public func skipCard() {
        guard [.asking, .listening, .thinking].contains(phase) else { return }
        skipRequested = true
        pendingDecision?.cancel()
        speech.stop()
        completeAnswer()
    }

    /// *End*: stops the exam; nothing is recorded.
    public func abandon() {
        task?.cancel()
        pendingDecision?.cancel()
        speech.stop()
        completeAnswer()
        deck.abandon()
        phase = .ended
        releaseAudio()
    }

    public func retryGrading() {
        guard case .gradingFailed = phase else { return }
        task = Task { [weak self] in await self?.gradeExam() }
    }

    // MARK: The exam

    private func run() async {
        switch await recognizer.authorisation() {
        case .authorized: break
        case .microphoneDenied:
            phase = .unavailable("The oral exam needs microphone access. Enable it in Settings → AIQuiz.")
            return
        case .speechDenied:
            phase = .unavailable("The oral exam needs speech recognition. Enable it in Settings → AIQuiz.")
            return
        }
        guard !Task.isCancelled else { return }
        holdAudio()

        while !deck.ended, let card = deck.current {
            await examine(card)
            if Task.isCancelled { return }
            deck.next()
        }
        releaseAudio()
        await gradeExam()
    }

    /// Asks the card's question, listens, and asks at most one follow-up.
    private func examine(_ card: CardSnapshot) async {
        skipRequested = false
        var cardExchanges: [OralExchange] = []
        var question = OralExaminer.question(for: card)
        turn = 1
        while turn <= Self.maxTurns {
            transcript = ""
            await say(question)
            if stopped { return }
            let reply = await listen()
            if stopped { return }
            cardExchanges.append(OralExchange(question: question, answer: reply))
            exchanges[card.id] = cardExchanges

            let answered = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard turn < Self.maxTurns, answered else { return }
            phase = .thinking
            let exchangesSoFar = cardExchanges
            let pending = Task { try await decide(card, exchangesSoFar) }
            pendingDecision = pending
            let decision = try? await pending.value
            pendingDecision = nil
            guard let decision, !stopped else { return }
            if let followUp = decision.followUp {
                question = followUp
                turn += 1
            } else {
                if !decision.say.isEmpty { await say(decision.say) }
                return
            }
        }
    }

    private var stopped: Bool { Task.isCancelled || skipRequested }

    private func say(_ text: String) async {
        spoken = text
        phase = .asking
        await speech.speak(text)
    }

    /// Listens until the learner pauses (`silenceTimeout` after the last words), the
    /// recognizer's final result, *Done*, *Skip*, or `noSpeechTimeout` without a word.
    private func listen() async -> String {
        transcript = ""
        phase = .listening
        return await withCheckedContinuation { continuation in
            answer = continuation
            do {
                try recognizer.start(
                    locale: locale,
                    onPartial: { [weak self] text in self?.heard(text, final: false) },
                    onFinal: { [weak self] text in self?.heard(text, final: true) },
                    onError: { [weak self] _ in self?.completeAnswer() }
                )
                restartTimer(noSpeechTimeout)
            } catch {
                completeAnswer()
            }
        }
    }

    private func heard(_ text: String, final: Bool) {
        guard phase == .listening, answer != nil else { return }
        transcript = text
        if final {
            completeAnswer()
        } else {
            restartTimer(silenceTimeout)
        }
    }

    private func restartTimer(_ duration: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.completeAnswer()
        }
    }

    private func completeAnswer() {
        timer?.cancel()
        timer = nil
        guard let continuation = answer else { return }
        answer = nil
        recognizer.stop()
        continuation.resume(returning: transcript)
    }

    private func gradeExam() async {
        let items = deck.cards.compactMap { card in
            exchanges[card.id].map { OralExamItem(card: card, exchanges: $0) }
        }
        guard !items.isEmpty else {
            phase = .finished
            return
        }
        phase = .grading
        do {
            let result = try await grade(items)
            guard !Task.isCancelled else { return }
            for item in items {
                if let grade = result.grades[item.card.id] {
                    deck.recordAll(grade.verdict, for: item.card.id, ai: grade)
                }
            }
            overall = result.overall.isEmpty ? nil : result.overall
            phase = .finished
        } catch {
            guard !Task.isCancelled else { return }
            phase = .gradingFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func holdAudio() {
        guard let audio, !holdsAudio else { return }
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
}
