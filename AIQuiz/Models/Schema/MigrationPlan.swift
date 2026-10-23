import Foundation
import SwiftData
import AIQuizCore

/// v0.1 → v1.1 (original-content fields) → v2 (SPEC §3, D-10). Each database change is
/// lightweight; the v2 stage then fills values that depend on other fields.
enum AIQuizMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV0.self, SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [v0ToV1, v1ToV2] }

    static let v0ToV1 = MigrationStage.lightweight(fromVersion: SchemaV0.self, toVersion: SchemaV1.self)

    static let v1ToV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            try fillV2Defaults(in: context)
        }
    )

    /// Derived values for records that came from v1 or v0. Safe to run more than once.
    static func fillV2Defaults(in context: ModelContext, now: Date = .now) throws {
        let quizzes = try context.fetch(FetchDescriptor<SchemaV2.QuizRecord>())
        for quiz in quizzes {
            quiz.createdAt = quiz.importedAt
            quiz.originRaw = origin(of: quiz).rawValue
            quiz.tagsSearch = TagsSearch.make(name: quiz.name, tags: quiz.tags)
            for session in quiz.sessions {
                if let ended = session.endedAt {
                    session.durationSeconds = max(0, ended.timeIntervalSince(session.startedAt))
                }
            }
            QuizStats.refresh(quiz, now: now)
        }
        try context.save()
    }

    /// The origin a v1 quiz implies: bundled samples have an id, generated quizzes since
    /// CR-007 have a source kind, and a bookmark without one means a JSON import.
    static func origin(of quiz: SchemaV2.QuizRecord) -> QuizOrigin {
        if quiz.bundledSampleId != nil { return .bundled }
        switch quiz.sourceKindRaw.flatMap(QuizSourceKind.init(rawValue:)) {
        case .webPage?: return .url
        case .markdownFile?: return .markdown
        case .pastedText?: return .pastedText
        case .pdfFile?: return .pdf
        case .scannedPages?: return .image
        case nil: return quiz.sourceBookmark != nil ? .imported : .unknown
        }
    }
}
