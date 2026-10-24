import Foundation

/// What importing an Anki package produces (docs/anki-interchange.md §2): one quiz per deck
/// that has cards, each card with its schedule and answer counts carried over.
public struct AnkiImportResult: Sendable {
    public struct Card: Sendable, Equatable {
        public var payload: CardPayload
        public var schedule: FSRS.State
        public var correct: Int
        public var partial: Int
        public var wrong: Int
    }

    public struct Quiz: Sendable, Equatable {
        /// The deck path joined with " › ", e.g. "Spanish › Verbs".
        public var name: String
        public var cards: [Card]
    }

    public var format: AnkiPackage.Format
    public var quizzes: [Quiz]
    /// Images and sounds in imported notes; AIQuiz cards are text only.
    public var skippedImages = 0
    public var skippedSounds = 0
    /// Cards that render to nothing usable (an image-only card, an empty side, Image Occlusion).
    public var skippedCards = 0

    public var cardCount: Int { quizzes.reduce(0) { $0 + $1.cards.count } }
}

public enum AnkiImporter {
    public static let separator = " › "

    /// Reads an `.apkg` or `.colpkg` file.
    public static func importPackage(at url: URL, now: Date = .now) throws -> AnkiImportResult {
        let (collection, format) = try AnkiPackage.read(url: url)
        return convert(collection, format: format, now: now)
    }

    public static func convert(_ collection: AnkiCollection, format: AnkiPackage.Format, now: Date = .now) -> AnkiImportResult {
        let notetypes = Dictionary(collection.notetypes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let notes = Dictionary(collection.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decks = Dictionary(collection.decks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reviews = Dictionary(grouping: collection.reviews, by: \.cardId)

        var result = AnkiImportResult(format: format, quizzes: [])
        var order: [Int64] = []
        var byDeck: [Int64: [AnkiImportResult.Card]] = [:]
        var counted = Set<Int64>()

        for card in collection.cards {
            guard let note = notes[card.noteId], let notetype = notetypes[note.notetypeId] else { continue }
            if counted.insert(note.id).inserted {
                for field in note.fields {
                    let media = HTMLText.media(field)
                    result.skippedImages += media.images
                    result.skippedSounds += media.sounds
                }
            }
            let deck = decks[card.deckId]?.path ?? ["Default"]
            guard var payload = payload(for: card, note: note, notetype: notetype, deck: deck),
                  CardValidator.problem(with: payload) == nil else {
                result.skippedCards += 1
                continue
            }
            payload.prompt = String(payload.prompt.prefix(4_000))
            let history = reviews[card.id] ?? []
            let imported = AnkiImportResult.Card(
                payload: payload,
                schedule: schedule(for: card, reviews: history, createdAt: collection.createdAt, now: now),
                correct: history.filter { $0.ease == 3 || $0.ease == 4 }.count,
                partial: history.filter { $0.ease == 2 }.count,
                wrong: history.filter { $0.ease == 1 }.count
            )
            if byDeck[card.deckId] == nil { order.append(card.deckId) }
            byDeck[card.deckId, default: []].append(imported)
        }
        let paths = quizPaths(order.map { decks[$0]?.path ?? ["Default"] })
        result.quizzes = zip(order, paths).map { id, path in
            AnkiImportResult.Quiz(name: path.joined(separator: separator), cards: byDeck[id] ?? [])
        }
        return result
    }

    /// Quiz names for the imported decks (anki-interchange §2.1): with several decks, the
    /// levels they all share are dropped except the closest one, which stays for context
    /// ("A › B › C › 1" and "A › B › C › 2" become "C › 1" and "C › 2"). One deck keeps its
    /// whole path, and no name is ever shortened to nothing.
    static func quizPaths(_ paths: [[String]]) -> [[String]] {
        guard paths.count > 1, let shortest = paths.map(\.count).min() else { return paths }
        var shared = 0
        while shared < shortest - 1, Set(paths.map { $0[shared] }).count == 1 { shared += 1 }
        let drop = max(0, shared - 1)
        return paths.map { Array($0.dropFirst(drop)) }
    }

    // MARK: Content

    /// The AIQuiz card for one Anki card, or nil when a side renders empty.
    static func payload(for card: AnkiCollection.Card, note: AnkiCollection.Note, notetype: AnkiCollection.Notetype, deck: [String]) -> CardPayload? {
        let values = Dictionary(zip(notetype.fields, note.fields + Array(repeating: "", count: max(0, notetype.fields.count - note.fields.count))),
                                uniquingKeysWith: { a, _ in a })
        if let roundTrip = AnkiExporter.aiQuizPayload(notetype: notetype, values: values) {
            return roundTrip
        }
        // Image Occlusion cards are a picture with boxes over it: nothing to show as text.
        if notetype.name == "Image Occlusion" || notetype.templates.contains(where: { $0.question.contains("cloze:Occlusion") }) {
            return nil
        }
        let template = notetype.isCloze ? notetype.templates.first : notetype.templates.first { $0.ord == card.ord }
        guard let template else { return nil }
        var context = AnkiTemplate.Context(fields: values, side: .question, tags: note.tags, deck: deck, cardName: template.name, notetypeName: notetype.name)
        if notetype.isCloze { context.cloze = .init(number: card.ord + 1) }

        let questionHTML = AnkiTemplate.render(template.question, context)
        context.side = .answer
        context.frontSide = questionHTML
        var answerHTML = AnkiTemplate.render(template.answer, context)
        if let range = answerHTML.range(of: #"(?i)<hr[^>]*id\s*=\s*"?answer"?[^>]*>"#, options: .regularExpression) {
            answerHTML = String(answerHTML[range.upperBound...])
        } else if template.answer.contains("{{FrontSide}}") {
            context.frontSide = ""
            answerHTML = AnkiTemplate.render(template.answer, context)
        }
        // What Anki shows: the note type's CSS may hide elements too.
        let hidden = HTMLText.hiddenSelectors(css: notetype.css)
        let prompt = HTMLText.plain(questionHTML, hiding: hidden)
        let longAnswer = HTMLText.plain(answerHTML, hiding: hidden)
        guard !prompt.isEmpty, !longAnswer.isEmpty else { return nil }

        if notetype.isCloze {
            // The answers and hint of this card's deletion, from the fields its template uses.
            let clozeFields = notetype.fields.filter { template.question.contains("cloze:\($0)") }
            var answers: [String] = []
            var hints: [String] = []
            for name in clozeFields {
                let parts = Cloze.anki(values[name] ?? "", number: card.ord + 1, side: .question)
                answers += parts.answers.map { HTMLText.plain($0) }
                hints += parts.hints.map { HTMLText.plain($0) }
            }
            guard prompt.contains(Cloze.marker), !answers.isEmpty else { return nil }
            return CardPayload(prompt: prompt, longAnswer: longAnswer, shortAnswer: answers.joined(separator: "|"),
                               hint: hints.first { !$0.isEmpty }, kind: .cloze)
        }
        return CardPayload(prompt: prompt, longAnswer: longAnswer)
    }

    // MARK: Schedule

    /// The card's FSRS state from Anki's (§2.3): due date as Anki has it; stability and
    /// difficulty from Anki's FSRS memory when present, otherwise from the interval and ease.
    static func schedule(for card: AnkiCollection.Card, reviews: [AnkiCollection.Review], createdAt: Int64, now: Date) -> FSRS.State {
        guard card.type != 0 else { return FSRS.State() }
        let data = (try? JSONSerialization.jsonObject(with: Data(card.data.utf8))) as? [String: Any] ?? [:]
        let graded = reviews.filter { (1...4).contains($0.ease) }

        let dueAt: Date
        if card.due > 1_000_000_000 {
            // Learning cards due today count in seconds since 1970.
            dueAt = Date(timeIntervalSince1970: TimeInterval(card.due))
        } else {
            dueAt = Date(timeIntervalSince1970: TimeInterval(createdAt + card.due * 86_400))
        }
        let lastReview: Date
        if let lrt = data["lrt"] as? NSNumber, lrt.int64Value > 0 {
            lastReview = Date(timeIntervalSince1970: lrt.doubleValue)
        } else if let latest = graded.last {
            lastReview = Date(timeIntervalSince1970: TimeInterval(latest.id) / 1_000)
        } else {
            lastReview = min(now, dueAt.addingTimeInterval(-Double(max(card.interval, 1)) * 86_400))
        }
        let lastRating = graded.last.map(\.ease) ?? 3
        let stability = (data["s"] as? NSNumber)?.doubleValue
            ?? (card.interval > 0 ? Double(card.interval) : FSRS.initialStability(FSRS.Rating(rawValue: lastRating) ?? .good))
        let difficulty = (data["d"] as? NSNumber)?.doubleValue ?? difficulty(fromEase: card.factor)
        return FSRS.State(stability: max(0.1, stability), difficulty: difficulty, dueAt: dueAt,
                          reps: card.reps, lapses: card.lapses, lastRating: lastRating, lastReviewedAt: lastReview)
    }

    /// Anki's ease (2500 is the default, 1300 the floor) on FSRS's 1–10 difficulty scale:
    /// default ease is middling difficulty, lower ease harder.
    static func difficulty(fromEase factor: Int) -> Double {
        guard factor > 0 else { return 5 }
        return min(10, max(1, 5 + Double(2_500 - factor) / 240))
    }
}
