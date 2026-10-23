import SwiftUI
import AIQuizCore
import SwiftData

struct QuizDetailView: View {
    let quiz: QuizRecord
    @State private var selectedCard: CardRecord?
    @State private var actions = QuizActions()

    var body: some View {
        List {
            Section("Modes") {
                NavigationLink {
                    StudyVoiceView(quiz: quiz)
                } label: {
                    modeRow(
                        title: "Study — Voice auto-read",
                        systemImage: "speaker.wave.2.fill",
                        subtitle: "Hands-free; the app reads each card aloud."
                    )
                }
                .disabled(quiz.cardCount == 0)
                .accessibilityIdentifier("detail.mode.studyVoice")

                NavigationLink {
                    StudyReadView(quiz: quiz)
                } label: {
                    modeRow(
                        title: "Study — User-paced read",
                        systemImage: "rectangle.portrait.on.rectangle.portrait",
                        subtitle: "Flip-card or all-at-once display."
                    )
                }
                .disabled(quiz.cardCount == 0)
                .accessibilityIdentifier("detail.mode.studyRead")

                NavigationLink {
                    QuizVoiceView(quiz: quiz)
                } label: {
                    modeRow(
                        title: "Quiz — Voice answer",
                        systemImage: "mic.fill",
                        subtitle: "Speak your answer, then self-grade."
                    )
                }
                .disabled(quiz.cardCount == 0)
                .accessibilityIdentifier("detail.mode.quizVoice")

                if quiz.sourceKind != nil {
                    NavigationLink {
                        SourceMaterialsView(quiz: quiz)
                    } label: {
                        modeRow(
                            title: "Read Source Materials",
                            systemImage: "doc.richtext",
                            subtitle: sourceSubtitle
                        )
                    }
                    .accessibilityIdentifier("detail.mode.source")
                }
            }

            if quiz.descriptionText != nil || !quiz.tags.isEmpty || quiz.generatedByModel != nil {
                Section("About") {
                    if let description = quiz.descriptionText {
                        Text(description)
                            .accessibilityIdentifier("detail.description")
                    }
                    if !quiz.tags.isEmpty {
                        Text(quiz.tags.map { "#\($0)" }.joined(separator: " "))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("detail.tags")
                    }
                    if let model = quiz.generatedByModel {
                        LabeledContent("Generated with", value: [quiz.generatedByEndpointName, model].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }

            Section("Stats") {
                LabeledContent("Cards", value: "\(quiz.cardCount)")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.stat.cards")
                LabeledContent("Sessions", value: "\(quiz.sessionCount)")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.stat.sessions")
                if let best = quiz.bestScore {
                    LabeledContent("Best", value: "\(Int((best * 100).rounded()))%")
                }
                if let avg = quiz.averageScore {
                    LabeledContent("Average", value: "\(Int((avg * 100).rounded()))%")
                }
            }

            if !quiz.sessions.isEmpty {
                Section("Recent sessions") {
                    ForEach(recentSessions) { session in
                        sessionRow(session)
                    }
                }
            }

            Section("Cards") {
                ForEach(Array(quiz.sortedCards.enumerated()), id: \.element.id) { index, card in
                    Button {
                        selectedCard = card
                    } label: {
                        cardRow(card)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("detail.card.\(index)")
                }
            }
        }
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    actions.menu(for: quiz, idPrefix: "detail", includeDelete: false)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("detail.more")
            }
        }
        .sheet(item: $selectedCard) { card in
            CardSheet(card: card)
        }
        .quizActions(actions)
    }

    private func cardRow(_ card: CardRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.prompt).font(.headline)
                Spacer()
                if card.cardKind != .recall {
                    Text(card.cardKind.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: Capsule())
                }
            }
            if let s = card.shortAnswer { Text(s).font(.subheadline).foregroundStyle(.secondary) }
            Text(card.longAnswer).font(.body)
            if card.correctCount + card.partialCount + card.wrongCount > 0 {
                historyBadges(card)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "Web page · en.wikipedia.org", "Markdown file · notes.md", "Pasted text" (CR-008).
    private var sourceSubtitle: String {
        switch quiz.sourceKind {
        case .webPage?: return "Web page · \(quiz.sourceTitle ?? quiz.sourceURL?.host ?? "")"
        case .markdownFile?: return "Markdown file · \(quiz.sourceTitle ?? "")"
        case .pastedText?: return "The text this quiz was generated from."
        case nil: return ""
        }
    }

    private var recentSessions: [SessionRecord] {
        quiz.sessions
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .map { $0 }
    }

    @ViewBuilder
    private func sessionRow(_ s: SessionRecord) -> some View {
        HStack {
            Image(systemName: modeIcon(s.sessionMode))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(modeLabel(s.sessionMode)).font(.subheadline)
                Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let pct = s.scorePercent {
                Text("\(Int((pct * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func historyBadges(_ card: CardRecord) -> some View {
        HStack(spacing: 6) {
            if card.correctCount > 0 {
                badge("\(card.correctCount)✓", color: .green)
            }
            if card.partialCount > 0 {
                badge("\(card.partialCount)~", color: .orange)
            }
            if card.wrongCount > 0 {
                badge("\(card.wrongCount)✗", color: .red)
            }
        }
        .font(.caption2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func modeIcon(_ m: SessionMode) -> String {
        switch m {
        case .studyVoice: return "speaker.wave.2.fill"
        case .studyRead: return "rectangle.portrait.on.rectangle.portrait"
        case .quizVoice: return "mic.fill"
        }
    }

    private func modeLabel(_ m: SessionMode) -> String {
        switch m {
        case .studyVoice: return "Study — Voice"
        case .studyRead: return "Study — Read"
        case .quizVoice: return "Quiz — Voice"
        }
    }

    @ViewBuilder
    private func modeRow(
        title: String,
        systemImage: String,
        subtitle: String
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
