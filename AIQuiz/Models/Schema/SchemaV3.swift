import Foundation
import SwiftData
import AIQuizCore

/// The current store (SPEC §3, F-63): v2 plus folders. The app uses these types through the
/// `QuizRecord`, `CardRecord`, `SessionRecord` and `FolderRecord` aliases. The only changes
/// from v2 are the `FolderRecord` entity and the optional `QuizRecord.folderID`, so the
/// migration is lightweight (ADR-022). Frozen once shipped (ADR-014).
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [QuizRecord.self, CardRecord.self, SessionRecord.self, FolderRecord.self] }

    @Model
    final class QuizRecord {
        #Index<QuizRecord>([\.lastStudiedAt], [\.createdAt], [\.isArchived], [\.folderID])

        @Attribute(.unique) var id: UUID
        var name: String
        var descriptionText: String?
        var tags: [String] = []
        /// ` name #tag1 #tag2 `, lowercased, for `contains` search (`TagsSearch`).
        var tagsSearch: String = ""
        var language: String?
        var createdAt: Date = Date.distantPast
        var importedAt: Date
        var lastStudiedAt: Date?
        var isArchived: Bool = false
        /// The folder the quiz lives in (F-63); nil is the top level. A plain id, not a
        /// relationship, so library queries filter on it cleanly (ADR-022).
        var folderID: UUID?
        /// `QuizOrigin` raw value: how the quiz came into the library.
        var originRaw: String = QuizOrigin.unknown.rawValue
        var sourceBookmark: Data?
        var bundledSampleId: String?
        var generatedByEndpointName: String?
        var generatedByModel: String?

        // Original content (CR-007).
        var sourceKindRaw: String?
        var sourceTitle: String?
        @Attribute(.externalStorage) var sourceTextData: Data?
        var sourceURLString: String?

        /// AI study notes (F-20, on hold). External so library fetches don't load it.
        @Attribute(.externalStorage) var summaryMarkdownData: Data?
        /// Unused since CR-007; kept until the owner agrees to drop it (holds notes on the iPad).
        var studyNotes: String?

        // Stored counters (SPEC D-11); written only by `QuizStats.refresh`.
        var cardCount: Int = 0
        var sessionCount: Int = 0
        var bestScore: Double?
        var averageScore: Double?
        var dueCount: Int = 0
        var countersUpdatedAt: Date = Date.distantPast

        @Relationship(deleteRule: .cascade, inverse: \CardRecord.quiz)
        var cards: [CardRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \SessionRecord.quiz)
        var sessions: [SessionRecord] = []

        init(
            id: UUID = UUID(),
            name: String,
            importedAt: Date = .now,
            origin: QuizOrigin = .unknown,
            sourceBookmark: Data? = nil,
            bundledSampleId: String? = nil
        ) {
            self.id = id
            self.name = name
            self.importedAt = importedAt
            self.createdAt = importedAt
            self.originRaw = origin.rawValue
            self.sourceBookmark = sourceBookmark
            self.bundledSampleId = bundledSampleId
            self.tagsSearch = TagsSearch.make(name: name, tags: [])
        }
    }

    @Model
    final class CardRecord {
        #Index<CardRecord>([\.dueAt])

        @Attribute(.unique) var id: UUID
        var prompt: String
        var longAnswer: String
        var shortAnswer: String?
        var hint: String?
        /// `CardKind` raw value.
        var kind: String = "recall"
        /// JSON `[String]`, multiple-choice options.
        var optionsData: Data?
        var explanation: String?
        var mnemonic: String?
        /// JSON `[String]`, progressive AI hints (F-24).
        var aiHintsData: Data?
        var orderIndex: Int
        /// 1–5 (F-26).
        var aiDifficulty: Int?

        var correctCount: Int
        var partialCount: Int
        var wrongCount: Int
        var lastSeenAt: Date?

        // Scheduling (FSRS, F-40). 0 stability means new.
        var stability: Double = 0
        var difficulty: Double = 0
        var dueAt: Date?
        var reps: Int = 0
        var lapses: Int = 0
        var lastRating: Int?
        var lastReviewedAt: Date?

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
    }

    @Model
    final class SessionRecord {
        #Index<SessionRecord>([\.startedAt])

        @Attribute(.unique) var id: UUID
        var mode: String
        var startedAt: Date
        var endedAt: Date?
        var durationSeconds: Double = 0
        var scorePercent: Double?
        var abandoned: Bool
        var outcomesData: Data
        var endpointName: String?
        /// AI recap (F-44).
        var recapText: String?

        var quiz: QuizRecord?

        init(
            id: UUID = UUID(),
            mode: String,
            startedAt: Date = .now,
            endedAt: Date? = nil,
            scorePercent: Double? = nil,
            abandoned: Bool = false,
            outcomesData: Data = Data()
        ) {
            self.id = id
            self.mode = mode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.durationSeconds = endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } ?? 0
            self.scorePercent = scorePercent
            self.abandoned = abandoned
            self.outcomesData = outcomesData
        }
    }

    /// A folder in the library (F-63). Folders nest through `parentID`; nil is the top level.
    @Model
    final class FolderRecord {
        #Index<FolderRecord>([\.parentID])

        @Attribute(.unique) var id: UUID
        var name: String
        var parentID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), name: String, parentID: UUID? = nil, createdAt: Date = .now) {
            self.id = id
            self.name = name
            self.parentID = parentID
            self.createdAt = createdAt
        }
    }
}
