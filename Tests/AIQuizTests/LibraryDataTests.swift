import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// Stored counters (D-11), quiz edits and JSON import (SPEC §2, F-4).
@MainActor
final class LibraryDataTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var dir: URL!

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
        dir = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeQuiz(cards: Int) -> QuizRecord {
        let payload = QuizPayload(name: "Deck", tags: ["Rome"], cards: (0..<cards).map { CardPayload(prompt: "p\($0)", longAnswer: "l\($0)") })
        let quiz = QuizRecord.make(from: payload, origin: .topic)
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    func testMakeFillsCountersAndSearchText() {
        let quiz = makeQuiz(cards: 4)
        XCTAssertEqual(quiz.cardCount, 4)
        XCTAssertEqual(quiz.dueCount, 4)
        XCTAssertEqual(quiz.sessionCount, 0)
        XCTAssertEqual(quiz.tags, ["Rome"])
        XCTAssertEqual(quiz.tagsSearch, " deck #rome ")
        XCTAssertEqual(quiz.origin, .topic)
    }

    func testRecordingASessionUpdatesCountersAndLastStudied() {
        let quiz = makeQuiz(cards: 2)
        let deck = ScoreStore.makeDeck(for: quiz)
        deck.record(.correct); deck.next()
        deck.record(.wrong); deck.next()
        ScoreStore.recordSession(for: quiz, deck: deck, mode: .quizVoice, in: context)
        XCTAssertEqual(quiz.sessionCount, 1)
        XCTAssertEqual(try XCTUnwrap(quiz.bestScore), 0.5, accuracy: 0.0001)
        XCTAssertNotNil(quiz.lastStudiedAt)
        XCTAssertGreaterThan(quiz.sessions[0].durationSeconds, -1)
    }

    func testRenameAndTagsKeepSearchTextInStep() throws {
        let quiz = makeQuiz(cards: 1)
        quiz.rename(to: "Roman Emperors")
        quiz.setTags(["history", "#Ancient Rome", "history"])
        XCTAssertEqual(quiz.tags, ["history", "Ancient-Rome"])
        XCTAssertEqual(quiz.tagsSearch, " roman emperors #history #ancient-rome ")

        let needle = TagsSearch.needle(forTag: "ancient-rome")
        let found = try context.fetch(FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.tagsSearch.contains(needle) }))
        XCTAssertEqual(found.map(\.name), ["Roman Emperors"])
    }

    func testEditingAndDeletingCardsRefreshesCounters() throws {
        let quiz = makeQuiz(cards: 3)
        let card = quiz.sortedCards[0]
        card.apply(CardPayload(prompt: "Pick one", longAnswer: "B is right", shortAnswer: "B", kind: .multipleChoice, options: ["A", "B"]))
        XCTAssertEqual(card.cardKind, .multipleChoice)
        XCTAssertEqual(card.options, ["A", "B"])
        XCTAssertEqual(card.payload.kind, .multipleChoice)

        quiz.cards.removeAll { $0.id == card.id }
        context.delete(card)
        QuizStats.refresh(quiz)
        try context.save()
        XCTAssertEqual(quiz.cardCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), 2)
    }

    func testStaleCountersRefreshAfterMidnight() throws {
        let quiz = makeQuiz(cards: 2)
        quiz.dueCount = 0
        quiz.countersUpdatedAt = Date(timeIntervalSinceNow: -2 * 86_400)
        try context.save()
        QuizStats.refreshStale(in: context)
        XCTAssertEqual(quiz.dueCount, 2)
        XCTAssertGreaterThan(quiz.countersUpdatedAt, Date(timeIntervalSinceNow: -60))
    }

    func testExportRoundTripsEveryField() throws {
        let payload = QuizPayload(name: "Full", description: "About", tags: ["a", "b"], language: "es", cards: [
            CardPayload(prompt: "p", longAnswer: "l", shortAnswer: "x", hint: "h", kind: .multipleChoice, options: ["x", "y"], explanation: "e", mnemonic: "m")
        ])
        let quiz = QuizRecord.make(from: payload, origin: .imported)
        context.insert(quiz)
        XCTAssertEqual(try QuizDecoder.decode(QuizDecoder.encode(quiz.payload)), payload)
    }

    func testImportReadsNewFieldsAndNamesTheFileOnError() throws {
        let good = dir.appending(path: "rome.json")
        try Data(#"{"quiz":{"name":"Rome","description":"d","tags":["history"],"language":"en","cards":[{"prompt":"p","long-answer":"l","kind":"trueFalse","short_answer":"true"}]}}"#.utf8).write(to: good)
        let bad = dir.appending(path: "broken.json")
        try Data(#"{"quiz":{"name":"X","cards":[{"prompt":"Pick","long_answer":"l","kind":"multipleChoice","short_answer":"a"}]}}"#.utf8).write(to: bad)

        XCTAssertThrowsError(try QuizImporter.importFiles([good, bad], into: context)) { error in
            XCTAssertEqual(error.localizedDescription, "broken.json: Card 1: a multiple-choice card needs 2 to 6 options; it has 0.")
        }
        let quizzes = try context.fetch(FetchDescriptor<QuizRecord>())
        XCTAssertEqual(quizzes.map(\.name), ["Rome"], "the good file is still imported")
        let rome = quizzes[0]
        XCTAssertEqual(rome.origin, .imported)
        XCTAssertEqual(rome.descriptionText, "d")
        XCTAssertEqual(rome.language, "en")
        XCTAssertEqual(rome.tags, ["history"])
        XCTAssertEqual(rome.cards.first?.cardKind, .trueFalse)
        XCTAssertNotNil(rome.sourceBookmark)
    }

    func testMalformedJSONNamesTheMissingKey() throws {
        let file = dir.appending(path: "nolong.json")
        try Data(#"{"quiz":{"name":"X","cards":[{"prompt":"p"}]}}"#.utf8).write(to: file)
        XCTAssertThrowsError(try QuizImporter.importFiles([file], into: context)) { error in
            XCTAssertEqual(error.localizedDescription, "nolong.json: missing \"long_answer\" (at cards › card 1).")
        }
    }
}

/// SPEC N-8: list rows never traverse relationships. A source check, so a regression fails
/// the build's tests rather than showing up as a slow library on a full device.
final class LibraryRulesTests: XCTestCase {
    func testLibraryListNeverReadsCardsOrSessions() throws {
        let library = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AIQuiz/Library")
        for file in ["LibraryView.swift", "QuizActions.swift"] {
            let source = try String(contentsOf: library.appending(path: file), encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                XCTAssertFalse(code.contains(".cards") || code.contains(".sessions"),
                               "\(file):\(number + 1) reads a quiz's cards or sessions in the library list: \(line)")
            }
        }
    }
}
