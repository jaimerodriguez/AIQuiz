import Foundation

/// The per-quiz numbers library rows show, stored on the quiz so rows never walk its
/// cards or sessions (SPEC D-11, N-8).
public struct QuizCounters: Equatable, Sendable {
    public var cardCount: Int
    /// Sessions that were not abandoned.
    public var sessionCount: Int
    public var bestScore: Double?
    public var averageScore: Double?
    /// Cards due at `now`: never reviewed (`dueAt == nil`) or `dueAt <= now`.
    public var dueCount: Int
    public var lastStudiedAt: Date?

    public init(cardCount: Int = 0, sessionCount: Int = 0, bestScore: Double? = nil, averageScore: Double? = nil, dueCount: Int = 0, lastStudiedAt: Date? = nil) {
        self.cardCount = cardCount
        self.sessionCount = sessionCount
        self.bestScore = bestScore
        self.averageScore = averageScore
        self.dueCount = dueCount
        self.lastStudiedAt = lastStudiedAt
    }

    public struct Session: Sendable {
        public var abandoned: Bool
        public var scorePercent: Double?
        public var startedAt: Date
        public var endedAt: Date?

        public init(abandoned: Bool, scorePercent: Double?, startedAt: Date, endedAt: Date?) {
            self.abandoned = abandoned
            self.scorePercent = scorePercent
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    public static func compute(cardDueDates: [Date?], sessions: [Session], now: Date) -> QuizCounters {
        let kept = sessions.filter { !$0.abandoned }
        let scores = kept.compactMap(\.scorePercent)
        return QuizCounters(
            cardCount: cardDueDates.count,
            sessionCount: kept.count,
            bestScore: scores.max(),
            averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
            dueCount: cardDueDates.filter { $0 == nil || $0! <= now }.count,
            lastStudiedAt: kept.map { $0.endedAt ?? $0.startedAt }.max()
        )
    }
}
