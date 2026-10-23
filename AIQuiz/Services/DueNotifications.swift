import Foundation
import SwiftData
import UserNotifications
import AIQuizCore

/// Opens the Due today review, from the library row or a tapped reminder (F-42).
@MainActor
@Observable
final class ReviewRouter: NSObject, UNUserNotificationCenterDelegate {
    var showReview = false

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == DueNotifications.identifier else { return }
        await MainActor.run { showReview = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// The daily due reminder (SPEC F-42, S-12). Rescheduled on launch, when the app goes to
/// the background (after a session) and when the setting changes. The text counts the cards
/// that will be due at the reminder time; nothing due means no reminder.
@MainActor
enum DueNotifications {
    nonisolated static let identifier = "due-reminder"

    static func reschedule(settings: AppSettings, context: ModelContext, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard settings.reminderOn, !AppEnvironment.current.isUITest else { return }
        let fire = DueReminder.nextFireDate(hour: settings.reminderMinutes / 60, minute: settings.reminderMinutes % 60, after: now)
        let (cards, quizzes) = dueSummary(at: fire, in: context)
        guard let body = DueReminder.message(cards: cards, quizzes: quizzes) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to review"
        content.body = body
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// Cards due by `date` and how many quizzes they're in.
    static func dueSummary(at date: Date, in context: ModelContext) -> (cards: Int, quizzes: Int) {
        let never = Date.distantPast
        let due = (try? context.fetch(FetchDescriptor<CardRecord>(predicate: #Predicate { card in
            (card.dueAt ?? never) <= date && card.quiz?.isArchived == false
        }))) ?? []
        return (due.count, Set(due.compactMap { $0.quiz?.id }).count)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
