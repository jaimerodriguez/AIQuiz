import SwiftUI
import AIQuizCore

struct SessionSummaryView: View {
    let deck: SessionDeck
    let onDone: () -> Void
    let onPracticeMissed: (([CardSnapshot]) -> Void)?
    /// F-44: fetches the recap; nil when no grading endpoint is ready.
    var recap: (() async throws -> String)? = nil
    var onRecap: ((String) -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @State private var recapText: String?
    @State private var recapFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                scoreHeadline

                statsGrid

                if recap != nil {
                    recapBlock
                }

                if !deck.missedCards.isEmpty {
                    missedList
                }

                actionButtons
            }
            .padding()
        }
        .navigationTitle("Session complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            guard let recap, recapText == nil else { return }
            do {
                let text = try await recap()
                recapText = text
                onRecap?(text)
            } catch {
                recapFailed = true
            }
        }
    }

    /// The recap arrives in the background; failing quietly never blocks the summary.
    @ViewBuilder
    private var recapBlock: some View {
        if let recapText {
            Label(recapText, systemImage: "sparkles")
                .font(settings.quizFontSize.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.recap")
        } else if !recapFailed {
            HStack(spacing: 8) {
                ProgressView()
                Text("Writing a recap…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("summary.recapLoading")
        }
    }

    @ViewBuilder
    private var scoreHeadline: some View {
        if let pct = deck.scorePercent {
            VStack(spacing: 6) {
                Text("\(Int((pct * 100).rounded()))%")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(pct))
                    .accessibilityIdentifier("summary.score")
                Text("Session score")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top)
        } else {
            Text("Done")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .padding(.top)
                .accessibilityIdentifier("summary.score")
        }
    }

    private var statsGrid: some View {
        let c = deck.counts
        return HStack(spacing: 8) {
            statCell("Correct", value: c.correct, color: .green)
            statCell("Partial", value: c.partial, color: .orange)
            statCell("Wrong", value: c.wrong, color: .red)
            if c.skipped > 0 {
                statCell("Skipped", value: c.skipped, color: .secondary)
            }
        }
    }

    private func statCell(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("summary.count.\(label.lowercased())")
    }

    private var missedList: some View {
        let typo = settings.quizFontSize
        let missed = deck.scoredCards.filter { $0.verdict == .wrong || $0.verdict == .partial }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Cards to review")
                .font(.headline)
            ForEach(missed, id: \.card.id) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(entry.card.prompt).font(typo.emphasisFont)
                        Spacer()
                        verdictBadge(entry.verdict)
                    }
                    if let s = entry.card.shortAnswer {
                        Text(s).font(typo.bodyFont).foregroundStyle(.tint)
                    }
                    Text(entry.card.longAnswer).font(typo.bodyFont).foregroundStyle(.secondary)
                    if let explanation = deck.explanations[entry.card.id] {
                        Label(explanation, systemImage: "questionmark.bubble")
                            .font(.footnote)
                            .padding(.top, 2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            if let onPracticeMissed, !deck.missedCards.isEmpty {
                Button {
                    onPracticeMissed(deck.missedCards)
                } label: {
                    Label("Practice missed cards (\(deck.missedCards.count))", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("summary.practiceMissed")
            }
            Button("Done", action: onDone)
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("summary.done")
        }
        .padding(.top)
    }

    @ViewBuilder
    private func verdictBadge(_ v: CardVerdict) -> some View {
        switch v {
        case .correct: Text("Correct").font(.caption2).foregroundStyle(.green)
        case .partial: Text("Partial").font(.caption2).foregroundStyle(.orange)
        case .wrong:   Text("Wrong").font(.caption2).foregroundStyle(.red)
        case .skipped: Text("Skipped").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func scoreColor(_ pct: Double) -> Color {
        switch pct {
        case 0.85...: return .green
        case 0.6..<0.85: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
}
