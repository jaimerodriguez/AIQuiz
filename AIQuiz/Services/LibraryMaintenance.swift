import Foundation
import SwiftData

/// The privacy clears in Settings (SPEC S-15). Each one is confirmed in the UI first.
@MainActor
enum LibraryMaintenance {
    /// Deletes every session and resets per-card history; quizzes and cards stay.
    static func clearSessionHistory(in context: ModelContext) throws {
        // One by one: a batch delete can't nullify the quiz → sessions relationship.
        for quiz in try context.fetch(FetchDescriptor<QuizRecord>()) {
            quiz.sessions.removeAll()
        }
        for session in try context.fetch(FetchDescriptor<SessionRecord>()) {
            context.delete(session)
        }
        for card in try context.fetch(FetchDescriptor<CardRecord>()) {
            card.correctCount = 0
            card.partialCount = 0
            card.wrongCount = 0
            card.lastSeenAt = nil
        }
        for quiz in try context.fetch(FetchDescriptor<QuizRecord>()) {
            quiz.lastStudiedAt = nil
            QuizStats.refresh(quiz)
        }
        try context.save()
        Log.data.info("Cleared session history")
    }

    /// Deletes every quiz with its cards and sessions.
    static func clearLibrary(in context: ModelContext) throws {
        for quiz in try context.fetch(FetchDescriptor<QuizRecord>()) {
            context.delete(quiz)
        }
        try context.save()
        Log.data.info("Cleared the quiz library")
    }
}
