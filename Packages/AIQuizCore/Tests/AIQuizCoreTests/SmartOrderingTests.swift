import Foundation
import Testing
@testable import AIQuizCore

/// Deterministic generator for reproducible ordering tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("SmartOrdering")
struct SmartOrderingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("new cards weigh 0.5 with the stale boost")
    func newCard() {
        let w = SmartOrdering.weight(.init(), now: now)
        #expect(w == 0.5 * 1.25)
    }

    @Test("wrong cards weigh more than mastered cards")
    func wrongVsMastered() {
        let recent = now.addingTimeInterval(-60)
        let wrong = SmartOrdering.weight(.init(wrong: 5, lastSeenAt: recent), now: now)
        let mastered = SmartOrdering.weight(.init(correct: 5, lastSeenAt: recent), now: now)
        #expect(wrong > mastered)
        #expect(mastered > 0)
    }

    @Test("stale boost applies after 24 hours")
    func staleBoost() {
        let fresh = SmartOrdering.weight(.init(correct: 1, lastSeenAt: now.addingTimeInterval(-3600)), now: now)
        let stale = SmartOrdering.weight(.init(correct: 1, lastSeenAt: now.addingTimeInterval(-90_000)), now: now)
        #expect(stale == fresh * 1.25)
    }

    @Test("order is a permutation and deterministic for a seed")
    func permutation() {
        let items = Array(0..<20)
        var g1 = SeededGenerator(seed: 42)
        var g2 = SeededGenerator(seed: 42)
        let a = SmartOrdering.order(items, now: now, history: { _ in .init() }, using: &g1)
        let b = SmartOrdering.order(items, now: now, history: { _ in .init() }, using: &g2)
        #expect(a.sorted() == items)
        #expect(a == b)
    }

    @Test("heavily wrong card comes first far more often than chance")
    func wrongFirstTendency() {
        let items = Array(0..<10)
        var g = SeededGenerator(seed: 7)
        var firstIsWrong = 0
        for _ in 0..<500 {
            let ordered = SmartOrdering.order(items, now: now, history: { i in
                i == 3 ? .init(wrong: 10, lastSeenAt: now) : .init(correct: 10, lastSeenAt: now)
            }, using: &g)
            if ordered.first == 3 { firstIsWrong += 1 }
        }
        // Chance would be ~50; the wrong card's weight is ~11x a mastered card's.
        #expect(firstIsWrong > 200)
    }

    @Test("empty input")
    func empty() {
        let out = SmartOrdering.order([Int](), history: { _ in .init() })
        #expect(out.isEmpty)
    }
}
