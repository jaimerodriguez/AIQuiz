import Foundation

/// The daily due reminder (SPEC F-42, S-12).
public enum DueReminder {
    /// The next time the reminder should fire: today at `hour:minute` if that's still ahead,
    /// otherwise tomorrow.
    public static func nextFireDate(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        let today = calendar.date(from: parts) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    /// "12 cards due in 3 quizzes"; nil when nothing is due, so no reminder is sent.
    public static func message(cards: Int, quizzes: Int) -> String? {
        guard cards > 0 else { return nil }
        let cardText = cards == 1 ? "1 card" : "\(cards) cards"
        let quizText = quizzes == 1 ? "1 quiz" : "\(quizzes) quizzes"
        return "\(cardText) due in \(quizText)"
    }
}
