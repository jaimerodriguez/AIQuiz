import SwiftUI
import AIQuizCore

// Shared pieces of every study and quiz screen (SPEC §5, REVIEW §4.4).

/// "Card n of N" with a progress bar and an optional trailing status.
struct SessionProgressHeader<Trailing: View>: View {
    let deck: SessionDeck
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let progress = deck.progress
        VStack(spacing: 4) {
            ProgressView(value: Double(progress.current), total: Double(progress.total))
            HStack {
                Text("Card \(progress.current) of \(progress.total)")
                    .accessibilityIdentifier("session.progress")
                Spacer()
                trailing
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension SessionProgressHeader where Trailing == EmptyView {
    init(deck: SessionDeck) {
        self.init(deck: deck) { EmptyView() }
    }
}

/// The card: prompt, then mode-specific content, the answer when shown, then the hints.
struct CardFaceView<Middle: View, Footer: View>: View {
    let card: CardSnapshot
    var showsAnswer: Bool
    /// A caption above the answer, e.g. "Correct answer" in quiz mode.
    var answerCaption: String?
    /// Hints revealed so far, weakest first (F-24).
    var hints: [String]
    @ViewBuilder var middle: Middle
    @ViewBuilder var footer: Footer
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let typo = settings.quizFontSize
        VStack(alignment: .leading, spacing: 16) {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("session.card.prompt")
            middle
            if showsAnswer {
                if let answerCaption {
                    Divider()
                    Text(answerCaption).font(.caption).foregroundStyle(.secondary)
                }
                AnswerBlock(card: card)
            }
            footer
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                Label(hint, systemImage: "lightbulb")
                    .font(typo.bodyFont)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(index == 0 ? "session.card.hint" : "session.card.hint.\(index)")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension CardFaceView where Middle == EmptyView, Footer == EmptyView {
    init(card: CardSnapshot, showsAnswer: Bool, hints: [String]) {
        self.init(card: card, showsAnswer: showsAnswer, answerCaption: nil, hints: hints) { EmptyView() } footer: { EmptyView() }
    }
}

/// Short answer (emphasised) and long answer.
struct AnswerBlock: View {
    let card: CardSnapshot
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let typo = settings.quizFontSize
        VStack(alignment: .leading, spacing: 8) {
            if let short = card.shortAnswer {
                Text(short)
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
}

/// The Hint button every mode shows: each tap reveals the next hint (the author's, then
/// stored AI hints, F-24); after the last, it hides them. Hints appear on the card face.
/// In a deck where no card has a hint there is no button at all; where some cards do, it is
/// disabled on the others, so the controls don't move from card to card.
struct HintButton: View {
    let progress: HintProgress
    let deck: SessionDeck
    let action: () -> Void

    var body: some View {
        if deck.hasHints {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(progress.buttonLabel, systemImage: "lightbulb")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!progress.isAvailable)
        .accessibilityIdentifier("session.hint")
    }
}

extension View {
    /// The back arrow asks "End session?" while a session runs (SPEC §5, CR-020); ending
    /// discards the session. Once it has ended (the summary), back simply goes back.
    /// `onAsk` runs as the question appears (pause what would carry on behind it) and
    /// `onCancel` when the user stays.
    func endSessionConfirmation(isEnabled: Bool = true, onAsk: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}, onEnd: @escaping () -> Void) -> some View {
        modifier(EndSessionConfirmation(isEnabled: isEnabled, onAsk: onAsk, onCancel: onCancel, onEnd: onEnd))
    }

    /// Swipe right for next, left for back (SPEC §5).
    func swipeToNavigate(onNext: @escaping () -> Void, onBack: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                        if dx > 0 { onNext() } else { onBack() }
                    }
            )
    }
}

private struct EndSessionConfirmation: ViewModifier {
    let isEnabled: Bool
    let onAsk: () -> Void
    let onCancel: () -> Void
    let onEnd: () -> Void
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            // The system back arrow (and the edge swipe) would leave without asking.
            .navigationBarBackButtonHidden(isEnabled)
            .toolbar {
                if isEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onAsk()
                            confirming = true
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Back")
                        .accessibilityHint("Ends the session")
                        .accessibilityIdentifier("session.end")
                    }
                }
            }
            .alert("End session?", isPresented: $confirming) {
                Button("End", role: .destructive, action: onEnd)
                Button("Cancel", role: .cancel, action: onCancel)
            } message: {
                Text("Your progress in this session won't be saved.")
            }
    }
}
