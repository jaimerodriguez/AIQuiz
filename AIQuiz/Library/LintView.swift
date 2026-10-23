import SwiftUI
import SwiftData
import AIQuizCore
import LLMKit

/// Lint cards (SPEC F-29): the AI lists problems; each issue with a suggested fix offers
/// *Apply fix*, and any issue can be dismissed.
struct LintView: View {
    let quiz: QuizRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AIRouter.self) private var router
    @State private var gate = AIGate()
    @State private var issues: [LintIssue]?
    @State private var cards: [CardRecord] = []
    @State private var error: String?
    @State private var running = false

    var body: some View {
        List {
            if running {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking \(cards.count) cards…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("lint.progress")
            } else if let error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("lint.error")
                Button("Try again") { Task { await run() } }
            } else if let issues {
                if issues.isEmpty {
                    ContentUnavailableView("No problems found", systemImage: "checkmark.seal", description: Text("The AI didn't find ambiguous, duplicate or mismatched cards."))
                        .accessibilityIdentifier("lint.clean")
                } else {
                    ForEach(issues) { issue in
                        issueRow(issue)
                    }
                }
            }
        }
        .navigationTitle("Lint cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("lint.done")
            }
        }
        .aiSetupSheet(gate)
        .task {
            guard issues == nil, !running else { return }
            await run()
        }
    }

    private func issueRow(_ issue: LintIssue) -> some View {
        let card = issue.index < cards.count ? cards[issue.index] : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                Text(issue.kind.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("Card \(issue.index + 1)").font(.caption).foregroundStyle(.secondary)
            }
            if let card { Text(card.prompt).font(.headline) }
            Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
            if let fix = issue.suggestedFix {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested").font(.caption).foregroundStyle(.secondary)
                    Text(fix.prompt).font(.subheadline)
                    Text(fix.shortAnswer ?? fix.longAnswer).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if let fix = issue.suggestedFix, let card {
                    Button("Apply fix") { apply(fix, to: card, issue: issue) }
                        .primaryActionStyle()
                        .accessibilityIdentifier("lint.apply.\(issue.index)")
                }
                Button("Dismiss") { remove(issue) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lint.dismiss.\(issue.index)")
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lint.issue.\(issue.index)")
    }

    private func run() async {
        guard let client = gate.client(.grading, from: router) else { return }
        cards = quiz.sortedCards
        let payloads = cards.map(\.payload)
        error = nil
        running = true
        defer { running = false }
        do {
            issues = try await CardLinter.lint(payloads, using: client)
        } catch {
            self.error = aiMessage(error)
        }
    }

    private func apply(_ fix: CardPayload, to card: CardRecord, issue: LintIssue) {
        card.apply(fix)
        try? context.save()
        remove(issue)
    }

    private func remove(_ issue: LintIssue) {
        issues?.removeAll { $0.id == issue.id }
    }
}

/// Per-card outcomes of a past session, with the AI's verdicts (SPEC F-8, F-15).
struct SessionOutcomesView: View {
    let session: SessionRecord
    let quiz: QuizRecord

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: quiz.cards.map { ($0.id, $0) })
        List {
            Section {
                LabeledContent("Score", value: session.scorePercent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                LabeledContent("When", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let recap = session.recapText {
                    Label(recap, systemImage: "sparkles")
                        .accessibilityIdentifier("sessionOutcomes.recap")
                }
            }
            Section("Cards") {
                ForEach(Array(session.outcomes.enumerated()), id: \.offset) { index, outcome in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(byId[outcome.cardId]?.prompt ?? "A deleted card").font(.headline)
                            Spacer()
                            VerdictBadge(verdict: outcome.verdict)
                        }
                        if let ai = outcome.aiVerdict {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("AI: \(ai.rawValue.capitalized)")
                                if outcome.userOverrode { Text("· you overrode it") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let reason = outcome.aiReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let explanation = outcome.explanation {
                            Label(explanation, systemImage: "questionmark.bubble").font(.footnote)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sessionOutcomes.card.\(index)")
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VerdictBadge: View {
    let verdict: CardVerdict

    var body: some View {
        Text(verdict.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch verdict {
        case .correct: return .green
        case .partial: return .orange
        case .wrong: return .red
        case .skipped: return .secondary
        }
    }
}
