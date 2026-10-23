import XCTest
import SwiftData
import UniformTypeIdentifiers
import AIQuizCore
@testable import AIQuiz

/// F-62: Anki decks saved into the library, and quizzes written back out.
@MainActor
final class AnkiLibraryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "anki-latest", withExtension: "apkg", subdirectory: "TestFixtures")
            ?? Bundle.main.url(forResource: "anki-latest", withExtension: "apkg"))
    }

    func testImportedDecksBecomeTaggedQuizzesWithTheirHistory() throws {
        let result = try AnkiImporter.importPackage(at: fixture())
        let saved = try AnkiLibrary.save(result, into: context)
        XCTAssertEqual(Set(saved.map(\.name)), ["Spanish › Verbs", "Geography"])
        let verbs = try XCTUnwrap(saved.first { $0.name == "Spanish › Verbs" })
        XCTAssertEqual(verbs.tags, ["anki"])
        XCTAssertEqual(verbs.origin, .imported)
        XCTAssertEqual(verbs.sortedCards.map(\.prompt), ["hablar", "comer", "vivir", "to live", "¿Qué es esto?", "ser (yo)"])

        let hablar = try XCTUnwrap(verbs.sortedCards.first)
        XCTAssertFalse(hablar.isNewCard, "Anki's review carries over")
        XCTAssertEqual(hablar.correctCount, 1)
        XCTAssertEqual(hablar.reps, 1)
        XCTAssertNotNil(hablar.lastSeenAt)
        let vivir = verbs.sortedCards[2]
        XCTAssertEqual(vivir.lapses, 1)
        XCTAssertEqual(vivir.wrongCount, 1)
        XCTAssertTrue(verbs.sortedCards[3].isNewCard)

        let geography = try XCTUnwrap(saved.first { $0.name == "Geography" })
        XCTAssertEqual(geography.sortedCards.map(\.cardKind), [.cloze, .cloze, .cloze])
        XCTAssertEqual(geography.sortedCards.first?.hint, "country")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuizRecord>()), 2)
    }

    func testAQuizExportsToAnkiAndReadsBackTheSame() throws {
        let quiz = QuizRecord.make(from: QuizPayload(name: "Biology › Cells", cards: [
            CardPayload(prompt: "What is ATP?", longAnswer: "Energy currency.", shortAnswer: "ATP", hint: "Power"),
            CardPayload(prompt: "{{blank}} make ATP.", longAnswer: "Mitochondria make ATP.", shortAnswer: "Mitochondria", kind: .cloze),
            CardPayload(prompt: "Pick the organelle", longAnswer: "The nucleus is an organelle.", shortAnswer: "Nucleus", kind: .multipleChoice, options: ["Nucleus", "Water"])
        ]), origin: .topic)
        context.insert(quiz)
        let reviewed = quiz.sortedCards[0]
        reviewed.schedule = FSRS.State(stability: 6, difficulty: 5.5, dueAt: Date(timeIntervalSinceNow: 6 * 86_400), reps: 2, lapses: 0,
                                       lastRating: 3, lastReviewedAt: Date(timeIntervalSinceNow: -3_600))
        try context.save()

        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID()).apkg")
        try AnkiLibrary.package(for: quiz).write(to: file)
        let back = try AnkiImporter.importPackage(at: file)
        XCTAssertEqual(back.quizzes.map(\.name), ["Biology › Cells"])
        XCTAssertEqual(back.quizzes.first?.cards.map(\.payload), quiz.sortedCards.map(\.payload))
        let schedule = try XCTUnwrap(back.quizzes.first?.cards.first?.schedule)
        XCTAssertEqual(schedule.stability, 6, accuracy: 0.001)
        XCTAssertEqual(schedule.reps, 2)
        XCTAssertTrue(back.quizzes.first?.cards[1].schedule.isNew ?? false)
    }

    func testThePickerAcceptsAnyFileAndANonAnkiFileGetsAClearMessage() throws {
        // A .apkg labelled with another app's or a generic type must not be greyed out (A-13).
        for type in [UTType.data, .zip, UTType(filenameExtension: "apkg") ?? .data] {
            XCTAssertTrue(UTType.ankiPickerTypes.contains { type.conforms(to: $0) }, "\(type.identifier) is selectable")
        }
        let notAnki = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID()).apkg")
        try Data("plain text, not a package".utf8).write(to: notAnki)
        XCTAssertThrowsError(try AnkiImporter.importPackage(at: notAnki)) { error in
            XCTAssertEqual(AnkiImportView.message(for: error), "This isn't an Anki deck. Pick a .apkg or .colpkg file exported from Anki.")
        }
    }

    func testAnAnkiDeckSharedToAIQuizGoesToTheImporterNotTheQueue() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "anki-share-\(UUID())")
        let inbox = dir.appending(path: "Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture(), to: inbox.appending(path: "1.apkg"))
        try Data(#"{"kind":"anki","file":"1.apkg","name":"Spanish.apkg"}"#.utf8).write(to: inbox.appending(path: "1.json"))
        let queue = GenerationQueue(
            store: GenerationJobStore(url: dir.appending(path: "jobs.json")), foldersRoot: dir.appending(path: "Jobs"),
            pipeline: { _, _ in throw CancellationError() }, save: { _, _ in UUID() }
        )
        var received: [URL] = []
        ShareInbox.drain(from: inbox, keepFilesIn: dir.appending(path: "Kept"), into: queue, anki: { received.append($0) })
        XCTAssertTrue(queue.jobs.isEmpty)
        let url = try XCTUnwrap(received.first)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("Spanish.apkg"))
        XCTAssertEqual(try AnkiImporter.importPackage(at: url).cardCount, 9, "the importer gets a readable copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "the inbox is emptied")
    }
}
