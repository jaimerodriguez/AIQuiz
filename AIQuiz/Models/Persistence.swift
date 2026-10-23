import Foundation
import SwiftData
import AIQuizCore

// The app works with the current schema's types (DECISIONS ADR-014).
typealias QuizRecord = SchemaV2.QuizRecord
typealias CardRecord = SchemaV2.CardRecord
typealias SessionRecord = SchemaV2.SessionRecord

extension CardRecord {
    var cardKind: CardKind {
        get { CardKind(rawValue: kind) ?? .recall }
        set { kind = newValue.rawValue }
    }

    /// Stored AI hints, weakest first (F-24).
    var aiHints: [String] {
        get { aiHintsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { aiHintsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var options: [String]? {
        get { optionsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } }
        set { optionsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// History in the shape the ordering algorithm consumes.
    var history: SmartOrdering.History {
        .init(correct: correctCount, partial: partialCount, wrong: wrongCount, lastSeenAt: lastSeenAt)
    }

    var payload: CardPayload {
        CardPayload(prompt: prompt, longAnswer: longAnswer, shortAnswer: shortAnswer, hint: hint,
                    kind: cardKind, options: options, explanation: explanation, mnemonic: mnemonic)
    }

    /// Writes edited content back; history and scheduling are untouched.
    func apply(_ content: CardPayload) {
        prompt = content.prompt
        longAnswer = content.longAnswer
        shortAnswer = content.shortAnswer
        hint = content.hint
        cardKind = content.kind
        options = content.kind == .multipleChoice ? content.options : nil
        explanation = content.explanation
        mnemonic = content.mnemonic
    }

    convenience init(_ content: CardPayload, orderIndex: Int) {
        self.init(prompt: content.prompt, longAnswer: content.longAnswer, shortAnswer: content.shortAnswer,
                  hint: content.hint, orderIndex: orderIndex)
        apply(content)
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
            hint: record.hint,
            aiHints: record.aiHints,
            kind: record.cardKind,
            options: record.options ?? [],
            explanation: record.explanation
        )
    }
}

extension SessionRecord {
    convenience init(
        mode: SessionMode,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        scorePercent: Double? = nil,
        abandoned: Bool = false,
        outcomes: [CardOutcome] = []
    ) {
        self.init(
            mode: mode.rawValue,
            startedAt: startedAt,
            endedAt: endedAt,
            scorePercent: scorePercent,
            abandoned: abandoned,
            outcomesData: (try? JSONEncoder().encode(outcomes)) ?? Data()
        )
    }

    var sessionMode: SessionMode { SessionMode(rawValue: mode) ?? .studyRead }

    var outcomes: [CardOutcome] {
        get { (try? JSONDecoder().decode([CardOutcome].self, from: outcomesData)) ?? [] }
        set { outcomesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

extension QuizRecord {
    var origin: QuizOrigin {
        get { QuizOrigin(rawValue: originRaw) ?? .unknown }
        set { originRaw = newValue.rawValue }
    }

    var sourceText: String? {
        get { sourceTextData.map { String(decoding: $0, as: UTF8.self) } }
        set { sourceTextData = newValue.map { Data($0.utf8) } }
    }

    var summaryMarkdown: String? {
        get { summaryMarkdownData.map { String(decoding: $0, as: UTF8.self) } }
        set { summaryMarkdownData = newValue.map { Data($0.utf8) } }
    }

    var sourceURL: URL? {
        sourceURLString.flatMap(URL.init(string:))
    }

    var sourceKind: QuizSourceKind? {
        sourceKindRaw.flatMap(QuizSourceKind.init(rawValue:))
    }

    /// Renames the quiz and keeps the search text in step.
    func rename(to newName: String) {
        name = newName
        tagsSearch = TagsSearch.make(name: name, tags: tags)
    }

    /// Replaces the tags (normalised, de-duplicated) and keeps the search text in step.
    func setTags(_ newTags: [String]) {
        tags = TagsSearch.clean(newTags)
        tagsSearch = TagsSearch.make(name: name, tags: tags)
    }

    /// Builds a quiz and its cards from a payload. The caller inserts and saves it.
    static func make(
        from payload: QuizPayload,
        origin: QuizOrigin,
        sourceBookmark: Data? = nil,
        bundledSampleId: String? = nil,
        source: OriginalSource? = nil
    ) -> QuizRecord {
        let record = QuizRecord(name: payload.name, origin: origin, sourceBookmark: source?.fileBookmark ?? sourceBookmark, bundledSampleId: bundledSampleId)
        record.descriptionText = payload.description
        record.language = payload.language
        record.setTags(payload.tags)
        if let source {
            record.sourceKindRaw = source.kind.rawValue
            record.sourceTitle = source.title
            record.sourceText = source.text
            record.sourceURLString = source.url?.absoluteString
        }
        for (idx, card) in payload.cards.enumerated() {
            let cr = CardRecord(card, orderIndex: idx)
            cr.quiz = record
            record.cards.append(cr)
        }
        QuizStats.refresh(record)
        return record
    }

    /// Inserts new cards right after `card` (F-27 Expand), shifting later cards down.
    func insertCards(_ payloads: [CardPayload], after card: CardRecord) {
        let position = card.orderIndex
        for existing in cards where existing.orderIndex > position {
            existing.orderIndex += payloads.count
        }
        for (offset, payload) in payloads.enumerated() {
            let new = CardRecord(payload, orderIndex: position + 1 + offset)
            new.quiz = self
            cards.append(new)
        }
        QuizStats.refresh(self)
    }

    var sortedCards: [CardRecord] {
        cards.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// The quiz as a payload for export (SPEC §2).
    var payload: QuizPayload {
        QuizPayload(
            name: name,
            description: descriptionText,
            tags: tags,
            language: language,
            cards: sortedCards.map(\.payload)
        )
    }
}

/// Keeps the stored counters on `QuizRecord` current (SPEC D-11). Call after any write
/// that changes a quiz's cards, sessions or scheduling.
enum QuizStats {
    static func refresh(_ quiz: QuizRecord, now: Date = .now) {
        let counters = QuizCounters.compute(
            cardDueDates: quiz.cards.map(\.dueAt),
            sessions: quiz.sessions.map {
                .init(abandoned: $0.abandoned, scorePercent: $0.scorePercent, startedAt: $0.startedAt, endedAt: $0.endedAt)
            },
            now: now
        )
        quiz.cardCount = counters.cardCount
        quiz.sessionCount = counters.sessionCount
        quiz.bestScore = counters.bestScore
        quiz.averageScore = counters.averageScore
        quiz.dueCount = counters.dueCount
        if let last = counters.lastStudiedAt, last > (quiz.lastStudiedAt ?? .distantPast) {
            quiz.lastStudiedAt = last
        }
        quiz.countersUpdatedAt = now
    }

    /// Refreshes quizzes whose counters predate the last midnight, because `dueCount`
    /// drifts as time passes. Run on launch and when the app returns to the foreground.
    static func refreshStale(in context: ModelContext, now: Date = .now) {
        let midnight = Calendar.current.startOfDay(for: now)
        let stale = FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.countersUpdatedAt < midnight })
        guard let quizzes = try? context.fetch(stale), !quizzes.isEmpty else { return }
        for quiz in quizzes { refresh(quiz, now: now) }
        do {
            try context.save()
        } catch {
            Log.data.error("refreshStale save failed: \(String(describing: error))")
        }
        Log.data.info("Refreshed counters for \(quizzes.count) quizzes")
    }
}

/// Where a generated quiz's content came from (CR-007).
enum QuizSourceKind: String, Codable, Sendable {
    case webPage
    case markdownFile
    case pastedText
    /// A PDF in Files (Phase 5), linked by bookmark with its text saved.
    case pdfFile
    /// Photos or scanned pages; only the recognised text is kept.
    case scannedPages
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
