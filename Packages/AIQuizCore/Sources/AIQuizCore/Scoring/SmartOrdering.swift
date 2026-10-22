import Foundation

/// v1 "smart ordering": weighted sampling without replacement so cards the user
/// gets wrong tend to come first. Replaced by FSRS in PLAN Phase 7; kept here so it
/// is testable until then.
public enum SmartOrdering {
    public struct History: Sendable, Hashable {
        public var correct: Int
        public var partial: Int
        public var wrong: Int
        public var lastSeenAt: Date?

        public init(correct: Int = 0, partial: Int = 0, wrong: Int = 0, lastSeenAt: Date? = nil) {
            self.correct = correct
            self.partial = partial
            self.wrong = wrong
            self.lastSeenAt = lastSeenAt
        }
    }

    /// Weight in (0, 1.25]. New cards get 0.5. Cards not seen for over a day get a 1.25× boost.
    public static func weight(_ h: History, now: Date) -> Double {
        let total = h.correct + h.partial + h.wrong
        let wrongish = Double(h.wrong) + 0.5 * Double(h.partial)
        let base = total == 0 ? 0.5 : (wrongish + 1.0) / (Double(total) + 2.0)
        let stale = h.lastSeenAt.map { now.timeIntervalSince($0) > 86_400 } ?? true
        return base * (stale ? 1.25 : 1.0)
    }

    /// Returns a permutation of `items`, sampled without replacement by weight.
    public static func order<T, G: RandomNumberGenerator>(
        _ items: [T],
        now: Date,
        history: (T) -> History,
        using generator: inout G
    ) -> [T] {
        guard !items.isEmpty else { return [] }
        var pool = items
        var weights = items.map { weight(history($0), now: now) }
        var result: [T] = []
        result.reserveCapacity(pool.count)

        while !pool.isEmpty {
            let total = weights.reduce(0, +)
            guard total > 0 else {
                result.append(contentsOf: pool)
                break
            }
            let r = Double.random(in: 0..<total, using: &generator)
            var acc = 0.0
            var picked = pool.count - 1
            for (i, w) in weights.enumerated() {
                acc += w
                if r < acc { picked = i; break }
            }
            result.append(pool.remove(at: picked))
            weights.remove(at: picked)
        }
        return result
    }

    public static func order<T>(_ items: [T], now: Date = .now, history: (T) -> History) -> [T] {
        var g = SystemRandomNumberGenerator()
        return order(items, now: now, history: history, using: &g)
    }
}
