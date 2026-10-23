import SwiftUI
import AIQuizCore
import SwiftData

/// Study — User-paced read (SPEC F-13). State lives in `StudyReadPlayer`.
struct StudyReadView: View {
    let quiz: QuizRecord
    @Environment(AppSettings.self) private var settings
    @State private var player: StudyReadPlayer?

    var body: some View {
        Group {
            if let player {
                StudyReadSession(quiz: quiz, player: player)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if player == nil {
                player = StudyReadPlayer(deck: ScoreStore.makeDeck(for: quiz), style: settings.studyReadStyle)
            }
        }
    }
}

private struct StudyReadSession: View {
    let quiz: QuizRecord
    @Bindable var player: StudyReadPlayer
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            SessionProgressHeader(deck: player.deck)
            if let card = player.deck.current {
                CardFaceView(card: card, showsAnswer: player.showsAnswer, answerCaption: nil, hints: player.hints.shown) {
                    EmptyView()
                } footer: {
                    if !player.showsAnswer {
                        Button {
                            withAnimation { player.reveal() }
                        } label: {
                            Label("Tap to reveal", systemImage: "hand.tap")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("studyRead.reveal")
                    }
                    HintButton(progress: player.hints) {
                        withAnimation { player.toggleHint() }
                    }
                }
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }
            Spacer()
            controls
        }
        .padding()
        .swipeToNavigate(onNext: player.next, onBack: player.back)
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Style", selection: $player.style) {
                    ForEach(StudyReadStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityIdentifier("studyRead.style")
            }
        }
        .endSessionConfirmation {
            player.abandon()
            dismiss()
        }
        .onChange(of: player.finished) { _, finished in
            guard finished else { return }
            ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .studyRead, in: context)
            dismiss()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: player.back) {
                Label("Back", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(player.deck.atStart)
            .accessibilityIdentifier("studyRead.back")

            Button(action: player.next) {
                Label(player.deck.atEnd ? "Done" : "Next", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("studyRead.next")
        }
    }
}
