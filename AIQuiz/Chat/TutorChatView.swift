import SwiftUI
import SwiftData
import AIQuizCore
import LLMKit

/// Tutor chat (SPEC F-30, §9.1): a sheet with a streamed conversation about the quiz, and
/// the card it was opened from during a session. The transcript lives for the sheet only.
struct TutorChatView: View {
    let quiz: QuizRecord
    @State private var chat: TutorChat
    @State private var gate = AIGate()
    @State private var draft = ""
    @State private var makingCards = false
    @State private var newCards: NewCards?
    @State private var addedMessage: String?
    @State private var cardsError: String?
    @FocusState private var inputFocused: Bool
    @Environment(AIRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    struct NewCards: Identifiable {
        let id = UUID()
        let cards: [CardPayload]
    }

    init(quiz: QuizRecord, card: CardSnapshot? = nil) {
        self.quiz = quiz
        _chat = State(initialValue: TutorChat(context: TutorContext(
            quizName: quiz.name,
            description: quiz.descriptionText,
            studyNotes: quiz.studyNotes,
            card: card?.payload
        )))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if chat.messages.isEmpty {
                                emptyState
                            }
                            ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                                MessageRow(message: message, isStreaming: chat.isStreaming && index == chat.messages.count - 1)
                                    .id(message.id)
                                    .accessibilityIdentifier("chat.message.\(index)")
                            }
                            if let error = chat.error ?? cardsError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("chat.error")
                            }
                            if let addedMessage {
                                Label(addedMessage, systemImage: "checkmark.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("chat.added")
                            }
                        }
                        .padding()
                        .frame(maxWidth: Theme.readableWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.last?.text) { _, _ in
                        if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                inputBar
            }
            .navigationTitle("Tutor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        chat.stop()
                        dismiss()
                    }
                    .accessibilityIdentifier("chat.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await makeCards() }
                    } label: {
                        if makingCards {
                            ProgressView()
                        } else {
                            Label("Make cards", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                    .disabled(!chat.canMakeCards || makingCards)
                    .accessibilityIdentifier("chat.makeCards")
                }
            }
            .sheet(item: $newCards) { result in
                NewCardsPreview(cards: result.cards) {
                    add(result.cards)
                }
            }
            .aiSetupSheet(gate)
        }
        // A full page on iPad; the default form sheet is too small for a conversation.
        .presentationSizing(.page)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            AccentIcon(systemName: "bubble.left.and.text.bubble.right", size: 56)
            Text(chat.context.card == nil ? "Ask about \(quiz.name)" : "Ask about this card")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let card = chat.context.card {
                Text(card.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityIdentifier("chat.card")
            }
            VStack(spacing: 8) {
                ForEach(Array(chat.starters.enumerated()), id: \.offset) { index, starter in
                    Button(starter) { send(starter) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chat.starter.\(index)")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("chat.input")
            if chat.isStreaming {
                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("chat.stop")
            } else {
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                        .frame(width: 22, height: 22)
                }
                .primaryActionStyle()
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func send(_ text: String) {
        guard let client = gate.client(.chat, from: router) else { return }
        draft = ""
        addedMessage = nil
        cardsError = nil
        Task { await chat.send(text, using: client) }
    }

    /// F-27's contract on the transcript; the cards open in a preview to add or discard.
    private func makeCards() async {
        guard let client = gate.client(.generation, from: router) else { return }
        makingCards = true
        defer { makingCards = false }
        cardsError = nil
        addedMessage = nil
        do {
            let cards = try await chat.makeCards(existingPrompts: quiz.cards.map(\.prompt), using: client)
            newCards = NewCards(cards: cards)
        } catch {
            cardsError = aiMessage(error)
        }
    }

    private func add(_ cards: [CardPayload]) {
        quiz.appendCards(cards)
        do {
            try context.save()
            addedMessage = cards.count == 1 ? "Added 1 card to \(quiz.name)." : "Added \(cards.count) cards to \(quiz.name)."
        } catch {
            Log.data.error("Saving chat cards failed: \(String(describing: error))")
        }
        newCards = nil
    }
}

/// One message: the learner's in a bubble on the right, the tutor's as text on the left.
private struct MessageRow: View {
    let message: TutorChat.Message
    let isStreaming: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 18))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                if message.text.isEmpty && isStreaming {
                    ProgressView()
                } else {
                    Text(Self.rendered(message.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Inline Markdown (bold, italics, code) keeping the line breaks.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The cards *Make cards* proposed: add them all to the quiz, or discard.
private struct NewCardsPreview: View {
    let cards: [CardPayload]
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(cards.enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.prompt).font(.headline)
                    if let short = card.shortAnswer { Text(short).font(.subheadline).foregroundStyle(.secondary) }
                    Text(card.longAnswer)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("\(cards.count) new cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                        .accessibilityIdentifier("chat.cards.discard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(cards.count)", action: onAdd)
                        .primaryActionStyle()
                        .accessibilityIdentifier("chat.cards.add")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// A toolbar button that opens tutor chat about the current card (§9.1). `onOpen` pauses
    /// the session; `onClose` runs when the sheet goes away.
    func tutorChatButton(quiz: QuizRecord?, card: CardSnapshot?, isEnabled: Bool = true, onOpen: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) -> some View {
        modifier(TutorChatButton(quiz: quiz, card: card, isEnabled: isEnabled, onOpen: onOpen, onClose: onClose))
    }
}

private struct TutorChatButton: ViewModifier {
    let quiz: QuizRecord?
    let card: CardSnapshot?
    let isEnabled: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var chatCard: ChatCard?

    struct ChatCard: Identifiable {
        let id = UUID()
        let card: CardSnapshot?
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if quiz != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpen()
                            chatCard = ChatCard(card: card)
                        } label: {
                            Label("Ask the tutor", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .disabled(!isEnabled)
                        .accessibilityIdentifier("session.chat")
                    }
                }
            }
            .sheet(item: $chatCard, onDismiss: onClose) { item in
                if let quiz {
                    TutorChatView(quiz: quiz, card: item.card)
                }
            }
    }
}
