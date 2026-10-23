import SwiftUI
import SwiftData
import AIQuizCore

/// A card's full content with its AI actions, Edit and Delete (SPEC F-9).
struct CardSheet: View {
    let card: CardRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var assistant: CardAssistant

    init(card: CardRecord) {
        self.card = card
        _assistant = State(initialValue: CardAssistant(card: card))
    }

    var body: some View {
        NavigationStack {
            List {
                field("Prompt", card.prompt, id: "card.prompt")
                if let short = card.shortAnswer, !short.isEmpty { field("Short answer", short, id: "card.shortAnswer") }
                field("Long answer", card.longAnswer, id: "card.longAnswer")
                if let hint = card.hint, !hint.isEmpty { field("Hint", hint, id: "card.hint") }
                CardAISection(assistant: assistant)
                if let difficulty = card.aiDifficulty {
                    LabeledContent("Difficulty (AI)", value: "\(difficulty) of 5")
                        .accessibilityIdentifier("card.difficulty")
                }
                if card.cardKind != .recall {
                    Section("Kind") {
                        Text(card.cardKind.label)
                        if let options = card.options, !options.isEmpty {
                            ForEach(options, id: \.self) { option in
                                Label(option, systemImage: option == card.shortAnswer ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
                if let explanation = card.explanation, !explanation.isEmpty { field("Explanation", explanation, id: "card.explanation") }
                if let mnemonic = card.mnemonic, !mnemonic.isEmpty { field("Mnemonic", mnemonic, id: "card.mnemonic") }
                Section("History") {
                    LabeledContent("Correct", value: "\(card.correctCount)")
                    LabeledContent("Partly right", value: "\(card.partialCount)")
                    LabeledContent("Wrong", value: "\(card.wrongCount)")
                    if let seen = card.lastSeenAt {
                        LabeledContent("Last seen", value: seen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Button("Delete card", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("card.delete")
                }
            }
            .cardAIPresentation(assistant)
            .navigationTitle("Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("card.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("card.edit")
                }
            }
            .navigationDestination(isPresented: $editing) {
                CardEditView(card: card)
            }
            .confirmationDialog("Delete this card?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete card", role: .destructive) { delete() }
                    .accessibilityIdentifier("card.confirmDelete")
            } message: {
                Text("Its history is deleted too.")
            }
        }
    }

    private func field(_ title: String, _ text: String, id: String) -> some View {
        Section(title) {
            Text(text)
                .textSelection(.enabled)
                .accessibilityIdentifier(id)
        }
    }

    private func delete() {
        let quiz = card.quiz
        quiz?.cards.removeAll { $0.id == card.id }
        context.delete(card)
        if let quiz { QuizStats.refresh(quiz) }
        do {
            try context.save()
        } catch {
            Log.data.error("Card delete failed: \(String(describing: error))")
        }
        dismiss()
    }
}

/// Edits every content field of a card (F-9 *Edit*), validated against SPEC D-2.
struct CardEditView: View {
    let card: CardRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: CardPayload
    @State private var optionsText: String

    init(card: CardRecord) {
        self.card = card
        _draft = State(initialValue: card.payload)
        _optionsText = State(initialValue: (card.options ?? []).joined(separator: "\n"))
    }

    var body: some View {
        Form {
            // At the top, so the reason Save is disabled is always on screen.
            if let problem {
                Section {
                    Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("cardEdit.problem")
                }
            }
            Section("Prompt") {
                TextField("Prompt", text: $draft.prompt, axis: .vertical)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("cardEdit.prompt")
            }
            Section("Short answer") {
                TextField("Optional", text: optional(\.shortAnswer), axis: .vertical)
                    .accessibilityIdentifier("cardEdit.shortAnswer")
            }
            Section("Long answer") {
                TextField("Long answer", text: $draft.longAnswer, axis: .vertical)
                    .lineLimit(3...12)
                    .accessibilityIdentifier("cardEdit.longAnswer")
            }
            Section("Hint") {
                TextField("Optional", text: optional(\.hint), axis: .vertical)
                    .accessibilityIdentifier("cardEdit.hint")
            }
            Section {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(CardKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .accessibilityIdentifier("cardEdit.kind")
                if draft.kind == .multipleChoice {
                    TextField("One option per line", text: $optionsText, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("cardEdit.options")
                }
            } header: {
                Text("Kind")
            } footer: {
                Text(kindHelp)
            }
            Section("Explanation") {
                TextField("Optional, shown after grading", text: optional(\.explanation), axis: .vertical)
                    .accessibilityIdentifier("cardEdit.explanation")
            }
            Section("Mnemonic") {
                TextField("Optional", text: optional(\.mnemonic), axis: .vertical)
                    .accessibilityIdentifier("cardEdit.mnemonic")
            }
        }
        .navigationTitle("Edit card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .primaryActionStyle()
                    .disabled(problem != nil)
                    .accessibilityIdentifier("cardEdit.save")
            }
        }
    }

    private var kindHelp: String {
        switch draft.kind {
        case .recall: return "Answer from memory."
        case .multipleChoice: return "2 to 6 options. The short answer must be one of them."
        case .cloze: return "Put {{blank}} in the prompt where the answer goes; the short answer is the missing text."
        case .trueFalse: return "The short answer is true or false."
        }
    }

    /// The draft as it will be saved: empty optional fields become nil.
    private var final: CardPayload {
        var d = draft
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        d.prompt = d.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        d.longAnswer = d.longAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        d.shortAnswer = clean(d.shortAnswer)
        d.hint = clean(d.hint)
        d.explanation = clean(d.explanation)
        d.mnemonic = clean(d.mnemonic)
        d.options = d.kind == .multipleChoice
            ? optionsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : nil
        return d
    }

    private var problem: String? { CardValidator.problem(with: final) }

    private func optional(_ keyPath: WritableKeyPath<CardPayload, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func save() {
        card.apply(final)
        if let quiz = card.quiz { QuizStats.refresh(quiz) }
        do {
            try context.save()
        } catch {
            Log.data.error("Card edit failed: \(String(describing: error))")
        }
        dismiss()
    }
}
