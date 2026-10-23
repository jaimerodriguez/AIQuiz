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

/// The card: prompt, then mode-specific content, the answer when shown, then the hint.
struct CardFaceView<Middle: View, Footer: View>: View {
    let card: CardSnapshot
    var showsAnswer: Bool
    /// A caption above the answer, e.g. "Correct answer" in quiz mode.
    var answerCaption: String?
    var hintRevealed: Bool
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
            if hintRevealed, let hint = card.hint {
                Text(hint)
                    .font(typo.bodyFont)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("session.card.hint")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension CardFaceView where Middle == EmptyView, Footer == EmptyView {
    init(card: CardSnapshot, showsAnswer: Bool, hintRevealed: Bool) {
        self.init(card: card, showsAnswer: showsAnswer, answerCaption: nil, hintRevealed: hintRevealed) { EmptyView() } footer: { EmptyView() }
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

/// The Hint button every mode shows; the hint itself appears on the card face.
struct HintButton: View {
    let hint: String?
    let revealed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(revealed ? "Hide hint" : "Hint", systemImage: "lightbulb")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(hint == nil)
        .accessibilityIdentifier("session.hint")
    }
}

extension View {
    /// An *End* toolbar button with the "End session?" confirmation (SPEC §5). Ending
    /// discards the session.
    func endSessionConfirmation(isEnabled: Bool = true, onEnd: @escaping () -> Void) -> some View {
        modifier(EndSessionConfirmation(isEnabled: isEnabled, onEnd: onEnd))
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
    let onEnd: () -> Void
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            confirming = true
                        } label: {
                            Label("End", systemImage: "xmark.circle")
                        }
                        .accessibilityIdentifier("session.end")
                    }
                }
            }
            .alert("End session?", isPresented: $confirming) {
                Button("End", role: .destructive, action: onEnd)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your progress in this session won't be saved.")
            }
    }
}
