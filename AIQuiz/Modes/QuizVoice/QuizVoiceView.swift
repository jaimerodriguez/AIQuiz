import SwiftUI
import AIQuizCore
import LLMKit
import SwiftData

/// Quiz — Voice answer (SPEC F-14, F-15, F-16). State lives in `QuizVoicePlayer`; this view
/// adds the summary, the session recap (F-44) and *Practice missed cards* (F-18).
struct QuizVoiceView: View {
    let quiz: QuizRecord
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechServices.self) private var speech
    @Environment(AIRouter.self) private var router
    @State private var player: QuizVoicePlayer?

    var body: some View {
        Group {
            if let player {
                QuizVoiceSession(quiz: quiz, player: player) { missed in
                    self.player = makePlayer(ScoreStore.makeDeck(cards: missed))
                }
                .id(ObjectIdentifier(player))
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if player == nil { player = makePlayer(ScoreStore.makeQuizDeck(for: quiz, cap: settings.sessionCap, includeNotDue: settings.includeNotDue)) }
        }
    }

    private func makePlayer(_ deck: SessionDeck) -> QuizVoicePlayer {
        // S-3: auto-grade when it is on and a grading endpoint is ready.
        let router = self.router
        let autoJudge: QuizVoicePlayer.Judge? = settings.autoGrade && router.issue(for: .grading) == nil
            ? { request in try await AnswerJudge.judge(request, using: try router.client(for: .grading)) }
            : nil
        return QuizVoicePlayer(deck: deck, recognizer: speech.recognizer, locale: settings.sttLocale, autoJudge: autoJudge)
    }
}

private struct QuizVoiceSession: View {
    let quiz: QuizRecord
    let player: QuizVoicePlayer
    let onPracticeMissed: ([CardSnapshot]) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AIRouter.self) private var router
    @State private var gate = AIGate()
    @State private var recorded: SessionRecord?

    var body: some View {
        Group {
            if player.phase == .ended {
                SessionSummaryView(
                    deck: player.deck,
                    onDone: { dismiss() },
                    onPracticeMissed: onPracticeMissed,
                    recap: recapRequest,
                    onRecap: { text in
                        recorded?.recapText = text
                        try? context.save()
                    }
                )
            } else {
                sessionBody
            }
        }
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .endSessionConfirmation(isEnabled: player.phase != .ended) {
            player.abandon()
            dismiss()
        }
        .tutorChatButton(quiz: player.phase == .ended ? nil : quiz, card: player.deck.current, isEnabled: player.phase != .listening)
        .aiSetupSheet(gate)
        .onChange(of: player.phase) { _, phase in
            if phase == .ended {
                recorded = ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .quizVoice, in: context)
            }
        }
    }

    /// F-44: a two-sentence recap, when a grading endpoint is ready and something was graded.
    private var recapRequest: (() async throws -> String)? {
        guard router.issue(for: .grading) == nil, !player.deck.scoredCards.isEmpty else { return nil }
        let router = self.router
        let quizName = quiz.name
        let results = player.deck.scoredCards.map { (card: CardPayload($0.card), verdict: $0.verdict) }
        return { try await SessionRecapper.recap(quizName: quizName, results: results, using: try router.client(for: .grading)) }
    }

    private var sessionBody: some View {
        VStack(spacing: 16) {
            SessionProgressHeader(deck: player.deck)
            if let card = player.deck.current {
                ScrollView {
                    CardFaceView(card: card, showsAnswer: player.phase == .reveal, answerCaption: "Correct answer", hints: player.hints.shown) {
                        if player.phase == .listening || (player.phase == .reveal && !player.transcript.isEmpty) {
                            transcriptBlock
                        }
                    } footer: {
                        if player.phase == .reveal {
                            aiBlock
                        }
                        if let error = player.sttError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }
            Spacer(minLength: 0)
            controls
        }
        .padding()
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your answer").font(.caption).foregroundStyle(.secondary)
                if player.phase == .listening {
                    Spacer()
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.tint)
                }
            }
            Text(player.transcript.isEmpty ? "Listening…" : player.transcript)
                .foregroundStyle(player.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("quiz.transcript")
        }
    }

    /// The AI verdict chip, its progress, and *Why was I wrong?* (F-15, F-16).
    @ViewBuilder
    private var aiBlock: some View {
        if player.aiJudging {
            HStack(spacing: 8) {
                ProgressView()
                Text("AI is grading…").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("quiz.aiJudging")
        }
        if let verdict = player.aiVerdict {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("AI: \(verdict.verdict.rawValue.capitalized)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color(for: verdict.verdict))
                }
                Text(verdict.reason).font(.footnote).foregroundStyle(.secondary)
                if player.canAskWhyWrong {
                    if let why = player.whyWrong {
                        Text(why)
                            .font(.footnote)
                            .padding(.top, 2)
                            .accessibilityIdentifier("quiz.whyWrongText")
                    } else {
                        Button {
                            Task { await askWhyWrong() }
                        } label: {
                            if player.whyWrongLoading {
                                HStack { ProgressView(); Text("Explaining…") }
                            } else {
                                Label("Why was I wrong?", systemImage: "questionmark.bubble")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.whyWrongLoading)
                        .accessibilityIdentifier("quiz.whyWrong")
                    }
                    if let error = player.whyWrongError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quiz.aiVerdict")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch player.phase {
        case .awaitingAnswer:
            VStack(spacing: 12) {
                Button {
                    Task { await player.startListening() }
                } label: {
                    Label("Tap to answer", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("quiz.tapToAnswer")
                HStack {
                    HintButton(progress: player.hints, action: player.toggleHint)
                    Button(action: player.revealAnswerWithoutVoice) {
                        Label("Show answer", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("quiz.showAnswer")
                }
            }
        case .listening:
            Button(action: player.stopListeningAndReveal) {
                Label("Stop & reveal", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("quiz.stopReveal")
        case .reveal:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    gradeButton("Wrong", systemImage: "xmark", verdict: .wrong, id: "quiz.grade.wrong")
                    gradeButton("Partial", systemImage: "circle.lefthalf.filled", verdict: .partial, id: "quiz.grade.partial")
                    gradeButton("Correct", systemImage: "checkmark", verdict: .correct, id: "quiz.grade.correct")
                }
                if showsAskAI {
                    Button {
                        Task { await askAIToJudge() }
                    } label: {
                        Label("Ask AI to judge", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(player.aiJudging || player.transcript.isEmpty)
                    .accessibilityIdentifier("quiz.askAI")
                }
                if let error = player.aiError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("quiz.aiError")
                }
            }
        case .ended:
            EmptyView()
        }
    }

    /// *Ask AI to judge* when auto-grade is off, or to retry after it failed (S-3).
    private var showsAskAI: Bool {
        player.aiVerdict == nil && !player.aiJudging && (!player.autoGrades || player.aiError != nil)
    }

    /// The grade the AI chose is filled; the others stay outlined. Without an AI verdict,
    /// Correct is filled as before. The user's tap always decides (F-15).
    @ViewBuilder
    private func gradeButton(_ title: String, systemImage: String, verdict: CardVerdict, id: String) -> some View {
        let selected = player.aiVerdict.map { $0.verdict == verdict } ?? (verdict == .correct)
        let button = Button { player.record(verdict) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        Group {
            if selected { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .tint(color(for: verdict))
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected && player.aiVerdict != nil ? .isSelected : [])
    }

    private func color(for verdict: CardVerdict) -> Color {
        switch verdict {
        case .correct: return .green
        case .partial: return .orange
        case .wrong: return .red
        case .skipped: return .secondary
        }
    }

    private func askAIToJudge() async {
        guard let client = gate.client(.grading, from: router) else { return }
        await player.judge { request in try await AnswerJudge.judge(request, using: client) }
    }

    private func askWhyWrong() async {
        guard let client = gate.client(.grading, from: router) else { return }
        await player.explainWhyWrong { card, answer in
            try await Explainer.whyWrong(CardPayload(card), answer: answer, using: client)
        }
    }
}
