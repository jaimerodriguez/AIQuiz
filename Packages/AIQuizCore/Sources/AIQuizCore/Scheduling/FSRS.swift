import Foundation

/// FSRS-4.5, the Free Spaced Repetition Scheduler, with its published default parameters
/// (SPEC §10, F-40). Formulas from the open-spaced-repetition "The Algorithm" wiki:
/// retrievability R(t,S) = (1 + FACTOR·t/S)^DECAY with DECAY = −0.5 and FACTOR = 19/81, so the
/// interval for 90 % retention equals S days.
public enum FSRS {
    /// Ratings: Again, Hard, Good, Easy.
    public enum Rating: Int, Sendable, Codable, CaseIterable {
        case again = 1, hard = 2, good = 3, easy = 4

        /// SPEC §10: Wrong → Again, Partial → Hard, Correct → Good. Skipped has no rating.
        public init?(_ verdict: CardVerdict, easy: Bool = false) {
            switch verdict {
            case .wrong: self = .again
            case .partial: self = .hard
            case .correct: self = easy ? .easy : .good
            case .skipped: return nil
            }
        }
    }

    /// A card's scheduling state, as stored on `CardRecord`.
    public struct State: Sendable, Equatable {
        /// 0 means the card has never been reviewed.
        public var stability: Double
        public var difficulty: Double
        public var dueAt: Date?
        public var reps: Int
        public var lapses: Int
        public var lastRating: Int?
        public var lastReviewedAt: Date?

        public init(stability: Double = 0, difficulty: Double = 0, dueAt: Date? = nil, reps: Int = 0, lapses: Int = 0, lastRating: Int? = nil, lastReviewedAt: Date? = nil) {
            self.stability = stability
            self.difficulty = difficulty
            self.dueAt = dueAt
            self.reps = reps
            self.lapses = lapses
            self.lastRating = lastRating
            self.lastReviewedAt = lastReviewedAt
        }

        public var isNew: Bool { stability <= 0 || lastReviewedAt == nil }
    }

    /// FSRS-4.5 defaults, w0…w16.
    public static let defaultWeights: [Double] = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755]
    public static let decay = -0.5
    public static let factor = 19.0 / 81.0
    public static let requestedRetention = 0.9
    public static let maximumIntervalDays = 36_500.0
    /// A forgotten card comes back the same day, after this long.
    public static let relearnDelay: TimeInterval = 10 * 60

    static let w = defaultWeights

    public static func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(1 + factor * max(0, t) / s, decay)
    }

    /// Days until retrievability falls to `retention` (= S at 90 %).
    public static func interval(stability s: Double, retention: Double = requestedRetention) -> Double {
        s / factor * (pow(retention, 1 / decay) - 1)
    }

    public static func initialStability(_ rating: Rating) -> Double {
        w[rating.rawValue - 1]
    }

    public static func initialDifficulty(_ rating: Rating) -> Double {
        clamp(w[4] - Double(rating.rawValue - 3) * w[5])
    }

    public static func nextDifficulty(_ d: Double, _ rating: Rating) -> Double {
        let unclampedD0 = w[4]
        return clamp(w[7] * unclampedD0 + (1 - w[7]) * (d - w[6] * Double(rating.rawValue - 3)))
    }

    public static func recallStability(d: Double, s: Double, r: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus + 1)
    }

    public static func forgetStability(d: Double, s: Double, r: Double) -> Double {
        w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
    }

    /// The state after reviewing a card at `now` with `rating`.
    public static func review(_ state: State, rating: Rating, now: Date) -> State {
        var next = state
        if state.isNew {
            next.stability = initialStability(rating)
            next.difficulty = initialDifficulty(rating)
        } else {
            let elapsed = now.timeIntervalSince(state.lastReviewedAt ?? now) / 86_400
            let r = retrievability(elapsedDays: elapsed, stability: state.stability)
            next.stability = rating == .again
                ? forgetStability(d: state.difficulty, s: state.stability, r: r)
                : recallStability(d: state.difficulty, s: state.stability, r: r, rating: rating)
            next.difficulty = nextDifficulty(state.difficulty, rating)
        }
        if rating == .again {
            if !state.isNew { next.lapses += 1 }
            next.dueAt = now.addingTimeInterval(relearnDelay)
        } else {
            let days = min(maximumIntervalDays, max(1, interval(stability: next.stability).rounded()))
            next.dueAt = now.addingTimeInterval(days * 86_400)
        }
        next.reps += 1
        next.lastRating = rating.rawValue
        next.lastReviewedAt = now
        return next
    }

    static func clamp(_ d: Double) -> Double { min(10, max(1, d)) }
}
