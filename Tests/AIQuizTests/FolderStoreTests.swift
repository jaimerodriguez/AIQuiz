import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

/// F-63: folders in the store.
@MainActor
final class FolderStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
    }

    @discardableResult
    private func quiz(_ name: String, in folder: UUID?, cards: Int = 2, due: Bool = true, archived: Bool = false) -> QuizRecord {
        let quiz = QuizRecord.make(from: QuizPayload(name: name, cards: (0..<cards).map { CardPayload(prompt: "\(name) \($0)", longAnswer: "A") }), origin: .topic)
        quiz.folderID = folder
        quiz.isArchived = archived
        if !due { for card in quiz.cards { card.dueAt = .now.addingTimeInterval(86_400 * 5); card.stability = 5; card.lastReviewedAt = .now } }
        QuizStats.refresh(quiz)
        context.insert(quiz)
        try? context.save()
        return quiz
    }

    func testCreateTrimsAndNumbersTakenNames() throws {
        let a = try FolderStore.create(named: "  Spanish ", in: nil, context: context)
        let b = try FolderStore.create(named: "spanish", in: nil, context: context)
        let c = try FolderStore.create(named: "Spanish", in: a.id, context: context)
        XCTAssertEqual([a.name, b.name, c.name], ["Spanish", "spanish 2", "Spanish"], "names are unique among siblings only")
        XCTAssertThrowsError(try FolderStore.create(named: "  ", in: nil, context: context)) { XCTAssertEqual($0 as? FolderStore.Failure, .emptyName) }
    }

    func testRenameAndMoveKeepNamesUniqueAndRefuseLoops() throws {
        let languages = try FolderStore.create(named: "Languages", in: nil, context: context)
        let spanish = try FolderStore.create(named: "Spanish", in: languages.id, context: context)
        let verbs = try FolderStore.create(named: "Verbs", in: spanish.id, context: context)
        _ = try FolderStore.create(named: "Verbs", in: nil, context: context)
        XCTAssertThrowsError(try FolderStore.move(languages, to: verbs.id, context: context)) { XCTAssertEqual($0 as? FolderStore.Failure, .wouldContainItself) }
        XCTAssertThrowsError(try FolderStore.move(languages, to: languages.id, context: context))
        try FolderStore.move(verbs, to: nil, context: context)
        XCTAssertNil(verbs.parentID)
        XCTAssertEqual(verbs.name, "Verbs 2", "moving next to a namesake numbers it")
        try FolderStore.rename(spanish, to: "Español", context: context)
        XCTAssertEqual(FolderStore.path(to: spanish.id, in: context), ["Languages", "Español"])
    }

    func testFolderQueriesFindQuizzesAtAnyDepth() throws {
        let languages = try FolderStore.create(named: "Languages", in: nil, context: context)
        let spanish = try FolderStore.create(named: "Spanish", in: languages.id, context: context)
        quiz("Top", in: nil)
        quiz("Direct", in: languages.id)
        quiz("Deep", in: spanish.id, due: false)
        quiz("Old", in: spanish.id, archived: true)
        XCTAssertEqual(Set(FolderStore.quizzes(inFolders: FolderStore.subtree(languages.id, in: context), context: context).map(\.name)), ["Direct", "Deep", "Old"])
        let summary = FolderStore.summary(of: languages, context: context)
        XCTAssertEqual(summary.quizzes, 2, "archived quizzes aren't counted")
        XCTAssertEqual(summary.due, 2, "Direct's two new cards are due; Deep's are later")
        XCTAssertEqual(FolderStore.contents(of: languages, context: context), FolderStore.Contents(folders: 1, quizzes: 3))
    }

    func testDeletingAFolderDeletesEverythingInside() throws {
        let languages = try FolderStore.create(named: "Languages", in: nil, context: context)
        let spanish = try FolderStore.create(named: "Spanish", in: languages.id, context: context)
        let keep = quiz("Keep", in: nil)
        let deep = quiz("Deep", in: spanish.id)
        let session = SessionRecord(mode: .studyRead)
        session.quiz = deep
        deep.sessions.append(session)
        quiz("Direct", in: languages.id)
        try context.save()

        try FolderStore.delete(languages, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderRecord>()), 0, "the folder and its subfolders are gone")
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuizRecord>()).map(\.name), ["Keep"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardRecord>()), keep.cards.count, "the deleted quizzes' cards went with them")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 0)
    }

    func testAPathIsFoundOrCreatedUnderAParent() throws {
        let home = try FolderStore.create(named: "Home", in: nil, context: context)
        let first = try FolderStore.folderID(forPath: ["Languages", "Spanish"], under: home.id, context: context)
        let again = try FolderStore.folderID(forPath: ["languages", "Spanish"], under: home.id, context: context)
        XCTAssertEqual(first, again, "existing folders are reused, ignoring case")
        XCTAssertEqual(FolderStore.path(to: first, in: context), ["Home", "Languages", "Spanish"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderRecord>()), 3)
        XCTAssertNil(try FolderStore.folderID(forPath: [], under: nil, context: context))
    }

    func testAQuizWhoseFolderIsMissingReturnsToTheTopLevel() throws {
        let stray = quiz("Stray", in: UUID())
        let folder = try FolderStore.create(named: "Real", in: nil, context: context)
        let filed = quiz("Filed", in: folder.id)
        XCTAssertEqual(FolderStore.repairMissingFolders(in: context), 1)
        XCTAssertNil(stray.folderID)
        XCTAssertEqual(filed.folderID, folder.id)
        XCTAssertEqual(FolderStore.repairMissingFolders(in: context), 0)
    }
}
