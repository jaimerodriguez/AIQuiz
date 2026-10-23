import SwiftUI
import AIQuizCore
import SwiftData

/// Study — Voice auto-read (SPEC F-11). State lives in `StudyVoicePlayer`.
struct StudyVoiceView: View {
    let quiz: QuizRecord
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechServices.self) private var speech
    @State private var player: StudyVoicePlayer?

    var body: some View {
        Group {
            if let player {
                StudyVoiceSession(quiz: quiz, player: player)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard player == nil else { return }
            player = StudyVoicePlayer(
                deck: ScoreStore.makeDeck(for: quiz),
                speech: speech.synthesizer,
                pauseSeconds: settings.studyVoicePauseSeconds,
                repeatCount: settings.studyVoiceRepeatCount
            )
        }
    }
}

private struct StudyVoiceSession: View {
    let quiz: QuizRecord
    let player: StudyVoicePlayer
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            SessionProgressHeader(deck: player.deck) {
                Text(stateLabel)
                    .accessibilityIdentifier("studyVoice.state")
            }
            if let card = player.deck.current {
                CardFaceView(card: card, showsAnswer: true, hintRevealed: player.hintRevealed)
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }
            Spacer()
            controls
        }
        .padding()
        .swipeToNavigate(onNext: player.skip, onBack: player.back)
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .endSessionConfirmation {
            player.abandon()
            dismiss()
        }
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: player.state) { _, state in
            guard state == .ended, !player.deck.abandoned else { return }
            ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .studyVoice, in: context)
            dismiss()
        }
    }

    private var stateLabel: String {
        switch player.state {
        case .idle: return "Ready"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .ended: return "Done"
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton("Back", systemImage: "backward.fill", id: "studyVoice.back", action: player.back)
                    .disabled(player.deck.atStart)
                controlButton("Repeat", systemImage: "arrow.counterclockwise", id: "studyVoice.repeat", action: player.repeatCard)
                if player.state == .playing {
                    controlButton("Pause", systemImage: "pause.fill", id: "studyVoice.pause", prominent: true, action: player.pause)
                } else {
                    controlButton("Play", systemImage: "play.fill", id: "studyVoice.play", prominent: true, action: player.start)
                }
                controlButton("Skip", systemImage: "forward.fill", id: "studyVoice.skip", action: player.skip)
            }
            HintButton(hint: player.deck.current?.hint, revealed: player.hintRevealed, action: player.toggleHint)
        }
    }

    /// Play / Pause is the main control, so it carries the accent.
    @ViewBuilder
    private func controlButton(_ title: String, systemImage: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        Group {
            if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .accessibilityIdentifier(id)
    }
}
