import Foundation
import Testing
import LLMKit
@testable import AIQuizCore

/// Reference values computed independently from the published FSRS-4.5 formulas and default
/// parameters (a separate Python implementation, PLAN Phase 7). Tolerance 1 %.
private func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool {
    abs(a - b) <= abs(b) * tolerance
}

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("FSRS-4.5 against reference values (F-40)")
struct FSRSTests {
    @Test("initial difficulty and stability for each rating")
    func initial() {
        #expect(FSRS.Rating.allCases.map(FSRS.initialDifficulty).enumerated().allSatisfy { close($0.element, [7.6214, 6.3916, 5.1618, 3.932][$0.offset]) })
        #expect(FSRS.initialStability(.good) == 3.7145)
        #expect(close(FSRS.interval(stability: 3.7145), 3.7145), "90 % retention means interval = stability")
        #expect(close(FSRS.retrievability(elapsedDays: 10, stability: 5), 0.825029))
    }

    /// Reviews each card on its due date and checks stability and difficulty after each step.
    private func run(_ first: FSRS.Rating, _ steps: [(FSRS.Rating, days: Double)]) -> [FSRS.State] {
        var state = FSRS.review(FSRS.State(), rating: first, now: t0)
        var states = [state]
        var now = t0
        for (rating, days) in steps {
            now = now.addingTimeInterval(days * day)
            state = FSRS.review(state, rating: rating, now: now)
            states.append(state)
        }
        return states
    }

    @Test("Good, Good, Good, Good")
    func goodSequence() {
        let s = run(.good, [(.good, 4), (.good, 15), (.good, 48)])
        #expect(s.map(\.stability).enumerated().allSatisfy { close($0.element, [3.7145, 14.8081, 49.4616, 143.8974][$0.offset]) }, "\(s.map(\.stability))")
        #expect(s.allSatisfy { close($0.difficulty, 5.1618) })
        #expect(s.last?.reps == 4)
        #expect(s.last?.lapses == 0)
    }

    @Test("Good, then Again (a lapse), then Good")
    func lapse() {
        let s = run(.good, [(.again, 4), (.good, 1)])
        #expect(close(s[1].stability, 1.4332), "\(s[1].stability)")
        #expect(close(s[1].difficulty, 6.9012))
        #expect(s[1].lapses == 1)
        #expect(s[1].dueAt == t0.addingTimeInterval(4 * day + FSRS.relearnDelay), "a forgotten card is due again shortly")
        #expect(close(s[2].stability, 3.7377))
        #expect(close(s[2].difficulty, 6.8472))
    }

    @Test("Easy then Hard, and Again on a new card")
    func easyHardAndNewAgain() {
        let easyHard = run(.easy, [(.hard, 14)])
        #expect(close(easyHard[0].stability, 13.8206))
        #expect(close(easyHard[1].stability, 22.8012), "\(easyHard[1].stability)")
        #expect(close(easyHard[1].difficulty, 4.8398))
        let again = run(.again, [(.good, 1)])
        #expect(close(again[0].stability, 0.4872))
        #expect(again[0].lapses == 0, "a new card's first Again isn't a lapse")
        #expect(close(again[1].stability, 2.4225))
        #expect(close(again[1].difficulty, 7.5452))
    }

    @Test("due dates follow the interval in whole days")
    func dueDates() {
        let first = FSRS.review(FSRS.State(), rating: .good, now: t0)
        #expect(first.dueAt == t0.addingTimeInterval(4 * day), "3.71 days rounds to 4")
        let hard = FSRS.review(FSRS.State(), rating: .hard, now: t0)
        #expect(hard.dueAt == t0.addingTimeInterval(1 * day))
        #expect(first.lastRating == 3)
        #expect(first.lastReviewedAt == t0)
    }

    @Test("verdicts map to ratings; skipped has none")
    func mapping() {
        #expect(FSRS.Rating(.wrong) == .again)
        #expect(FSRS.Rating(.partial) == .hard)
        #expect(FSRS.Rating(.correct) == .good)
        #expect(FSRS.Rating(.correct, easy: true) == .easy)
        #expect(FSRS.Rating(.skipped) == nil)
    }
}

@Suite("Scheduler order and session size (§10)")
struct SchedulerTests {
    struct Item: Equatable { let name: String; let due: Date?; let isNew: Bool }

    private let items = [
        Item(name: "later2", due: t0.addingTimeInterval(9 * day), isNew: false),
        Item(name: "new1", due: nil, isNew: true),
        Item(name: "due-old", due: t0.addingTimeInterval(-5 * day), isNew: false),
        Item(name: "later1", due: t0.addingTimeInterval(2 * day), isNew: false),
        Item(name: "due-recent", due: t0.addingTimeInterval(-1 * day), isNew: false),
        Item(name: "new2", due: nil, isNew: true)
    ]

    private func order(seed: UInt64) -> [Item] {
        var generator = SeededGenerator(seed: seed)
        return Scheduler.order(items, now: t0, dueAt: \.due, isNew: \.isNew, using: &generator)
    }

    @Test("due (oldest first), then new, then later by due date")
    func groups() {
        let names = order(seed: 1).map(\.name)
        #expect(Set(names.prefix(2)) == ["due-old", "due-recent"])
        #expect(Set(names[2...3]) == ["new1", "new2"])
        #expect(Set(names.suffix(2)) == ["later1", "later2"])
    }

    @Test("the light shuffle never moves a card across groups, and does shuffle sometimes")
    func shuffleStaysInGroup() {
        var orders = Set<[String]>()
        for seed in UInt64(0)..<200 {
            let ordered = order(seed: seed)
            let groups = ordered.map { Scheduler.group(dueAt: $0.due, isNew: $0.isNew, now: t0) }
            #expect(groups == groups.sorted(), "seed \(seed): \(ordered.map(\.name))")
            orders.insert(ordered.map(\.name))
        }
        #expect(orders.count > 1, "the order varies")
        #expect(orders.contains(["due-old", "due-recent", "new1", "new2", "later1", "later2"]), "the unshuffled order occurs")
    }

    @Test("quiz sessions take due and new cards up to the cap; never empty")
    func sessions() {
        let ordered = order(seed: 3)
        #expect(Scheduler.quizSession(ordered, now: t0, dueAt: \.due, isNew: \.isNew, cap: 20, includeNotDue: false).count == 4)
        #expect(Scheduler.quizSession(ordered, now: t0, dueAt: \.due, isNew: \.isNew, cap: 3, includeNotDue: false).count == 3)
        #expect(Scheduler.quizSession(ordered, now: t0, dueAt: \.due, isNew: \.isNew, cap: 20, includeNotDue: true).count == 6)
        let allLater = items.filter { $0.name.hasPrefix("later") }
        #expect(Scheduler.quizSession(allLater, now: t0, dueAt: \.due, isNew: \.isNew, cap: 20, includeNotDue: false).count == 2, "nothing due → the whole deck")
    }
}

@Suite("Due reminder (F-42)")
struct DueReminderTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test("today when the time is ahead, tomorrow when it has passed")
    func nextFire() {
        #expect(DueReminder.nextFireDate(hour: 18, minute: 30, after: date(23, 9, 0), calendar: calendar) == date(23, 18, 30))
        #expect(DueReminder.nextFireDate(hour: 18, minute: 30, after: date(23, 18, 30), calendar: calendar) == date(24, 18, 30), "exactly now means tomorrow")
        #expect(DueReminder.nextFireDate(hour: 7, minute: 0, after: date(31, 22, 0), calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 7)), "across a month end")
    }

    @Test("message text, and none when nothing is due")
    func message() {
        #expect(DueReminder.message(cards: 12, quizzes: 3) == "12 cards due in 3 quizzes")
        #expect(DueReminder.message(cards: 1, quizzes: 1) == "1 card due in 1 quiz")
        #expect(DueReminder.message(cards: 0, quizzes: 0) == nil)
    }
}

@Suite("Insights (F-43)")
struct InsightsTests {
    private func quiz(_ name: String, cards: Int, wrong: Int) -> InsightsQuiz {
        InsightsQuiz(
            name: name,
            sessions: (0..<12).map { .init(date: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 86_400), mode: "quizVoice", score: 0.5) },
            cards: (0..<cards).map { .init(id: UUID(), prompt: "\(name) question \($0) " + String(repeating: "detail ", count: 10), correct: 1, partial: 0, wrong: wrong, lapses: 1) }
        )
    }

    @Test("the digest keeps the last 10 sessions, troublesome cards first, under the token cap")
    func digestCap() {
        let quizzes = (0..<60).map { quiz("Quiz \($0)", cards: 20, wrong: $0 % 5) }
        let digest = InsightsReporter.digest(quizzes)
        #expect(digest.count / 4 <= InsightsReporter.tokenBudget, "\(digest.count / 4) tokens")
        #expect(digest.hasPrefix("## Quiz 4"), "the quiz with the most trouble comes first")
        let firstBlock = digest.components(separatedBy: "\n\n")[0]
        #expect(firstBlock.components(separatedBy: ";").count == 10, "last 10 sessions")
        #expect(firstBlock.components(separatedBy: "\n- [").count - 1 == 15, "at most 15 cards per quiz")
    }

    @Test("the report maps short ids back to cards and drops invalid drill cards")
    func report() async throws {
        let q = quiz("Rome", cards: 3, wrong: 2)
        let id = InsightsReporter.shortId(q.cards[1].id)
        let client = FakeLLMClient.scripted([#"{"headline":"Strong on dates, shaky on successions.","strengths":["Dates"],"confusions":[{"description":"Tiberius vs Caligula","card_ids":["[\#(id)]","NOPE"]}],"recommendations":["Drill successions"],"drill_cards":[{"prompt":"Who followed Tiberius?","long_answer":"Caligula.","short_answer":"Caligula","hint":null},{"prompt":"","long_answer":"x","short_answer":null,"hint":null}]}"#])
        let report = try await InsightsReporter.report([q], using: client)
        #expect(report.headline.hasPrefix("Strong"))
        #expect(report.confusions[0].cardIds == [q.cards[1].id])
        #expect(report.drillCards.map(\.prompt) == ["Who followed Tiberius?"])
        #expect(client.recorder.requests[0].responseFormat?.name == "insights")
    }
}
