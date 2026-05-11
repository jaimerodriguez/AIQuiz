import SwiftUI

struct SessionSummaryView: View {
    let deck: SessionDeck
    let onDone: () -> Void
    let onPracticeMissed: (([CardRecord]) -> Void)?

    private var scoredOutcomes: [(card: CardRecord, verdict: CardVerdict)] {
        deck.cards.compactMap { card in
            guard let v = deck.outcomes[card.id] else { return nil }
            return (card, v)
        }
    }

    private var counts: (correct: Int, partial: Int, wrong: Int, skipped: Int) {
        var c = 0, p = 0, w = 0, s = 0
        for (_, v) in scoredOutcomes {
            switch v {
            case .correct: c += 1
            case .partial: p += 1
            case .wrong:   w += 1
            case .skipped: s += 1
            }
        }
        return (c, p, w, s)
    }

    private var missed: [CardRecord] {
        scoredOutcomes.compactMap { $0.verdict == .wrong || $0.verdict == .partial ? $0.card : nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                scoreHeadline

                statsGrid

                if !missed.isEmpty {
                    missedList
                }

                actionButtons
            }
            .padding()
        }
        .navigationTitle("Session complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private var scoreHeadline: some View {
        if let pct = deck.scorePercent {
            VStack(spacing: 6) {
                Text("\(Int((pct * 100).rounded()))%")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(pct))
                Text("Session score")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top)
        } else {
            Text("Done")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .padding(.top)
        }
    }

    private var statsGrid: some View {
        let c = counts
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
    }

    private var missedList: some View {
        let typo = AppSettings.shared.quizFontSize
        return VStack(alignment: .leading, spacing: 8) {
            Text("Cards to review")
                .font(.headline)
            ForEach(scoredOutcomes.filter { $0.verdict == .wrong || $0.verdict == .partial }, id: \.card.id) { entry in
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
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            if let onPracticeMissed, !missed.isEmpty {
                Button {
                    onPracticeMissed(missed)
                } label: {
                    Label("Practice missed cards (\(missed.count))", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done", action: onDone)
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
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
