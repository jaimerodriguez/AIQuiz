import Foundation
import SwiftData

/// The store as v0.1 (`main` at 2e94e8f) wrote it, before schemas were versioned.
/// A frozen copy: never edit. The migration plan needs it to recognise libraries that
/// have not opened a newer build, such as one on a phone (SPEC D-10, DECISIONS ADR-014).
enum SchemaV0: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [QuizRecord.self, CardRecord.self, SessionRecord.self] }

    @Model
    final class QuizRecord {
        @Attribute(.unique) var id: UUID
        var name: String
        var importedAt: Date
        var sourceBookmark: Data?
        var bundledSampleId: String?

        @Relationship(deleteRule: .cascade, inverse: \CardRecord.quiz)
        var cards: [CardRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \SessionRecord.quiz)
        var sessions: [SessionRecord] = []

        init(id: UUID = UUID(), name: String, importedAt: Date = .now, sourceBookmark: Data? = nil, bundledSampleId: String? = nil) {
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

        init(id: UUID = UUID(), prompt: String, longAnswer: String, shortAnswer: String? = nil, hint: String? = nil, orderIndex: Int) {
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

        init(id: UUID = UUID(), mode: String, startedAt: Date = .now, endedAt: Date? = nil, scorePercent: Double? = nil, abandoned: Bool = false, outcomesData: Data = Data()) {
            self.id = id
            self.mode = mode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.scorePercent = scorePercent
            self.abandoned = abandoned
            self.outcomesData = outcomesData
        }
    }
}
