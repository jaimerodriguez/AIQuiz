import Foundation

/// Input to quiz generation (SPEC F-19). Provider-independent.
public struct QuizGenRequest: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case topic
        case markdown
        case article
    }

    public var source: Source
    public var topic: String
    public var sourceContent: String?
    public var cardCount: Int?
    public var difficulty: String?
    public var language: String?
    public var tone: String?
    public var focus: String?
    public var exclude: String?
    /// Study notes written first (CR-006). When present, cards are drawn from them.
    public var studyNotes: String?

    public init(
        source: Source,
        topic: String,
        sourceContent: String? = nil,
        cardCount: Int? = nil,
        difficulty: String? = nil,
        language: String? = nil,
        tone: String? = nil,
        focus: String? = nil,
        exclude: String? = nil,
        studyNotes: String? = nil
    ) {
        self.source = source
        self.topic = topic
        self.sourceContent = sourceContent
        self.cardCount = cardCount
        self.difficulty = difficulty
        self.language = language
        self.tone = tone
        self.focus = focus
        self.exclude = exclude
        self.studyNotes = studyNotes
    }
}

/// Input to answer judging (SPEC F-15).
public struct JudgeRequest: Sendable, Hashable {
    public var prompt: String
    public var userAnswer: String
    public var correctShort: String?
    public var correctLong: String

    public init(prompt: String, userAnswer: String, correctShort: String? = nil, correctLong: String) {
        self.prompt = prompt
        self.userAnswer = userAnswer
        self.correctShort = correctShort
        self.correctLong = correctLong
    }
}

/// Output of answer judging.
public struct JudgeVerdict: Sendable, Hashable {
    public var verdict: CardVerdict
    public var reason: String

    public init(verdict: CardVerdict, reason: String) {
        self.verdict = verdict
        self.reason = reason
    }
}

/// Wire shape of the judge response: `{"verdict":"correct|partial|wrong","reason":"..."}`.
public struct JudgeJSON: Decodable, Sendable, Equatable {
    public let verdict: String
    public let reason: String

    public init(verdict: String, reason: String) {
        self.verdict = verdict
        self.reason = reason
    }

    public func toVerdict() -> JudgeVerdict {
        let v: CardVerdict
        switch verdict.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "correct": v = .correct
        case "partial": v = .partial
        default: v = .wrong
        }
        return JudgeVerdict(verdict: v, reason: reason)
    }
}
