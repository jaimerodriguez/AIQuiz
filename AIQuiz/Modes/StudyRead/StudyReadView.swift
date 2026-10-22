import SwiftUI
import AIQuizCore
import SwiftData

struct StudyReadView: View {
    let quiz: QuizRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var deck: SessionDeck
    @State private var style: StudyReadStyle = .flipCard
    @State private var styleInitialised: Bool = false
    @State private var revealed: Bool = false
    @State private var showAbandonAlert: Bool = false
    @State private var sessionRecorded: Bool = false

    init(quiz: QuizRecord) {
        self.quiz = quiz
        _deck = State(wrappedValue: ScoreStore.makeDeck(for: quiz))
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
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
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
                .accessibilityIdentifier("studyRead.style")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    showAbandonAlert = true
                } label: {
                    Label("End", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("session.end")
            }
        }
        .onAppear {
            if !styleInitialised {
                style = settings.studyReadStyle
                styleInitialised = true
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
                .accessibilityIdentifier("session.progress")
        }
    }

    @ViewBuilder
    private func cardView(_ card: CardSnapshot) -> some View {
        let typo = settings.quizFontSize
        VStack(alignment: .leading, spacing: 16) {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("session.card.prompt")

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
                    .accessibilityIdentifier("studyRead.reveal")
                }
            case .allAtOnce:
                answerBlock(card, typo: typo)
            }

            HintButton(hint: card.hint)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                if dx > 0 {
                    if deck.atEnd {
                        recordIfNeeded()
                        dismiss()
                    } else {
                        deck.next()
                    }
                } else {
                    if !deck.atStart { deck.back() }
                }
            }
    }

    @ViewBuilder
    private func answerBlock(_ card: CardSnapshot, typo: QuizFontSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = card.shortAnswer {
                Text(s)
                    .font(typo.emphasisFont)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("session.card.shortAnswer")
            }
            Text(card.longAnswer)
                .font(typo.bodyFont)
                .accessibilityIdentifier("session.card.longAnswer")
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
            .accessibilityIdentifier("studyRead.back")

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
            .accessibilityIdentifier("studyRead.next")
        }
    }
}
