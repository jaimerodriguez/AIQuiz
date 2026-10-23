import Foundation
import LLMKit
import Observation

/// What the tutor knows about (SPEC §9.1): the quiz, its notes, and the card the chat was
/// opened from, if any.
public struct TutorContext: Sendable, Equatable {
    /// Study notes are cut to this many tokens (characters / 4, §7.4).
    public static let notesTokenLimit = 4_000

    public var quizName: String
    public var description: String?
    public var studyNotes: String?
    public var card: CardPayload?

    public init(quizName: String, description: String? = nil, studyNotes: String? = nil, card: CardPayload? = nil) {
        self.quizName = quizName
        self.description = description
        self.studyNotes = studyNotes.map { Self.truncate($0, tokens: Self.notesTokenLimit) }
        self.card = card
    }

    /// The text cut at a word boundary to fit `tokens`, with an ellipsis when cut.
    static func truncate(_ text: String, tokens: Int) -> String {
        let limit = tokens * 4
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]) + " …"
    }
}

/// Tutor chat (SPEC F-30): a streamed conversation about a quiz, kept for the sheet's
/// lifetime only, that can be turned into new cards (F-27's contract).
@Observable
@MainActor
public final class TutorChat {
    public struct Message: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let role: ChatMessage.Role
        public var text: String

        public init(id: UUID = UUID(), role: ChatMessage.Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    /// Earlier turns beyond this many tokens are left out of each request.
    public static let historyTokenBudget = 12_000

    public let context: TutorContext
    public private(set) var messages: [Message] = []
    public private(set) var isStreaming = false
    public private(set) var error: String?
    private var task: Task<Void, Never>?

    public init(context: TutorContext) {
        self.context = context
    }

    /// Suggested first messages (§9.1).
    public var starters: [String] {
        context.card != nil
            ? ["Explain this card", "Quiz me on this", "Give me an analogy"]
            : ["Explain the key ideas", "Quiz me on this", "Give me an analogy"]
    }

    /// There is a reply to make cards from.
    public var canMakeCards: Bool {
        !isStreaming && messages.contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    /// Sends a message and streams the reply into the transcript. Returns when the reply ends,
    /// fails or is stopped; a stopped reply keeps what arrived.
    public func send(_ text: String, using client: LLMClient) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        error = nil
        messages.append(Message(role: .user, text: trimmed))
        let request = makeRequest()
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        isStreaming = true

        let streaming = Task { [weak self] in
            do {
                for try await event in client.stream(request) {
                    guard let self else { return }
                    if case .textDelta(let delta) = event { self.append(delta, to: reply.id) }
                }
            } catch {
                guard let self, !Self.isCancellation(error) else { return }
                self.error = Self.message(for: error)
            }
        }
        task = streaming
        await streaming.value
        task = nil
        isStreaming = false
        if let index = messages.firstIndex(where: { $0.id == reply.id }), messages[index].text.isEmpty {
            messages.remove(at: index)
        }
    }

    /// Stops the reply in progress.
    public func stop() {
        task?.cancel()
    }

    /// The request for the next reply: the context as system prompt and as much recent history
    /// as fits `historyTokenBudget`, always starting with a learner turn.
    func makeRequest() -> ChatRequest {
        var kept: [ChatMessage] = []
        var used = 0
        for message in messages.reversed() where !message.text.isEmpty {
            let cost = (message.text.utf8.count + 3) / 4
            if !kept.isEmpty, used + cost > Self.historyTokenBudget { break }
            used += cost
            kept.insert(message.role == .user ? .user(message.text) : .assistant(message.text), at: 0)
        }
        while let first = kept.first, first.role != .user { kept.removeFirst() }
        return ChatRequest(
            system: PromptBuilder.tutorSystem(context),
            messages: kept,
            maxTokens: 2_000,
            effort: .low,
            timeout: 120,
            label: "tutor"
        )
    }

    /// The conversation as text for *Make cards*, most recent part when it is long.
    var transcript: String {
        let text = messages
            .filter { !$0.text.isEmpty }
            .map { ($0.role == .user ? "Learner: " : "Tutor: ") + $0.text }
            .joined(separator: "\n\n")
        let limit = Self.historyTokenBudget * 4
        return text.count > limit ? "…" + String(text.suffix(limit)) : text
    }

    /// *Make cards from this chat* (§9.1): 3 to 5 cards through F-27's contract.
    public func makeCards(existingPrompts: [String], using client: LLMClient) async throws -> [CardPayload] {
        guard canMakeCards else { throw LLMError.malformedResponse("there is no conversation to make cards from yet") }
        return try await client.run(StructuredTask<ExpandJSON>(
            name: "chatCards",
            system: PromptBuilder.chatCardsSystem(),
            user: PromptBuilder.chatCardsUser(transcript: transcript, quizName: context.quizName, existingPrompts: existingPrompts),
            schema: CardExpander.schema, maxTokens: 8_000, effort: .medium, timeout: 120,
            validate: { json in
                guard (1...6).contains(json.cards.count) else { throw LLMResponseParseError("expected 3 to 5 cards, got \(json.cards.count)") }
                for (i, c) in json.cards.enumerated() {
                    if let problem = CardValidator.problem(with: c) { throw LLMResponseParseError("card \(i + 1): \(problem)") }
                }
            }
        )).cards
    }

    private func append(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case LLMError.cancelled? = error as? LLMError { return true }
        return false
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
