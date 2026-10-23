import SwiftUI
import AIQuizCore
import SwiftData

/// Quiz — Voice answer (SPEC F-14). State lives in `QuizVoicePlayer`; this view adds the
/// summary and *Practice missed cards*, which starts a new recorded session (F-18).
struct QuizVoiceView: View {
    let quiz: QuizRecord
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechServices.self) private var speech
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
            if player == nil { player = makePlayer(ScoreStore.makeDeck(for: quiz)) }
        }
    }

    private func makePlayer(_ deck: SessionDeck) -> QuizVoicePlayer {
        QuizVoicePlayer(deck: deck, recognizer: speech.recognizer, locale: settings.sttLocale)
    }
}

private struct QuizVoiceSession: View {
    let quiz: QuizRecord
    let player: QuizVoicePlayer
    let onPracticeMissed: ([CardSnapshot]) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AIRouter.self) private var router
    @State private var showProviderSetup = false
    @State private var setupIssue: String?

    var body: some View {
        Group {
            if player.phase == .ended {
                SessionSummaryView(deck: player.deck, onDone: { dismiss() }, onPracticeMissed: onPracticeMissed)
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
        .sheet(isPresented: $showProviderSetup) {
            NavigationStack { EndpointsListView(setupIssue: setupIssue, showsDoneButton: true) }
        }
        .onChange(of: player.phase) { _, phase in
            if phase == .ended {
                ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .quizVoice, in: context)
            }
        }
    }

    private var sessionBody: some View {
        VStack(spacing: 16) {
            SessionProgressHeader(deck: player.deck)
            if let card = player.deck.current {
                CardFaceView(card: card, showsAnswer: player.phase == .reveal, answerCaption: "Correct answer", hintRevealed: player.hintRevealed) {
                    if player.phase == .listening || (player.phase == .reveal && !player.transcript.isEmpty) {
                        transcriptBlock
                    }
                } footer: {
                    if let verdict = player.aiVerdict, player.phase == .reveal {
                        aiVerdictBlock(verdict)
                    }
                    if let error = player.sttError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }
            Spacer()
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

    private func aiVerdictBlock(_ v: QuizVoicePlayer.AIVerdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "sparkles")
                Text("AI verdict: \(v.verdict.rawValue.capitalized)")
                    .font(.subheadline.weight(.medium))
            }
            Text(v.reason).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("quiz.aiVerdict")
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
                    HintButton(hint: player.deck.current?.hint, revealed: player.hintRevealed, action: player.toggleHint)
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
                    gradeButton("Wrong", systemImage: "xmark", tint: .red, id: "quiz.grade.wrong", verdict: .wrong)
                    gradeButton("Partial", systemImage: "circle.lefthalf.filled", tint: .orange, id: "quiz.grade.partial", verdict: .partial)
                    gradeButton("Correct", systemImage: "checkmark", tint: .green, id: "quiz.grade.correct", verdict: .correct, prominent: true)
                }
                Button {
                    Task { await askAIToJudge() }
                } label: {
                    HStack {
                        if player.aiJudging {
                            ProgressView()
                            Text("Asking AI…")
                        } else {
                            Label("Ask AI to judge", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(player.aiJudging || player.transcript.isEmpty)
                .accessibilityIdentifier("quiz.askAI")
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

    @ViewBuilder
    private func gradeButton(_ title: String, systemImage: String, tint: Color, id: String, verdict: CardVerdict, prominent: Bool = false) -> some View {
        let button = Button { player.record(verdict) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        Group {
            if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .tint(tint)
        .accessibilityIdentifier(id)
    }

    private func askAIToJudge() async {
        if let issue = router.issue(for: .grading) {
            setupIssue = issue.localizedDescription
            showProviderSetup = true
            return
        }
        await player.judge { request in
            try await AnswerJudge.judge(request, using: try router.client(for: .grading))
        }
    }
}
