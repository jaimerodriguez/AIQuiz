import SwiftUI
import SwiftData

struct QuizDetailView: View {
    let quiz: QuizRecord

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
                .disabled(quiz.cards.isEmpty)

                NavigationLink {
                    StudyReadView(quiz: quiz)
                } label: {
                    modeRow(
                        title: "Study — User-paced read",
                        systemImage: "rectangle.portrait.on.rectangle.portrait",
                        subtitle: "Flip-card or all-at-once display."
                    )
                }
                .disabled(quiz.cards.isEmpty)

                NavigationLink {
                    QuizVoiceView(quiz: quiz)
                } label: {
                    modeRow(
                        title: "Quiz — Voice answer",
                        systemImage: "mic.fill",
                        subtitle: "Speak your answer, then self-grade."
                    )
                }
                .disabled(quiz.cards.isEmpty)
            }

            Section("Stats") {
                LabeledContent("Cards", value: "\(quiz.cards.count)")
                LabeledContent("Sessions", value: "\(quiz.sessionCount)")
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
                ForEach(quiz.cards.sorted(by: { $0.orderIndex < $1.orderIndex })) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.prompt).font(.headline)
                        if let s = card.shortAnswer { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                        Text(card.longAnswer).font(.body)
                        if card.correctCount + card.partialCount + card.wrongCount > 0 {
                            historyBadges(card)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recentSessions: [SessionRecord] {
        quiz.sessions
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(5)
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
