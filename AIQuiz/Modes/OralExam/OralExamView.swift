import SwiftUI
import SwiftData
import AIQuizCore
import LLMKit

/// Oral exam (SPEC F-45, §9.2). State lives in `OralExamPlayer`; this view adds the intro,
/// the summary with the examiner's overall comment, and *Practice missed cards* (F-18).
struct OralExamView: View {
    let quiz: QuizRecord
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechServices.self) private var speech
    @Environment(AIRouter.self) private var router
    @State private var player: OralExamPlayer?
    @State private var gate = AIGate()
    @State private var cardCount = 5

    /// 5 to 10 cards (§9.2), or the whole deck when it is smaller.
    private var countRange: ClosedRange<Int> {
        let total = max(1, quiz.cardCount)
        return min(5, total)...min(10, total)
    }

    var body: some View {
        Group {
            if let player {
                OralExamSession(quiz: quiz, player: player) { missed in
                    start(with: missed)
                }
                .id(ObjectIdentifier(player))
            } else {
                intro
            }
        }
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .aiSetupSheet(gate)
        .onAppear { cardCount = min(max(cardCount, countRange.lowerBound), countRange.upperBound) }
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: 24) {
                AccentIcon(systemName: "graduationcap", size: 64)
                Text("Oral exam")
                    .font(.largeTitle.weight(.bold))
                VStack(spacing: 12) {
                    tile("speaker.wave.2", "The examiner asks each question aloud")
                    tile("mic", "Answer out loud; pause when you're done")
                    tile("arrow.turn.down.right", "It may ask one follow-up")
                    tile("checkmark.seal", "Graded at the end")
                }
                if countRange.lowerBound < countRange.upperBound {
                    Stepper(value: $cardCount, in: countRange) {
                        Text("\(cardCount) cards")
                            .font(.headline)
                    }
                    .padding()
                    .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                    .accessibilityIdentifier("oralExam.count")
                }
                Button {
                    start(with: nil)
                } label: {
                    Text("Start exam")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .primaryActionStyle()
                .disabled(quiz.cardCount == 0)
                .accessibilityIdentifier("oralExam.start")
            }
            .padding()
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
    }

    /// The examiner decides follow-ups on the *chat* route and grades on *grading* (§8.2).
    private func start(with missed: [CardSnapshot]?) {
        guard let chat = gate.client(.chat, from: router), let grading = gate.client(.grading, from: router) else { return }
        let cards = missed ?? Array(ScoreStore.ordered(quiz.cards).prefix(cardCount)).map(CardSnapshot.init)
        let player = OralExamPlayer(
            deck: ScoreStore.makeDeck(cards: cards),
            speech: speech.synthesizer,
            recognizer: speech.recognizer,
            audio: speech.audio,
            locale: settings.sttLocale,
            decide: { card, exchanges in try await OralExaminer.decide(card: card, exchanges: exchanges, using: chat) },
            grade: { items in try await OralExaminer.grade(items, using: grading) }
        )
        self.player = player
        player.start()
    }
}

private struct OralExamSession: View {
    let quiz: QuizRecord
    let player: OralExamPlayer
    let onPracticeMissed: ([CardSnapshot]) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var recorded = false

    var body: some View {
        Group {
            switch player.phase {
            case .finished:
                SessionSummaryView(
                    deck: player.deck,
                    onDone: { dismiss() },
                    onPracticeMissed: onPracticeMissed,
                    recap: player.overall.map { overall in { overall } }
                )
            case .unavailable(let message):
                ContentUnavailableView("Can't listen", systemImage: "mic.slash", description: Text(message))
                    .accessibilityIdentifier("oralExam.unavailable")
            default:
                examBody
            }
        }
        .endSessionConfirmation(isEnabled: player.phase != .finished) {
            player.abandon()
            dismiss()
        }
        .onChange(of: player.phase) { _, phase in
            guard phase == .finished else { return }
            record()
        }
        .onDisappear {
            if player.phase != .finished { player.abandon() }
        }
    }

    /// Saves the exam once, with the grader's verdicts and its overall comment as the recap.
    private func record() {
        guard !recorded, !player.deck.outcomes.isEmpty else { return }
        recorded = true
        let session = ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .oralExam, in: context)
        if let overall = player.overall {
            session?.recapText = overall
            try? context.save()
        }
    }

    private var examBody: some View {
        VStack(spacing: 20) {
            SessionProgressHeader(deck: player.deck) {
                Text(stateLabel)
                    .accessibilityIdentifier("oralExam.state")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if player.turn > 1 {
                        Label("Follow-up", systemImage: "arrow.turn.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(player.spoken)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("oralExam.question")
                    if player.phase == .listening || !player.transcript.isEmpty {
                        answerBlock
                    }
                    statusBlock
                }
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
            controls
        }
        .padding()
    }

    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your answer").font(.caption).foregroundStyle(.secondary)
                if player.phase == .listening {
                    Spacer()
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.orange)
                }
            }
            Text(player.transcript.isEmpty ? "Listening…" : player.transcript)
                .foregroundStyle(player.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                .accessibilityIdentifier("oralExam.transcript")
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch player.phase {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking…").foregroundStyle(.secondary)
            }
        case .grading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Grading your answers…").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("oralExam.grading")
        case .gradingFailed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Grading didn't finish: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("oralExam.gradingError")
                Button("Try again", action: player.retryGrading)
                    .primaryActionStyle()
                    .accessibilityIdentifier("oralExam.retry")
            }
        default:
            EmptyView()
        }
    }

    private var stateLabel: String {
        switch player.phase {
        case .ready: return "Starting"
        case .asking: return "Asking"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .grading: return "Grading"
        case .gradingFailed: return "Grading failed"
        case .finished: return "Done"
        case .unavailable: return "Unavailable"
        case .ended: return "Ended"
        }
    }

    private var examRunning: Bool {
        [.asking, .listening, .thinking].contains(player.phase)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: player.skipCard) {
                Label("Skip", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!examRunning)
            .accessibilityIdentifier("oralExam.skip")

            Button(action: player.finishAnswer) {
                Label("Done answering", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .primaryActionStyle()
            .disabled(player.phase != .listening)
            .accessibilityIdentifier("oralExam.done")
        }
        .frame(maxWidth: Theme.readableWidth)
    }
}
