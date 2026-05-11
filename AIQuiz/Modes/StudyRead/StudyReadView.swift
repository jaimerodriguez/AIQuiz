import SwiftUI
import SwiftData

struct StudyReadView: View {
    let quiz: QuizRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var deck: SessionDeck
    @State private var style: StudyReadStyle
    @State private var revealed: Bool = false
    @State private var showAbandonAlert: Bool = false
    @State private var sessionRecorded: Bool = false

    init(quiz: QuizRecord) {
        self.quiz = quiz
        _deck = State(wrappedValue: ScoreStore.makeDeck(for: quiz))
        _style = State(wrappedValue: AppSettings.shared.studyReadStyle)
    }

    private func recordIfNeeded() {
        guard !sessionRecorded, !deck.abandoned else { return }
        sessionRecorded = true
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .studyRead, in: context)
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            if let card = deck.current {
                cardView(card)
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }

            Spacer()

            controls
        }
        .padding()
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Style", selection: $style) {
                    ForEach(StudyReadStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    showAbandonAlert = true
                } label: {
                    Label("End", systemImage: "xmark.circle")
                }
            }
        }
        .onChange(of: style) { _, _ in revealed = false }
        .onChange(of: deck.index) { _, _ in revealed = false }
        .alert("End session?", isPresented: $showAbandonAlert) {
            Button("End", role: .destructive) {
                deck.abandon()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress in this session won't be saved.")
        }
    }

    private var header: some View {
        let progress = deck.progress
        return VStack(spacing: 4) {
            ProgressView(value: Double(progress.current), total: Double(progress.total))
            Text("Card \(progress.current) of \(progress.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cardView(_ card: CardRecord) -> some View {
        let typo = AppSettings.shared.quizFontSize
        VStack(alignment: .leading, spacing: 16) {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch style {
            case .flipCard:
                if revealed {
                    answerBlock(card, typo: typo)
                } else {
                    Button {
                        withAnimation { revealed = true }
                    } label: {
                        Label("Tap to reveal", systemImage: "hand.tap")
                            .font(typo.bodyFont)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            case .allAtOnce:
                answerBlock(card, typo: typo)
            }

            HintButton(hint: card.hint)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func answerBlock(_ card: CardRecord, typo: QuizFontSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = card.shortAnswer {
                Text(s)
                    .font(typo.emphasisFont)
                    .foregroundStyle(.tint)
            }
            Text(card.longAnswer)
                .font(typo.bodyFont)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                deck.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(deck.atStart)

            Button {
                if deck.atEnd {
                    recordIfNeeded()
                    dismiss()
                } else {
                    deck.next()
                }
            } label: {
                Label(deck.atEnd ? "Done" : "Next", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
