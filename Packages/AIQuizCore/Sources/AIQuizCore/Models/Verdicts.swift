import Foundation

/// Which screen a session ran in. Stored as a raw string in `SessionRecord`.
public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case studyVoice
    case studyRead
    case quizVoice
}

/// Outcome of one card in a session. `skipped` records nothing and scores nothing.
public enum CardVerdict: String, Codable, Sendable, CaseIterable {
    case correct
    case partial
    case wrong
    case skipped

    /// Contribution to the session score (SPEC §5.7). `nil` means excluded.
    public var score: Double? {
        switch self {
        case .correct: return 1.0
        case .partial: return 0.5
        case .wrong: return 0.0
        case .skipped: return nil
        }
    }
}

/// Persisted per-card outcome of a session.
public struct CardOutcome: Codable, Hashable, Sendable {
    public var cardId: UUID
    public var verdict: CardVerdict

    public init(cardId: UUID, verdict: CardVerdict) {
        self.cardId = cardId
        self.verdict = verdict
    }
}
