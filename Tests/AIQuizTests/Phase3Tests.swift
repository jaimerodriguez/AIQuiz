import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// F-5 re-link, S-14 debug log, S-15 privacy clears, F-6 seeding once, F-60 flag.
@MainActor
final class Phase3Tests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "Phase3Tests"

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
        dir = FileManager.default.temporaryDirectory.appending(path: "p3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func importedQuiz(from file: URL) throws -> QuizRecord {
        try Data(#"{"quiz":{"name":"Imported","cards":[{"prompt":"p","long_answer":"l"}]}}"#.utf8).write(to: file)
        let quiz = try QuizImporter.makeRecord(from: file)
        context.insert(quiz)
        try context.save()
        return quiz
    }

    // MARK: F-5

    func testMissingSourceIsDetectedAndRelinkReplacesTheBookmark() throws {
        let original = dir.appending(path: "deck.json")
        let quiz = try importedQuiz(from: original)
        XCTAssertTrue(SourceLink.hasFileSource(quiz))
        let oldBookmark = try XCTUnwrap(quiz.sourceBookmark)
        XCTAssertFalse(SourceLink.isMissing(bookmark: oldBookmark))

        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(SourceLink.isMissing(bookmark: oldBookmark), "a deleted file shows as missing")

        let replacement = dir.appending(path: "deck-moved.json")
        try Data("{}".utf8).write(to: replacement)
        try SourceLink.relink(quiz, to: replacement)
        let newBookmark = try XCTUnwrap(quiz.sourceBookmark)
        XCTAssertNotEqual(newBookmark, oldBookmark, "re-link replaces the bookmark")
        XCTAssertFalse(SourceLink.isMissing(bookmark: newBookmark))
        XCTAssertEqual(quiz.cardCount, 1, "cards are untouched")
    }

    func testSourceStatusChecksOnceAndAfterRelink() async throws {
        let original = dir.appending(path: "a.json")
        let quiz = try importedQuiz(from: original)
        let status = SourceStatus()
        await status.check(quiz)
        XCTAssertFalse(status.isMissing(quiz))
        try FileManager.default.removeItem(at: original)
        await status.check(quiz)
        XCTAssertFalse(status.isMissing(quiz), "the same bookmark is not checked twice")

        let moved = dir.appending(path: "b.json")
        try Data("{}".utf8).write(to: moved)
        try SourceLink.relink(quiz, to: moved)
        try FileManager.default.removeItem(at: moved)
        await status.check(quiz)
        XCTAssertTrue(status.isMissing(quiz), "a new bookmark is checked")
    }

    func testTopicQuizzesHaveNoFileSource() {
        let quiz = QuizRecord.make(from: QuizPayload(name: "T", cards: []), origin: .topic)
        XCTAssertFalse(SourceLink.hasFileSource(quiz))
    }

    // MARK: S-15

    private func studiedQuiz() -> QuizRecord {
        let quiz = QuizRecord.make(from: QuizPayload(name: "Q", cards: [CardPayload(prompt: "p", longAnswer: "l")]), origin: .topic)
        context.insert(quiz)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.wrong); deck.next()
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)
        return quiz
    }

    func testClearSessionHistoryKeepsQuizzesAndResetsCounts() throws {
        let quiz = studiedQuiz()
        XCTAssertEqual(quiz.sessionCount, 1)
        try LibraryMaintenance.clearSessionHistory(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 1)
        XCTAssertEqual(quiz.sessionCount, 0)
        XCTAssertNil(quiz.bestScore)
        XCTAssertNil(quiz.lastStudiedAt)
        XCTAssertEqual(quiz.cards.first?.wrongCount, 0)
    }

    func testClearLibraryDeletesEverything() throws {
        _ = studiedQuiz()
        try LibraryMaintenance.clearLibrary(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 0)
    }

    // MARK: F-6

    func testSamplesAreSeededOnFirstLaunchOnly() throws {
        SampleQuizzes.seedOnFirstLaunch(in: context, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 3)
        try LibraryMaintenance.clearLibrary(in: context)
        SampleQuizzes.seedOnFirstLaunch(in: context, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 0, "a cleared library stays empty")
    }

    func testExistingLibrariesAreNotReseeded() throws {
        context.insert(QuizRecord.make(from: QuizPayload(name: "Mine", cards: []), origin: .imported))
        try context.save()
        SampleQuizzes.seedOnFirstLaunch(in: context, defaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuizRecord>()).map(\.name), ["Mine"])
        XCTAssertTrue(defaults.bool(forKey: SampleQuizzes.seededKey))
    }

    // MARK: S-14

    func testDebugLogWritesOnlyWhileEnabled() {
        let log = DebugLogFile(url: dir.appending(path: "debug.log"), maxBytes: 400)
        log.append(level: "info", category: "test", "before")
        XCTAssertEqual(log.size, 0, "nothing is written while off")
        log.isEnabled = true
        log.append(level: "info", category: "test", "hello")
        XCTAssertGreaterThan(log.size, 0)
        for i in 0..<40 { log.append(level: "debug", category: "test", "line \(i)") }
        XCTAssertLessThanOrEqual(log.size, 400 + 120, "the file is trimmed")
        log.clear()
        XCTAssertEqual(log.size, 0)
    }

    // MARK: F-60, S-5

    func testOnboardingFlagAndSpeechLanguagePersist() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.onboardingDone)
        settings.onboardingDone = true
        settings.sttLocaleIdentifier = "es-ES"
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.onboardingDone, "shown once")
        XCTAssertEqual(reloaded.sttLocale.identifier, "es-ES")
        reloaded.sttLocaleIdentifier = nil
        XCTAssertEqual(AppSettings(defaults: defaults).sttLocale, .current)
    }
}
