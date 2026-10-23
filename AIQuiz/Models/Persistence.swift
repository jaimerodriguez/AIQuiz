import Foundation
import SwiftData
import AIQuizCore

@Model
final class QuizRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var importedAt: Date
    var sourceBookmark: Data?
    var bundledSampleId: String?

    // Original content the quiz was generated from (CR-007). All optional, so SwiftData
    // migrates existing stores automatically. `sourceBookmark` (above) is reused for the
    // Markdown file a quiz was generated from.
    /// `QuizSourceKind` raw value; nil for topic and imported quizzes.
    var sourceKindRaw: String?
    /// File name or page host, for display.
    var sourceTitle: String?
    /// Copy of the original text at generation time (pasted text, file contents, or a page's
    /// extracted article). Stored outside the row so library lists don't load it (SPEC N-8).
    @Attribute(.externalStorage) var sourceTextData: Data?
    /// Web page the quiz was generated from.
    var sourceURLString: String?
    /// Unused since CR-007. Kept so AI notes written by a pre-release build on the owner's iPad
    /// are not deleted; drop in the Phase 2 schema with the owner's agreement.
    var studyNotes: String?

    @Relationship(deleteRule: .cascade, inverse: \CardRecord.quiz)
    var cards: [CardRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SessionRecord.quiz)
    var sessions: [SessionRecord] = []

    init(
        id: UUID = UUID(),
        name: String,
        importedAt: Date = .now,
        sourceBookmark: Data? = nil,
        bundledSampleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.importedAt = importedAt
        self.sourceBookmark = sourceBookmark
        self.bundledSampleId = bundledSampleId
    }
}

@Model
final class CardRecord {
    @Attribute(.unique) var id: UUID
    var prompt: String
    var longAnswer: String
    var shortAnswer: String?
    var hint: String?
    var orderIndex: Int

    var correctCount: Int
    var partialCount: Int
    var wrongCount: Int
    var lastSeenAt: Date?

    var quiz: QuizRecord?

    init(
        id: UUID = UUID(),
        prompt: String,
        longAnswer: String,
        shortAnswer: String? = nil,
        hint: String? = nil,
        orderIndex: Int
    ) {
        self.id = id
        self.prompt = prompt
        self.longAnswer = longAnswer
        self.shortAnswer = shortAnswer
        self.hint = hint
        self.orderIndex = orderIndex
        self.correctCount = 0
        self.partialCount = 0
        self.wrongCount = 0
    }

    /// History in the shape the ordering algorithm consumes.
    var history: SmartOrdering.History {
        .init(correct: correctCount, partial: partialCount, wrong: wrongCount, lastSeenAt: lastSeenAt)
    }
}

extension CardSnapshot {
    /// Copy a card's content for use in a session (DECISIONS ADR-009).
    init(_ record: CardRecord) {
        self.init(
            id: record.id,
            prompt: record.prompt,
            longAnswer: record.longAnswer,
            shortAnswer: record.shortAnswer,
            hint: record.hint
        )
    }
}

@Model
final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var mode: String
    var startedAt: Date
    var endedAt: Date?
    var scorePercent: Double?
    var abandoned: Bool
    var outcomesData: Data

    var quiz: QuizRecord?

    init(
        id: UUID = UUID(),
        mode: SessionMode,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        scorePercent: Double? = nil,
        abandoned: Bool = false,
        outcomes: [CardOutcome] = []
    ) {
        self.id = id
        self.mode = mode.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.scorePercent = scorePercent
        self.abandoned = abandoned
        self.outcomesData = (try? JSONEncoder().encode(outcomes)) ?? Data()
    }

    var sessionMode: SessionMode { SessionMode(rawValue: mode) ?? .studyRead }

    var outcomes: [CardOutcome] {
        get { (try? JSONDecoder().decode([CardOutcome].self, from: outcomesData)) ?? [] }
        set { outcomesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

extension QuizRecord {
    var sourceText: String? {
        get { sourceTextData.map { String(decoding: $0, as: UTF8.self) } }
        set { sourceTextData = newValue.map { Data($0.utf8) } }
    }

    var sourceURL: URL? {
        sourceURLString.flatMap(URL.init(string:))
    }

    var sourceKind: QuizSourceKind? {
        sourceKindRaw.flatMap(QuizSourceKind.init(rawValue:))
    }

    /// Builds a quiz and its cards from a payload. The caller inserts and saves it.
    static func make(
        from payload: QuizPayload,
        sourceBookmark: Data? = nil,
        bundledSampleId: String? = nil,
        source: OriginalSource? = nil
    ) -> QuizRecord {
        let record = QuizRecord(name: payload.name, sourceBookmark: source?.fileBookmark ?? sourceBookmark, bundledSampleId: bundledSampleId)
        if let source {
            record.sourceKindRaw = source.kind.rawValue
            record.sourceTitle = source.title
            record.sourceText = source.text
            record.sourceURLString = source.url?.absoluteString
        }
        for (idx, card) in payload.cards.enumerated() {
            let cr = CardRecord(
                prompt: card.prompt,
                longAnswer: card.longAnswer,
                shortAnswer: card.shortAnswer,
                hint: card.hint,
                orderIndex: idx
            )
            cr.quiz = record
            record.cards.append(cr)
        }
        return record
    }

    /// The quiz as a payload for export.
    var payload: QuizPayload {
        QuizPayload(
            name: name,
            cards: cards.sorted { $0.orderIndex < $1.orderIndex }.map {
                CardPayload(prompt: $0.prompt, longAnswer: $0.longAnswer, shortAnswer: $0.shortAnswer, hint: $0.hint)
            }
        )
    }

    var bestScore: Double? {
        sessions.filter { !$0.abandoned }.compactMap(\.scorePercent).max()
    }

    var averageScore: Double? {
        let valid = sessions.filter { !$0.abandoned }.compactMap(\.scorePercent)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    var sessionCount: Int {
        sessions.filter { !$0.abandoned }.count
    }
}

/// Where a generated quiz's content came from (CR-007).
enum QuizSourceKind: String, Codable, Sendable {
    case webPage
    case markdownFile
    case pastedText
}

/// The original content to keep with a generated quiz.
struct OriginalSource: Sendable, Equatable {
    var kind: QuizSourceKind
    var title: String
    /// Copy of the text at generation time; the fallback when the original can't be reached.
    var text: String?
    /// The web page, for `.webPage`.
    var url: URL?
    /// Security-scoped bookmark to the file in Files, for `.markdownFile`.
    var fileBookmark: Data?
}
