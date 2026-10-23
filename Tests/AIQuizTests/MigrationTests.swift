import XCTest
import SwiftData
import SQLite3
import AIQuizCore
@testable import AIQuiz

/// SPEC D-10: libraries written by v0.1 and by the CR-007 build open in v2 with nothing lost.
@MainActor
final class MigrationTests: XCTestCase {
    private var dir: URL!
    private var storeURL: URL { dir.appending(path: "default.store") }
    private var defaults: UserDefaults!
    private let suite = "MigrationTests"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: v0.1 → v2

    private func writeV0Store() throws {
        let schema = Schema(versionedSchema: SchemaV0.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let context = ModelContext(container)

        let sample = SchemaV0.QuizRecord(name: "Roman Emperors", importedAt: t0, bundledSampleId: "roman-emperors")
        let imported = SchemaV0.QuizRecord(name: "Imported Deck", importedAt: t0.addingTimeInterval(60), sourceBookmark: Data([1, 2, 3]))
        let generated = SchemaV0.QuizRecord(name: "Generated", importedAt: t0.addingTimeInterval(120))
        for quiz in [sample, imported, generated] { context.insert(quiz) }

        for i in 0..<3 {
            let card = SchemaV0.CardRecord(prompt: "Q\(i)", longAnswer: "Long \(i)", shortAnswer: i == 0 ? "S" : nil, hint: i == 1 ? "H" : nil, orderIndex: i)
            card.correctCount = i
            card.wrongCount = 1
            card.lastSeenAt = t0.addingTimeInterval(Double(i))
            card.quiz = sample
        }
        let outcomes = try JSONEncoder().encode([CardOutcome(cardId: UUID(), verdict: .correct)])
        let kept = SchemaV0.SessionRecord(mode: "quizVoice", startedAt: t0, endedAt: t0.addingTimeInterval(90), scorePercent: 0.8, outcomesData: outcomes)
        kept.quiz = sample
        let dropped = SchemaV0.SessionRecord(mode: "studyRead", startedAt: t0.addingTimeInterval(500), endedAt: nil, scorePercent: 0.1, abandoned: true)
        dropped.quiz = sample
        let card = SchemaV0.CardRecord(prompt: "Only", longAnswer: "Card", orderIndex: 0)
        card.quiz = imported
        try context.save()
    }

    func testV0LibraryMigratesWithEveryField() throws {
        try writeV0Store()
        let result = try StoreLoader.makeContainer(storeURL: storeURL, defaults: defaults)
        XCTAssertNil(result.recoveredFromFailure)
        let context = ModelContext(result.container)

        let quizzes = try context.fetch(FetchDescriptor<QuizRecord>(sortBy: [SortDescriptor(\.importedAt)]))
        XCTAssertEqual(quizzes.map(\.name), ["Roman Emperors", "Imported Deck", "Generated"])
        XCTAssertEqual(quizzes.map(\.origin), [.bundled, .imported, .unknown])
        XCTAssertEqual(quizzes.map(\.createdAt), quizzes.map(\.importedAt), "createdAt = importedAt")
        XCTAssertEqual(quizzes[0].tagsSearch, " roman emperors ")
        XCTAssertEqual(quizzes[1].sourceBookmark, Data([1, 2, 3]))
        XCTAssertFalse(quizzes[0].isArchived)
        XCTAssertNil(quizzes[0].sourceKind)

        let sample = quizzes[0]
        let cards = sample.sortedCards
        XCTAssertEqual(cards.map(\.prompt), ["Q0", "Q1", "Q2"])
        XCTAssertEqual(cards.map(\.correctCount), [0, 1, 2])
        XCTAssertEqual(cards.map(\.wrongCount), [1, 1, 1])
        XCTAssertEqual(cards[0].shortAnswer, "S")
        XCTAssertEqual(cards[1].hint, "H")
        XCTAssertEqual(cards[2].lastSeenAt, t0.addingTimeInterval(2))
        XCTAssertTrue(cards.allSatisfy { $0.cardKind == .recall && $0.dueAt == nil && $0.stability == 0 && $0.reps == 0 })

        XCTAssertEqual(sample.sessions.count, 2)
        let kept = try XCTUnwrap(sample.sessions.first { !$0.abandoned })
        XCTAssertEqual(kept.durationSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(kept.outcomes.map(\.verdict), [.correct])
        XCTAssertEqual(kept.sessionMode, .quizVoice)

        // Stored counters (D-11) filled by the migration.
        XCTAssertEqual(sample.cardCount, 3)
        XCTAssertEqual(sample.sessionCount, 1, "abandoned sessions don't count")
        XCTAssertEqual(try XCTUnwrap(sample.bestScore), 0.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.averageScore), 0.8, accuracy: 0.0001)
        XCTAssertEqual(sample.dueCount, 3, "never-reviewed cards are due")
        XCTAssertEqual(sample.lastStudiedAt, t0.addingTimeInterval(90))
        XCTAssertEqual(quizzes[1].cardCount, 1)
        XCTAssertEqual(quizzes[2].cardCount, 0)
        XCTAssertGreaterThan(sample.countersUpdatedAt, t0)

        XCTAssertEqual(try backups().count, 1, "the store was backed up before the upgrade")
    }

    // MARK: CR-007 build → v2

    func testV1LibraryKeepsOriginalContentAndNotes() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
            let context = ModelContext(container)
            let web = SchemaV1.QuizRecord(name: "Web", importedAt: t0)
            web.sourceKindRaw = "webPage"
            web.sourceTitle = "en.wikipedia.org"
            web.sourceURLString = "https://en.wikipedia.org/wiki/Rome"
            web.sourceTextData = Data(String(repeating: "Article. ", count: 5_000).utf8)
            web.studyNotes = "# Notes kept from CR-006"
            let md = SchemaV1.QuizRecord(name: "Notes file", importedAt: t0, sourceBookmark: Data([9]))
            md.sourceKindRaw = "markdownFile"
            let pasted = SchemaV1.QuizRecord(name: "Pasted", importedAt: t0)
            pasted.sourceKindRaw = "pastedText"
            for quiz in [web, md, pasted] { context.insert(quiz) }
            try context.save()
        }

        let result = try StoreLoader.makeContainer(storeURL: storeURL, defaults: defaults)
        let quizzes = try ModelContext(result.container).fetch(FetchDescriptor<QuizRecord>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(quizzes.map(\.name), ["Notes file", "Pasted", "Web"])
        XCTAssertEqual(quizzes.map(\.origin), [.markdown, .pastedText, .url])
        let web = quizzes[2]
        XCTAssertEqual(web.sourceKind, .webPage)
        XCTAssertEqual(web.sourceTitle, "en.wikipedia.org")
        XCTAssertEqual(web.sourceURL?.host, "en.wikipedia.org")
        XCTAssertEqual(web.sourceText?.count, "Article. ".count * 5_000, "external-storage text survives")
        XCTAssertEqual(web.studyNotes, "# Notes kept from CR-006", "CR-006 notes are not dropped")
        XCTAssertEqual(quizzes[0].sourceBookmark, Data([9]))
    }

    func testReopeningIsIdempotentAndDoesNotBackUpAgain() throws {
        try writeV0Store()
        do {
            let first = try StoreLoader.makeContainer(storeURL: storeURL, defaults: defaults)
            XCTAssertEqual(try ModelContext(first.container).fetchCount(FetchDescriptor<QuizRecord>()), 3)
        }
        let second = try StoreLoader.makeContainer(storeURL: storeURL, defaults: defaults)
        let context = ModelContext(second.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 2)
        XCTAssertEqual(try backups().count, 1, "no second backup once the store is current")
    }

    func testUnreadableStoreIsBackedUpAndAFreshLibraryStarts() throws {
        try Data("this is not a database".utf8).write(to: storeURL)
        let result = try StoreLoader.makeContainer(storeURL: storeURL, defaults: defaults)
        let backup = try XCTUnwrap(result.recoveredFromFailure, "the failure is reported so the app can tell the user")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appending(path: "default.store").path), "the unreadable file is kept")
        XCTAssertEqual(try ModelContext(result.container).fetchCount(FetchDescriptor<QuizRecord>()), 0)
    }

    func testUpgradeBackupsArePrunedToTheNewestThree() throws {
        try Data("x".utf8).write(to: storeURL)
        let folder = StoreLoader.backupsFolder(near: storeURL)
        for name in ["2026-01-01T000000-before-v2", "2026-02-01T000000-before-v2", "2026-03-01T000000-before-v2",
                     "2026-04-01T000000-before-v2", "2026-01-15T000000-unreadable"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        StoreLoader.pruneBackups(near: storeURL, keep: 3)
        XCTAssertEqual(try backups().sorted(), ["2026-01-15T000000-unreadable", "2026-02-01T000000-before-v2",
                                               "2026-03-01T000000-before-v2", "2026-04-01T000000-before-v2"])
    }

    // MARK: Real libraries copied from the owner's iPad

    /// Opens copies of real stores listed in `AIQUIZ_REAL_STORES` (folders separated by `:`,
    /// each holding `default.store` and its `-wal`/`-shm`). Set it with
    /// `TEST_RUNNER_AIQUIZ_REAL_STORES=… scripts/test.sh`. Skipped when unset.
    func testRealLibrariesMigrateWithoutLoss() throws {
        guard let list = ProcessInfo.processInfo.environment["AIQUIZ_REAL_STORES"], !list.isEmpty else {
            throw XCTSkip("AIQUIZ_REAL_STORES not set")
        }
        for source in list.split(separator: ":").map({ URL(fileURLWithPath: String($0)) }) {
            let work = dir.appending(path: source.lastPathComponent)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            for name in ["default.store", "default.store-wal", "default.store-shm"] {
                let from = source.appending(path: name)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: work.appending(path: name))
                }
            }
            let store = work.appending(path: "default.store")
            let before = try sqliteCounts(store)
            let suiteName = "real-\(source.lastPathComponent)"
            let realDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            realDefaults.removePersistentDomain(forName: suiteName)

            let result = try StoreLoader.makeContainer(storeURL: store, defaults: realDefaults)
            XCTAssertNil(result.recoveredFromFailure, "\(source.lastPathComponent) failed to migrate")
            let context = ModelContext(result.container)
            let quizzes = try context.fetch(FetchDescriptor<QuizRecord>())
            XCTAssertEqual(quizzes.count, before.quizzes, source.lastPathComponent)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), before.cards, source.lastPathComponent)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), before.sessions, source.lastPathComponent)
            XCTAssertEqual(quizzes.map(\.cardCount).reduce(0, +), before.cards, "counters match the cards")
            XCTAssertTrue(quizzes.allSatisfy { $0.createdAt == $0.importedAt && !$0.tagsSearch.isEmpty })
            print("REAL-STORE \(source.lastPathComponent): \(before.quizzes) quizzes, \(before.cards) cards, \(before.sessions) sessions → migrated; origins \(quizzes.map(\.originRaw).sorted())")
            realDefaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: Helpers

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: StoreLoader.backupsFolder(near: storeURL).path)
    }

    private func sqliteCounts(_ url: URL) throws -> (quizzes: Int, cards: Int, sessions: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("cannot open \(url.path)")
        }
        defer { sqlite3_close(db) }
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return (count("ZQUIZRECORD"), count("ZCARDRECORD"), count("ZSESSIONRECORD"))
    }
}
