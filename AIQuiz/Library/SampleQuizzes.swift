import Foundation
import SwiftData

enum SampleQuizzes {
    static let bundledIds: [String] = [
        "roman-emperors",
        "spanish-verbs",
        "systems-design"
    ]

    @MainActor
    static func seedIfNeeded(in context: ModelContext) async {
        for id in bundledIds {
            let descriptor = FetchDescriptor<QuizRecord>(
                predicate: #Predicate { $0.bundledSampleId == id }
            )
            let existing = (try? context.fetch(descriptor)) ?? []
            if existing.isEmpty {
                if let quiz = try? loadBundled(id: id) {
                    insert(quiz: quiz, bundledId: id, into: context)
                }
            }
        }
        try? context.save()
    }

    private static func loadBundled(id: String) throws -> QuizPayload {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "SampleQuizzes")
                ?? Bundle.main.url(forResource: id, withExtension: "json")
        else {
            throw NSError(domain: "SampleQuizzes", code: 404, userInfo: [NSLocalizedDescriptionKey: "Sample \(id).json not found in bundle"])
        }
        let data = try Data(contentsOf: url)
        return try QuizDecoder.decode(data)
    }

    @MainActor
    private static func insert(quiz: QuizPayload, bundledId: String?, into context: ModelContext) {
        let record = QuizRecord(name: quiz.name, bundledSampleId: bundledId)
        for (idx, card) in quiz.cards.enumerated() {
            let cardRecord = CardRecord(
                prompt: card.prompt,
                longAnswer: card.longAnswer,
                shortAnswer: card.shortAnswer,
                hint: card.hint,
                orderIndex: idx
            )
            cardRecord.quiz = record
            record.cards.append(cardRecord)
        }
        context.insert(record)
    }
}
