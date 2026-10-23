import SwiftUI
import SwiftData
import AIQuizCore
import LLMKit

/// The card sheet's AI actions (SPEC F-9, F-23, F-24, F-25, F-27, F-28). Owned by the card
/// sheet; `CardAISection` draws the buttons and `.cardAIPresentation(_:)` (attached to the
/// sheet's list, never inside a row) shows results, setup and errors.
@MainActor
@Observable
final class CardAssistant {
    enum Result: Equatable {
        case explanation(String)
        case mnemonic(String)
        case rewrite(CardPayload, label: String)
        case expansion([CardPayload])
    }

    /// A result shown in its own sheet, so it is never below the fold.
    struct Presented: Identifiable {
        let id = UUID()
        let result: Result
    }

    let card: CardRecord
    let gate = AIGate()
    private(set) var busy: String?
    var presented: Presented?
    var error: String?
    var askingLanguage = false
    var language = ""

    init(card: CardRecord) {
        self.card = card
    }

    func clear() {
        presented = nil
        error = nil
    }

    /// Runs one action; a second tap while busy is ignored.
    private func run(_ label: String, _ work: () async throws -> Result?) async {
        guard busy == nil else { return }
        busy = label
        error = nil
        presented = nil
        defer { busy = nil }
        do {
            if let result = try await work() { presented = Presented(result: result) }
        } catch {
            self.error = aiMessage(error)
        }
    }

    // MARK: Actions

    func explain(router: AIRouter) async {
        guard let client = gate.client(.grading, from: router) else { return }
        let payload = card.payload, name = card.quiz?.name
        await run("Explaining") { .explanation(try await Explainer.explain(payload, quizName: name, using: client)) }
    }

    func mnemonic(router: AIRouter) async {
        guard let client = gate.client(.grading, from: router) else { return }
        let payload = card.payload
        await run("Writing a mnemonic") { .mnemonic(try await MnemonicGenerator.mnemonic(for: payload, using: client)) }
    }

    func expand(router: AIRouter) async {
        guard let client = gate.client(.generation, from: router) else { return }
        let payload = card.payload, name = card.quiz?.name
        let existing = card.quiz?.sortedCards.map(\.prompt) ?? []
        await run("Expanding") {
            .expansion(try await CardExpander.expand(payload, quizName: name, existingPrompts: existing, using: client))
        }
    }

    func rewrite(_ instruction: CardRewriter.Instruction, router: AIRouter) async {
        guard let client = gate.client(.generation, from: router) else { return }
        let payload = card.payload
        await run("Rewriting") {
            .rewrite(try await CardRewriter.rewrite(payload, instruction, using: client), label: instruction.label)
        }
    }

    /// F-24: adds the next, stronger AI hint (up to three), stored on the card.
    func addHint(router: AIRouter, context: ModelContext) async {
        guard let client = gate.client(.grading, from: router) else { return }
        let payload = card.payload
        let previous = [card.hint].compactMap { $0 } + card.aiHints
        await run("Writing a hint") {
            let hint = try await HintGenerator.nextHint(for: payload, previous: previous, using: client)
            card.aiHints = Array((card.aiHints + [hint]).prefix(HintGenerator.maxHints))
            try? context.save()
            return nil
        }
    }

    // MARK: Results

    func title(for result: Result) -> String {
        switch result {
        case .explanation: return "Explanation"
        case .mnemonic: return "Mnemonic"
        case .rewrite: return "Rewrite"
        case .expansion(let cards): return "\(cards.count) new cards"
        }
    }

    /// The Save button's label, or nil when there is nothing new to save.
    func saveLabel(for result: Result) -> String? {
        switch result {
        case .explanation(let text): return card.explanation == text ? nil : "Save"
        case .mnemonic(let text): return card.mnemonic == text ? nil : "Save"
        case .rewrite: return "Replace"
        case .expansion(let cards): return "Add \(cards.count)"
        }
    }

    func keep(_ result: Result, context: ModelContext) {
        switch result {
        case .explanation(let text): card.explanation = text
        case .mnemonic(let text): card.mnemonic = text
        case .rewrite(let rewritten, _): card.apply(rewritten)
        case .expansion(let cards): card.quiz?.insertCards(cards, after: card)
        }
        if let quiz = card.quiz { QuizStats.refresh(quiz) }
        try? context.save()
        clear()
    }
}

/// The *AI* section of the card sheet: action buttons, each showing its own progress, and
/// the stored AI hints.
struct CardAISection: View {
    let assistant: CardAssistant
    @Environment(\.modelContext) private var context
    @Environment(AIRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var card: CardRecord { assistant.card }

    var body: some View {
        Section {
            // Four across on iPad, two by two on iPhone.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: sizeClass == .regular ? 4 : 2), spacing: 8) {
                action("Explain", "text.bubble", busyLabel: "Explaining", id: "card.ai.explain") { await assistant.explain(router: router) }
                action("Mnemonic", "brain.head.profile", busyLabel: "Writing a mnemonic", id: "card.ai.mnemonic") { await assistant.mnemonic(router: router) }
                action("Expand", "plus.rectangle.on.rectangle", busyLabel: "Expanding", id: "card.ai.expand") { await assistant.expand(router: router) }
                rewriteMenu
            }
            .buttonStyle(.bordered)
            .padding(.vertical, 4)

            ForEach(Array(card.aiHints.enumerated()), id: \.offset) { index, hint in
                Label(hint, systemImage: "lightbulb")
                    .font(.subheadline)
                    .accessibilityIdentifier("card.ai.hintText.\(index)")
            }
            .onDelete { offsets in
                var hints = card.aiHints
                hints.remove(atOffsets: offsets)
                card.aiHints = hints
                try? context.save()
            }
            if card.aiHints.count < HintGenerator.maxHints {
                Button {
                    Task { await assistant.addHint(router: router, context: context) }
                } label: {
                    if assistant.busy == "Writing a hint" {
                        HStack(spacing: 6) { ProgressView(); Text("Writing a hint…") }
                    } else {
                        Label(card.aiHints.isEmpty ? "Add an AI hint" : "Add a stronger hint (\(card.aiHints.count)/\(HintGenerator.maxHints))", systemImage: "lightbulb.max")
                    }
                }
                .disabled(assistant.busy != nil)
                .accessibilityIdentifier("card.ai.hint")
            }
        } header: {
            Label("AI", systemImage: "sparkles")
        }
    }

    private func action(_ title: String, _ icon: String, busyLabel: String, id: String, perform: @escaping () async -> Void) -> some View {
        Button {
            Task { await perform() }
        } label: {
            Group {
                if assistant.busy == busyLabel {
                    HStack(spacing: 6) { ProgressView(); Text(busyLabel) }
                } else {
                    Label(title, systemImage: icon)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .disabled(assistant.busy != nil)
        .accessibilityIdentifier(id)
    }

    private var rewriteMenu: some View {
        Menu {
            ForEach([CardRewriter.Instruction.simplify, .harder, .shorten], id: \.self) { instruction in
                Button(instruction.label) { Task { await assistant.rewrite(instruction, router: router) } }
                    .accessibilityIdentifier("card.ai.rewrite.\(instruction.label)")
            }
            Button("Translate…") { assistant.askingLanguage = true }
            Divider()
            ForEach(CardKind.allCases.filter { $0 != card.cardKind }, id: \.self) { kind in
                let instruction = CardRewriter.Instruction.convert(kind)
                Button(instruction.label) { Task { await assistant.rewrite(instruction, router: router) } }
                    .accessibilityIdentifier("card.ai.convert.\(kind.rawValue)")
            }
        } label: {
            Group {
                if assistant.busy == "Rewriting" {
                    HStack(spacing: 6) { ProgressView(); Text("Rewriting") }
                } else {
                    Label("Rewrite", systemImage: "wand.and.stars")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .disabled(assistant.busy != nil)
        .accessibilityIdentifier("card.ai.rewrite")
    }
}

extension View {
    /// The result sheet, endpoint setup and alerts for the card sheet's AI actions.
    func cardAIPresentation(_ assistant: CardAssistant) -> some View {
        modifier(CardAIPresentation(assistant: assistant))
    }
}

private struct CardAIPresentation: ViewModifier {
    @Bindable var assistant: CardAssistant
    @Environment(\.modelContext) private var context
    @Environment(AIRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .aiSetupSheet(assistant.gate)
            .sheet(item: $assistant.presented) { presented in
                NavigationStack {
                    List { resultView(presented.result) }
                        .navigationTitle(assistant.title(for: presented.result))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Discard") { assistant.clear() }
                                    .accessibilityIdentifier("card.ai.discard")
                            }
                            if let save = assistant.saveLabel(for: presented.result) {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(save) { assistant.keep(presented.result, context: context) }
                                        .primaryActionStyle()
                                        .accessibilityIdentifier("card.ai.save")
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("AI couldn't finish", isPresented: Binding(get: { assistant.error != nil }, set: { if !$0 { assistant.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(assistant.error ?? "")
            }
            .alert("Translate to", isPresented: $assistant.askingLanguage) {
                TextField("Language, e.g. Spanish", text: $assistant.language)
                    .accessibilityIdentifier("card.ai.language")
                Button("Translate") {
                    let target = assistant.language.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else { return }
                    Task { await assistant.rewrite(.translate(target), router: router) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder
    private func resultView(_ result: CardAssistant.Result) -> some View {
        switch result {
        case .explanation(let text), .mnemonic(let text):
            Text(text)
                .textSelection(.enabled)
                .accessibilityIdentifier("card.ai.result")
        case .rewrite(let rewritten, let label):
            Section(label) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rewritten.prompt).font(.headline)
                    if let short = rewritten.shortAnswer { Text(short).foregroundStyle(.tint) }
                    Text(rewritten.longAnswer)
                    if let hint = rewritten.hint { Label(hint, systemImage: "lightbulb").font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("card.ai.result")
            }
            Section("Now") {
                Text(assistant.card.prompt).foregroundStyle(.secondary)
            }
        case .expansion(let cards):
            Section("New cards, added after this one") {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, new in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(new.prompt).font(.subheadline.weight(.semibold))
                        Text(new.shortAnswer ?? new.longAnswer).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("card.ai.result")
        }
    }
}
