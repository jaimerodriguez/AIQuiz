import XCTest
import SwiftData
import AIQuizCore
@testable import AIQuiz

@MainActor
final class StudyNotesStorageTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: QuizRecord.self, CardRecord.self, SessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testMakeStoresNotesSourceAndCardsInOrder() throws {
        let payload = QuizPayload(
            name: "Rome",
            cards: [CardPayload(prompt: "p1", longAnswer: "l1"), CardPayload(prompt: "p2", longAnswer: "l2", hint: "h")],
            studyNotes: "## Notes\nBody"
        )
        let source = String(repeating: "Long article text. ", count: 2_000)
        let record = QuizRecord.make(from: payload, sourceText: source, sourceURL: URL(string: "https://example.com/a"))
        container.mainContext.insert(record)
        try container.mainContext.save()

        let fetched = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<QuizRecord>()).first)
        XCTAssertEqual(fetched.studyNotes, "## Notes\nBody")
        XCTAssertEqual(fetched.sourceText, source, "external-storage source text round-trips")
        XCTAssertEqual(fetched.sourceURL?.absoluteString, "https://example.com/a")
        XCTAssertEqual(fetched.cards.sorted { $0.orderIndex < $1.orderIndex }.map(\.prompt), ["p1", "p2"])
    }

    func testPayloadExportIncludesNotesAndCardOrder() throws {
        let record = QuizRecord.make(from: QuizPayload(
            name: "N",
            cards: [CardPayload(prompt: "a", longAnswer: "1"), CardPayload(prompt: "b", longAnswer: "2")],
            studyNotes: "notes"
        ))
        container.mainContext.insert(record)
        let exported = record.payload
        XCTAssertEqual(exported.studyNotes, "notes")
        XCTAssertEqual(exported.cards.map(\.prompt), ["a", "b"])
        let roundTrip = try QuizDecoder.decode(QuizDecoder.encode(exported))
        XCTAssertEqual(roundTrip, exported)
    }

    func testQuizWithoutNotesOrSource() {
        let record = QuizRecord.make(from: QuizPayload(name: "Plain", cards: []))
        XCTAssertNil(record.studyNotes)
        XCTAssertNil(record.sourceText)
        XCTAssertNil(record.sourceURL)
    }

    func testGenerationProgressLabels() {
        let progress = GenerationProgress()
        XCTAssertEqual(progress.label, "Generating…")
        progress.phase = .writingNotes(words: 0)
        XCTAssertEqual(progress.label, "Writing study notes…")
        progress.phase = .writingNotes(words: 240)
        XCTAssertEqual(progress.label, "Writing study notes… 240 words")
        progress.phase = .writingCards
        XCTAssertEqual(progress.label, "Writing cards…")
    }
}
