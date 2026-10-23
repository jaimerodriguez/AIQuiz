import SwiftUI
import AIQuizCore
import SwiftData

struct QuizDetailView: View {
    let quiz: QuizRecord

    @Environment(\.modelContext) private var context
    @Environment(AIRouter.self) private var router
    @State private var creatingNotes = false
    @State private var notesWords = 0
    @State private var notesError: String?
    @State private var showSetup = false
    @State private var setupIssue: String?

    var body: some View {
        List {
            studySection

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
                .disabled(quiz.cards.isEmpty)
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
                .disabled(quiz.cards.isEmpty)
                .accessibilityIdentifier("detail.mode.quizVoice")
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
        .sheet(isPresented: $showSetup) {
            NavigationStack { EndpointsListView(setupIssue: setupIssue, showsDoneButton: true) }
        }
    }

    // MARK: Study material (CR-006)

    @ViewBuilder
    private var studySection: some View {
        Section {
            if let notes = quiz.studyNotes {
                NavigationLink {
                    StudyNotesView(title: "\(quiz.name): study notes", markdown: notes, sourceURL: quiz.sourceURL)
                } label: {
                    LabeledContent {
                        Text("\(StudyNotesWriter.wordCount(notes)) words")
                    } label: {
                        Label("Study notes", systemImage: "doc.richtext")
                    }
                }
                .accessibilityIdentifier("detail.notes")
            } else {
                Button {
                    Task { await createNotes() }
                } label: {
                    HStack {
                        Label(creatingNotes ? notesProgressText : "Create study notes", systemImage: "sparkles")
                        if creatingNotes {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(creatingNotes || quiz.cards.isEmpty)
                .accessibilityIdentifier("detail.createNotes")
            }

            if let sourceText = quiz.sourceText {
                NavigationLink {
                    StudyNotesView(title: "\(quiz.name): source", markdown: sourceText, sourceURL: quiz.sourceURL)
                } label: {
                    Label("Source material", systemImage: "doc.text")
                }
                .accessibilityIdentifier("detail.source")
            }

            if let url = quiz.sourceURL {
                Link(destination: url) {
                    Label("Open original page", systemImage: "safari")
                }
                .accessibilityIdentifier("detail.openOriginal")
            }

            if let notesError {
                Text(notesError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("detail.notesError")
            }
        } header: {
            Text("Study")
        } footer: {
            if quiz.studyNotes == nil {
                Text("Writes notes that teach everything this quiz's cards test, so you can study the topic as a whole.")
            }
        }
    }

    private var notesProgressText: String {
        notesWords > 0 ? "Writing study notes… \(notesWords) words" : "Writing study notes…"
    }

    private func createNotes() async {
        notesError = nil
        if let issue = router.issue(for: .summary) {
            setupIssue = issue.localizedDescription
            showSetup = true
            return
        }
        creatingNotes = true
        notesWords = 0
        defer { creatingNotes = false }
        do {
            let client = try router.client(for: .summary)
            let relay = WordCountRelay()
            let task = Task { @MainActor in
                for await words in relay.stream { notesWords = words }
            }
            defer { task.cancel(); relay.finish() }
            let notes = try await StudyNotesWriter.write(
                .cards(quizName: quiz.name, cards: quiz.payload.cards),
                using: client,
                onProgress: { words in relay.send(words) }
            )
            quiz.studyNotes = notes
            try context.save()
        } catch {
            notesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

/// Carries word counts from the notes writer's background callback to the main actor.
private final class WordCountRelay: Sendable {
    let stream: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ words: Int) { continuation.yield(words) }
    func finish() { continuation.finish() }
}
