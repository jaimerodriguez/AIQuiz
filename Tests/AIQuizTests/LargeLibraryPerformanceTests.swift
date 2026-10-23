import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// SPEC N-8 scale target: 200 quizzes, 10 000 cards, 5 000 sessions in an on-disk store.
/// Each check takes the median of several runs on a fresh context, so cached objects
/// don't flatter the numbers. Limits come from PLAN Phase 2.
@MainActor
final class LargeLibraryPerformanceTests: XCTestCase {
    private static var dir: URL!
    private static var container: ModelContainer!
    private static var bigQuizID: UUID!

    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            dir = FileManager.default.temporaryDirectory.appending(path: "large-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let suite = "LargeLibraryPerformanceTests"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            container = try! StoreLoader.makeContainer(storeURL: dir.appending(path: "default.store"), defaults: defaults).container
            let context = container.mainContext
            UITestFixtures.seedLargeLibrary(in: context)

            let payload = QuizPayload(name: "Big quiz", cards: (0..<300).map { CardPayload(prompt: "big \($0)", longAnswer: "answer \($0)") })
            let big = QuizRecord.make(from: payload, origin: .imported)
            for s in 0..<30 {
                let session = SessionRecord(mode: .quizVoice, startedAt: .now.addingTimeInterval(Double(-s) * 3600), endedAt: .now, scorePercent: 0.5)
                session.quiz = big
                big.sessions.append(session)
            }
            context.insert(big)
            try! context.save()
            bigQuizID = big.id
        }
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            container = nil
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    private func medianMilliseconds(runs: Int = 7, _ body: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        return samples.sorted()[runs / 2]
    }

    func testTheSeededLibraryHasTheTargetSize() throws {
        let context = ModelContext(Self.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), UITestFixtures.largeQuizCount + 1)
        XCTAssertGreaterThanOrEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), 10_000)
        XCTAssertGreaterThanOrEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 5_000)
    }

    func testLibraryFetchSortedByLastStudiedUnder50ms() throws {
        let ms = try medianMilliseconds {
            let context = ModelContext(Self.container)
            var descriptor = FetchDescriptor<QuizRecord>(
                predicate: #Predicate { !$0.isArchived },
                sortBy: [SortDescriptor(\.lastStudiedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.relationshipKeyPathsForPrefetching = []
            let quizzes = try context.fetch(descriptor)
            // Touch what a row shows.
            _ = quizzes.reduce(0) { $0 + $1.cardCount + $1.name.count + ($1.bestScore == nil ? 0 : 1) + $1.tags.count }
            XCTAssertEqual(quizzes.count, UITestFixtures.largeQuizCount + 1)
        }
        print("PERF library fetch: \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 50)
    }

    func testDueTodayCountUnder100ms() throws {
        let now = Date.now
        let never = Date.distantPast
        let ms = try medianMilliseconds {
            let context = ModelContext(Self.container)
            // Never-reviewed cards (nil) count as due (SPEC F-2).
            let due = try context.fetchCount(FetchDescriptor<CardRecord>(predicate: #Predicate { card in
                (card.dueAt ?? never) <= now && card.quiz?.isArchived == false
            }))
            XCTAssertGreaterThan(due, 0)
        }
        print("PERF due today count: \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 100)
    }

    func testSearchFetchUnder50ms() throws {
        let term = "quiz 1"
        let ms = try medianMilliseconds {
            let context = ModelContext(Self.container)
            let found = try context.fetch(FetchDescriptor<QuizRecord>(
                predicate: #Predicate { !$0.isArchived && $0.tagsSearch.contains(term) },
                sortBy: [SortDescriptor(\.name)]
            ))
            XCTAssertFalse(found.isEmpty)
        }
        print("PERF search fetch: \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 50)
    }

    func testRefreshingA300CardQuizUnder20ms() throws {
        let context = ModelContext(Self.container)
        let id = Self.bigQuizID!
        let big = try XCTUnwrap(context.fetch(FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.id == id })).first)
        _ = big.cards.count  // fault the relationship in once, as the detail screen would
        let ms = medianMilliseconds {
            QuizStats.refresh(big)
        }
        print("PERF QuizStats.refresh 300 cards: \(String(format: "%.2f", ms)) ms")
        XCTAssertEqual(big.cardCount, 300)
        XCTAssertEqual(big.sessionCount, 30)
        XCTAssertLessThan(ms, 20)
    }
}
