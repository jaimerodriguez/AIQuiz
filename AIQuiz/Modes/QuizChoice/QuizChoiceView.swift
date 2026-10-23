import SwiftUI
import AIQuizCore
import SwiftData

/// Quiz — Choice (SPEC F-17). State lives in `ChoicePlayer`; this view adds the summary,
/// the recap (F-44) and *Practice missed cards* (F-18).
struct QuizChoiceView: View {
    let quiz: QuizRecord
    @State private var player: ChoicePlayer?

    var body: some View {
        Group {
            if let player {
                QuizChoiceSession(quiz: quiz, player: player) { missed in
                    self.player = ChoicePlayer(deck: ScoreStore.makeDeck(cards: missed))
                }
                .id(ObjectIdentifier(player))
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if player == nil { player = ChoicePlayer(deck: ScoreStore.makeDeck(for: quiz)) }
        }
    }
}

private struct QuizChoiceSession: View {
    let quiz: QuizRecord
    @Bindable var player: ChoicePlayer
    let onPracticeMissed: ([CardSnapshot]) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AIRouter.self) private var router
    @State private var recorded: SessionRecord?

    var body: some View {
        Group {
            if player.stage == .ended {
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
        .endSessionConfirmation(isEnabled: player.stage != .ended) {
            player.abandon()
            dismiss()
        }
        .onChange(of: player.stage) { _, stage in
            if stage == .ended {
                recorded = ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .quizChoice, in: context)
            }
        }
    }

    private var recapRequest: (() async throws -> String)? {
        guard router.issue(for: .grading) == nil, !player.deck.scoredCards.isEmpty else { return nil }
        let router = self.router
        let quizName = quiz.name
        let results = player.deck.scoredCards.map { (card: CardPayload($0.card), verdict: $0.verdict) }
        return { try await SessionRecapper.recap(quizName: quizName, results: results, using: try router.client(for: .grading)) }
    }

    private var sessionBody: some View {
        VStack(spacing: 16) {
            SessionProgressHeader(deck: player.deck) {
                if let kind = player.card?.kind { Text(kind.label).accessibilityIdentifier("choice.kind") }
            }
            if let card = player.card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        prompt(card)
                        answerArea(card)
                            .id(card.id)
                        if player.stage == .checked { result(card) }
                        ForEach(Array(player.hints.shown.enumerated()), id: \.offset) { _, hint in
                            Label(hint, systemImage: "lightbulb")
                                .font(settings.quizFontSize.bodyFont)
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Spacer(minLength: 0)
            controls
        }
        .padding()
    }

    // MARK: Card

    @ViewBuilder
    private func prompt(_ card: CardSnapshot) -> some View {
        let typo = settings.quizFontSize
        if card.kind == .cloze {
            Text(Cloze.segments(card.prompt).joined(separator: " ____ "))
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("session.card.prompt")
        } else {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("session.card.prompt")
        }
    }

    @ViewBuilder
    private func answerArea(_ card: CardSnapshot) -> some View {
        switch card.kind {
        case .multipleChoice, .trueFalse:
            VStack(spacing: 10) {
                ForEach(Array(player.shownOptions.enumerated()), id: \.offset) { index, option in
                    optionButton(option, index: index)
                }
            }
        case .cloze:
            VStack(spacing: 10) {
                ForEach(player.blankAnswers.indices, id: \.self) { index in
                    // Bounds-checked: when the next card has fewer blanks, a stale field must
                    // not read past the end (an array-index binding crashes there).
                    TextField(player.blankAnswers.count == 1 ? "The missing words" : "Blank \(index + 1)", text: blankBinding(index))
                        .textFieldStyle(.roundedBorder)
                        .font(settings.quizFontSize.bodyFont)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(player.stage != .asking)
                        .submitLabel(.done)
                        .onSubmit { player.checkBlanks() }
                        .accessibilityIdentifier("choice.blank.\(index)")
                }
            }
        case .recall:
            if player.stage == .checked {
                AnswerBlock(card: card)
            }
        }
    }

    private func blankBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < player.blankAnswers.count ? player.blankAnswers[index] : "" },
            set: { if index < player.blankAnswers.count { player.blankAnswers[index] = $0 } }
        )
    }

    /// An option: neutral while asking; then the right one green and a wrong pick red.
    private func optionButton(_ option: String, index: Int) -> some View {
        let checked = player.stage == .checked
        let isRight = player.rightAnswer.map { ChoicePlayer.isSame(option, $0) } ?? false
        let isChosen = player.chosen == option
        let fill: Color = checked ? (isRight ? .green : (isChosen ? .red : .clear)) : .clear
        return Button {
            player.choose(option)
        } label: {
            HStack {
                Text(option).font(settings.quizFontSize.bodyFont).multilineTextAlignment(.leading)
                Spacer()
                if checked && isRight { Image(systemName: "checkmark.circle.fill") }
                if checked && isChosen && !isRight { Image(systemName: "xmark.circle.fill") }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(checked && (isRight || isChosen) ? .white : .primary)
            .background(fill == .clear ? AnyShapeStyle(.background) : AnyShapeStyle(fill), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // Not disabled after checking (that would fade the colours); the player ignores a second tap.
        .allowsHitTesting(!checked)
        .accessibilityIdentifier("choice.option.\(index)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder
    private func result(_ card: CardSnapshot) -> some View {
        if card.kind != .recall, let verdict = player.verdict {
            VStack(alignment: .leading, spacing: 6) {
                Label(verdict.rawValue.capitalized + (player.overridden ? " (your call)" : ""),
                      systemImage: verdict == .correct ? "checkmark.seal.fill" : verdict == .partial ? "circle.lefthalf.filled" : "xmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(color(verdict))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("choice.verdict")
                if card.kind == .cloze, let right = player.rightAnswer {
                    Text("Answer: \(right)").font(.subheadline)
                }
                Text(card.longAnswer).font(settings.quizFontSize.bodyFont).foregroundStyle(.secondary)
                if let explanation = card.explanation {
                    Label(explanation, systemImage: "text.bubble").font(.footnote)
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch (player.stage, player.card?.kind) {
        case (.asking, .cloze?):
            HStack {
                HintButton(progress: player.hints, action: player.toggleHint)
                Button("Check") { player.checkBlanks() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(player.blankAnswers.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .accessibilityIdentifier("choice.check")
            }
        case (.asking, .recall?):
            HStack {
                HintButton(progress: player.hints, action: player.toggleHint)
                Button { player.reveal() } label: {
                    Label("Show answer", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("choice.reveal")
            }
        case (.asking, _):
            HintButton(progress: player.hints, action: player.toggleHint)
        case (.checked, .recall?):
            HStack(spacing: 8) {
                gradeButton("Wrong", "xmark", .wrong)
                gradeButton("Partial", "circle.lefthalf.filled", .partial)
                gradeButton("Correct", "checkmark", .correct)
            }
        case (.checked, _):
            HStack(spacing: 12) {
                Menu {
                    Button("Correct") { player.override(.correct) }
                    Button("Partly right") { player.override(.partial) }
                    Button("Wrong") { player.override(.wrong) }
                } label: {
                    Label("Mark as…", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("choice.override")
                Button { player.next() } label: {
                    Label(player.deck.atEnd ? "Finish" : "Next", systemImage: "chevron.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("choice.next")
            }
        case (.ended, _):
            EmptyView()
        }
    }

    /// Recall cards in a choice deck: self-grade, then move on (F-17).
    private func gradeButton(_ title: String, _ icon: String, _ verdict: CardVerdict) -> some View {
        Button {
            player.override(verdict)
            player.next()
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(color(verdict))
        .accessibilityIdentifier("choice.grade.\(verdict.rawValue)")
    }

    private func color(_ verdict: CardVerdict) -> Color {
        switch verdict {
        case .correct: return .green
        case .partial: return .orange
        case .wrong: return .red
        case .skipped: return .secondary
        }
    }
}
