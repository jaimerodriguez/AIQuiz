import Foundation

/// Deck order and session size (SPEC §10). Replaces v1's smart weighting.
public enum Scheduler {
    public enum Group: Int, Sendable, Comparable {
        case due, new, later
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public static func group(dueAt: Date?, isNew: Bool, now: Date) -> Group {
        if isNew || dueAt == nil { return .new }
        return dueAt! <= now ? .due : .later
    }

    /// Due cards (oldest due first), then never-reviewed cards, then the rest by due date.
    /// Within each group neighbours swap with probability 0.3, so the order varies a little
    /// without a card ever leaving its group.
    public static func order<Item>(
        _ items: [Item],
        now: Date,
        dueAt: (Item) -> Date?,
        isNew: (Item) -> Bool,
        using generator: inout some RandomNumberGenerator
    ) -> [Item] {
        let keyed = items.enumerated().map { (offset: $0.offset, item: $0.element, group: group(dueAt: dueAt($0.element), isNew: isNew($0.element), now: now), due: dueAt($0.element)) }
        let sorted = keyed.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }
        var result = sorted
        var i = 0
        while i < result.count - 1 {
            if result[i].group == result[i + 1].group, Double.random(in: 0..<1, using: &generator) < 0.3 {
                result.swapAt(i, i + 1)
                i += 2
            } else {
                i += 1
            }
        }
        return result.map(\.item)
    }

    /// Cards for a quiz session (SPEC §10): due and new cards, capped at `cap`; with
    /// `includeNotDue` the rest follow. When nothing is due or new, the whole deck is used so
    /// a quiz is never empty.
    public static func quizSession<Item>(
        _ ordered: [Item],
        now: Date,
        dueAt: (Item) -> Date?,
        isNew: (Item) -> Bool,
        cap: Int,
        includeNotDue: Bool
    ) -> [Item] {
        let ready = ordered.filter { group(dueAt: dueAt($0), isNew: isNew($0), now: now) != .later }
        let pool = includeNotDue || ready.isEmpty ? ordered : ready
        return Array(pool.prefix(max(1, cap)))
    }
}
