import Foundation
import SwiftData
import AIQuizCore

/// Deterministic library contents for UI-test mode (PLAN §1.5).
enum UITestFixtures {
    static let deckName = "UITest Deck"

    @MainActor
    static func seed(scenario: AppEnvironment.Scenario, in context: ModelContext) async {
        guard scenario != .emptyLibrary else { return }
        await SampleQuizzes.seedIfNeeded(in: context)

        let name = deckName
        let descriptor = FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        let record = QuizRecord(name: name)
        let cards: [(String, String, String?, String?)] = [
            ("Fixture prompt one", "Fixture long answer one.", "Short one", "Hint one"),
            ("Fixture prompt two", "Fixture long answer two.", "Short two", nil),
            ("Fixture prompt three", "Fixture long answer three.", nil, "Hint three"),
            ("Fixture prompt four", "Fixture long answer four.", "Short four", "Hint four"),
            ("Fixture prompt five", "Fixture long answer five.", "Short five", nil),
            ("Fixture prompt six", "Fixture long answer six.", nil, nil)
        ]
        for (idx, c) in cards.enumerated() {
            let cr = CardRecord(prompt: c.0, longAnswer: c.1, shortAnswer: c.2, hint: c.3, orderIndex: idx)
            cr.quiz = record
            record.cards.append(cr)
        }
        context.insert(record)
        try? context.save()
    }
}
