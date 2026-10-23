import Foundation
import AIQuizCore
import SwiftData

/// The three bundled sample quizzes (SPEC F-6), seeded on first launch only, so a sample
/// the user deletes, or a library they clear (S-15), stays that way.
enum SampleQuizzes {
    static let bundledIds: [String] = [
        "roman-emperors",
        "spanish-verbs",
        "systems-design"
    ]

    static let seededKey = "samplesSeeded"

    @MainActor
    static func seedOnFirstLaunch(in context: ModelContext, defaults: UserDefaults) {
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        // Libraries from before this flag existed already had their samples seeded.
        if ((try? context.fetchCount(FetchDescriptor<QuizRecord>())) ?? 0) > 0 { return }
        seedMissing(in: context)
    }

    /// Inserts any bundled sample not already in the library.
    @MainActor
    static func seedMissing(in context: ModelContext) {
        for id in bundledIds {
            let descriptor = FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.bundledSampleId == id })
            guard ((try? context.fetchCount(descriptor)) ?? 0) == 0, let quiz = try? loadBundled(id: id) else { continue }
            context.insert(QuizRecord.make(from: quiz, origin: .bundled, bundledSampleId: id))
        }
        try? context.save()
    }

    private static func loadBundled(id: String) throws -> QuizPayload {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "SampleQuizzes")
                ?? Bundle.main.url(forResource: id, withExtension: "json")
        else {
            throw NSError(domain: "SampleQuizzes", code: 404, userInfo: [NSLocalizedDescriptionKey: "Sample \(id).json not found in bundle"])
        }
        return try QuizDecoder.decode(Data(contentsOf: url))
    }
}
