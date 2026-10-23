import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

@MainActor
final class OriginalContentTests: XCTestCase {
    private var container: ModelContainer!
    private var tempDir: URL!

    override func setUp() async throws {
        container = try ModelContainer(
            for: QuizRecord.self, CardRecord.self, SessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let payload = QuizPayload(name: "Q", cards: [CardPayload(prompt: "p1", longAnswer: "l1"), CardPayload(prompt: "p2", longAnswer: "l2")])

    func testWebPageSourceIsStoredAndRefetched() throws {
        let article = String(repeating: "Article text. ", count: 2_000)
        let record = QuizRecord.make(from: payload, source: OriginalSource(
            kind: .webPage, title: "en.wikipedia.org", text: article, url: URL(string: "https://en.wikipedia.org/wiki/Rome")
        ))
        container.mainContext.insert(record)
        try container.mainContext.save()

        let fetched = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<QuizRecord>()).first)
        XCTAssertEqual(fetched.sourceKind, .webPage)
        XCTAssertEqual(fetched.sourceTitle, "en.wikipedia.org")
        XCTAssertEqual(fetched.sourceURL?.absoluteString, "https://en.wikipedia.org/wiki/Rome")
        XCTAssertEqual(fetched.sourceText, article, "external-storage copy round-trips")
        XCTAssertEqual(fetched.cards.sorted { $0.orderIndex < $1.orderIndex }.map(\.prompt), ["p1", "p2"])
    }

    func testPastedAndTopicQuizzes() {
        let pasted = QuizRecord.make(from: payload, source: OriginalSource(kind: .pastedText, title: "Pasted text", text: "## Heading\nBody"))
        XCTAssertEqual(pasted.sourceKind, .pastedText)
        XCTAssertEqual(pasted.sourceText, "## Heading\nBody")
        XCTAssertNil(pasted.sourceURL)

        let topic = QuizRecord.make(from: payload)
        XCTAssertNil(topic.sourceKind, "topic quizzes have no original content")
        XCTAssertNil(topic.sourceText)
        XCTAssertNil(topic.studyNotes)
    }

    func testMarkdownFileSourceKeepsTheBookmark() throws {
        let file = tempDir.appendingPathComponent("notes.md")
        try "# Original\nText".write(to: file, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(OriginalFileLoader.bookmark(for: file))
        let record = QuizRecord.make(from: payload, source: OriginalSource(
            kind: .markdownFile, title: "notes.md", text: "# Original\nText", fileBookmark: bookmark
        ))
        XCTAssertEqual(record.sourceBookmark, bookmark)
        XCTAssertEqual(record.sourceKind, .markdownFile)
    }

    func testLoaderReadsTheCurrentFileContents() async throws {
        let file = tempDir.appendingPathComponent("live.md")
        try "# Version 1".write(to: file, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(OriginalFileLoader.bookmark(for: file))
        try "# Version 2, edited later".write(to: file, atomically: true, encoding: .utf8)

        let outcome = await OriginalFileLoader.load(bookmark: bookmark, savedCopy: "# Version 1")
        XCTAssertEqual(outcome, .original("# Version 2, edited later"), "the original file is shown, not the saved copy")
    }

    func testLoaderFallsBackToSavedCopyWhenTheFileIsGone() async throws {
        let file = tempDir.appendingPathComponent("gone.md")
        try "# Gone".write(to: file, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(OriginalFileLoader.bookmark(for: file))
        try FileManager.default.removeItem(at: file)

        let outcome = await OriginalFileLoader.load(bookmark: bookmark, savedCopy: "# Saved")
        guard case .savedCopy(let text, let reason) = outcome else {
            return XCTFail("expected the saved copy, got \(outcome)")
        }
        XCTAssertEqual(text, "# Saved")
        XCTAssertTrue(reason.contains("copy saved when the quiz was made"))
    }

    func testLoaderWithNothingAvailable() async {
        let outcome = await OriginalFileLoader.load(bookmark: nil, savedCopy: nil)
        guard case .unavailable = outcome else { return XCTFail("got \(outcome)") }
    }
}
