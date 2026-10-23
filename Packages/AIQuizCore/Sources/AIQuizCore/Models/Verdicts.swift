import Foundation

/// Which screen a session ran in. Stored as a raw string in `SessionRecord`.
public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case studyVoice
    case studyRead
    case quizVoice
    /// Quiz — Choice: multiple choice, fill in the blank, true or false (F-17).
    case quizChoice
    /// The cross-quiz Due today review (F-41).
    case review
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

/// Persisted per-card outcome of a session (SPEC §3). Older sessions stored only
/// `cardId` and `verdict`; the AI fields decode as absent.
public struct CardOutcome: Codable, Hashable, Sendable {
    public var cardId: UUID
    /// The verdict that counts: the user's grade.
    public var verdict: CardVerdict
    /// What the AI judged, when it judged (F-15).
    public var aiVerdict: CardVerdict?
    public var aiReason: String?
    /// The user chose a different grade from the AI's.
    public var userOverrode: Bool
    /// "Why was I wrong?" text, when the user asked (F-16).
    public var explanation: String?

    public init(cardId: UUID, verdict: CardVerdict, aiVerdict: CardVerdict? = nil, aiReason: String? = nil, userOverrode: Bool = false, explanation: String? = nil) {
        self.cardId = cardId
        self.verdict = verdict
        self.aiVerdict = aiVerdict
        self.aiReason = aiReason
        self.userOverrode = userOverrode
        self.explanation = explanation
    }

    enum CodingKeys: String, CodingKey { case cardId, verdict, aiVerdict, aiReason, userOverrode, explanation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cardId = try c.decode(UUID.self, forKey: .cardId)
        verdict = try c.decode(CardVerdict.self, forKey: .verdict)
        aiVerdict = try c.decodeIfPresent(CardVerdict.self, forKey: .aiVerdict)
        aiReason = try c.decodeIfPresent(String.self, forKey: .aiReason)
        userOverrode = try c.decodeIfPresent(Bool.self, forKey: .userOverrode) ?? false
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
    }
}

/// An AI grade for one card (F-15).
public struct AIGrade: Sendable, Hashable {
    public let verdict: CardVerdict
    public let reason: String

    public init(verdict: CardVerdict, reason: String) {
        self.verdict = verdict
        self.reason = reason
    }
}
