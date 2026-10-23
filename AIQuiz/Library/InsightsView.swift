import SwiftUI
import SwiftData
import AIQuizCore
import LLMKit

/// The progress report (SPEC F-43, F-7): the AI reads a compact digest of the history and
/// names strengths, confusions and next steps; *Create drill deck* saves its drill cards as
/// a new quiz.
struct InsightsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AIRouter.self) private var router
    @State private var gate = AIGate()
    @State private var report: InsightsReport?
    @State private var loading = false
    @State private var error: String?
    @State private var savedDrill: String?
    @State private var prompts: [UUID: String] = [:]

    var body: some View {
        List {
            if loading {
                HStack(spacing: 10) { ProgressView(); Text("Reading your history…").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("insights.loading")
            } else if let error {
                Section {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("insights.error")
                    Button("Try again") { Task { await load() } }
                }
            } else if let report {
                Section {
                    Label(report.headline, systemImage: "sparkles")
                        .font(.title3.weight(.semibold))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("insights.headline")
                }
                bullets("Strengths", "checkmark.seal", report.strengths, id: "insights.strengths")
                if !report.confusions.isEmpty {
                    Section("Mixed up") {
                        ForEach(Array(report.confusions.enumerated()), id: \.offset) { index, confusion in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(confusion.description)
                                ForEach(confusion.cardIds, id: \.self) { id in
                                    if let prompt = prompts[id] {
                                        Text("• " + prompt).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("insights.confusion.\(index)")
                        }
                    }
                }
                bullets("Next steps", "arrow.forward.circle", report.recommendations, id: "insights.recommendations")
                if !report.drillCards.isEmpty {
                    Section {
                        ForEach(Array(report.drillCards.enumerated()), id: \.offset) { _, card in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.prompt).font(.subheadline.weight(.semibold))
                                Text(card.shortAnswer ?? card.longAnswer).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let savedDrill {
                            Label("Saved as “\(savedDrill)”", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                                .accessibilityIdentifier("insights.saved")
                        } else {
                            Button {
                                createDrill(report.drillCards)
                            } label: {
                                Label("Create drill deck (\(report.drillCards.count) cards)", systemImage: "plus.rectangle.on.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryActionStyle()
                            .accessibilityIdentifier("insights.createDrill")
                        }
                    } header: {
                        Text("Drill cards")
                    }
                }
            } else {
                ContentUnavailableView("No history yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Do a few quiz sessions, then come back for a report on what you know and what to revisit."))
                    .accessibilityIdentifier("insights.empty")
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityIdentifier("insights.refresh")
            }
        }
        .aiSetupSheet(gate)
        .task { if report == nil && !loading { await load() } }
    }

    private func bullets(_ title: String, _ icon: String, _ items: [String], id: String) -> some View {
        Section(title) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: icon)
            }
        }
        .accessibilityIdentifier(id)
    }

    /// Builds the digest input from the library (relationships are read here, on demand).
    private func history() -> [InsightsQuiz] {
        let quizzes = (try? context.fetch(FetchDescriptor<QuizRecord>(predicate: #Predicate { !$0.isArchived }))) ?? []
        var names: [UUID: String] = [:]
        let input = quizzes.compactMap { quiz -> InsightsQuiz? in
            let sessions = quiz.sessions.filter { !$0.abandoned }
            guard !sessions.isEmpty else { return nil }
            for card in quiz.cards { names[card.id] = card.prompt }
            return InsightsQuiz(
                name: quiz.name,
                sessions: sessions.map { .init(date: $0.startedAt, mode: $0.mode, score: $0.scorePercent) },
                cards: quiz.cards.map { .init(id: $0.id, prompt: $0.prompt, correct: $0.correctCount, partial: $0.partialCount, wrong: $0.wrongCount, lapses: $0.lapses) }
            )
        }
        prompts = names
        return input
    }

    private func load() async {
        let input = history()
        guard !input.isEmpty else { report = nil; error = nil; return }
        guard let client = gate.client(.summary, from: router) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            report = try await InsightsReporter.report(input, using: client)
            savedDrill = nil
        } catch {
            self.error = aiMessage(error)
        }
    }

    private func createDrill(_ cards: [CardPayload]) {
        let name = "Drill · " + Date.now.formatted(date: .abbreviated, time: .omitted)
        let quiz = QuizRecord.make(from: QuizPayload(name: name, tags: ["drill"], cards: cards), origin: .topic)
        context.insert(quiz)
        try? context.save()
        savedDrill = name
    }
}
