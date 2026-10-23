import Foundation

/// Immutable copy of a card's content taken at session start (DECISIONS ADR-009).
/// Sessions and players operate on snapshots; results are mapped back to the
/// persistent record by `id` when the session is recorded.
public struct CardSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let prompt: String
    public let longAnswer: String
    public let shortAnswer: String?
    public let hint: String?
    /// Stored AI hints, weakest first (F-24).
    public let aiHints: [String]

    public init(id: UUID, prompt: String, longAnswer: String, shortAnswer: String? = nil, hint: String? = nil, aiHints: [String] = []) {
        self.id = id
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
        self.aiHints = aiHints
    }

    /// Every hint, in the order the Hint button reveals them: the author's, then AI hints.
    public var hints: [String] {
        ([hint].compactMap { $0 } + aiHints).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public extension CardPayload {
    /// The content of a session card, for AI prompts.
    init(_ snapshot: CardSnapshot) {
        self.init(prompt: snapshot.prompt, longAnswer: snapshot.longAnswer, shortAnswer: snapshot.shortAnswer, hint: snapshot.hint)
    }
}
