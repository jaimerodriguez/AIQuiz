import Foundation
import SwiftData

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
}

enum SessionMode: String, Codable {
    case studyVoice
    case studyRead
    case quizVoice
}

enum CardVerdict: String, Codable {
    case correct
    case partial
    case wrong
    case skipped

    var score: Double? {
        switch self {
        case .correct: return 1.0
        case .partial: return 0.5
        case .wrong: return 0.0
        case .skipped: return nil
        }
    }
}

struct CardOutcome: Codable, Hashable {
    var cardId: UUID
    var verdict: CardVerdict
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
    var bestScore: Double? {
        let valid = sessions.filter { !$0.abandoned && $0.scorePercent != nil }
        return valid.map { $0.scorePercent! }.max()
    }

    var averageScore: Double? {
        let valid = sessions.filter { !$0.abandoned && $0.scorePercent != nil }
        guard !valid.isEmpty else { return nil }
        return valid.map { $0.scorePercent! }.reduce(0, +) / Double(valid.count)
    }

    var sessionCount: Int {
        sessions.filter { !$0.abandoned }.count
    }
}
