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

    public init(id: UUID, prompt: String, longAnswer: String, shortAnswer: String? = nil, hint: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
    }
}
