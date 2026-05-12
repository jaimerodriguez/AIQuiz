import SwiftUI
import SwiftData

@main
struct AIQuizApp: App {
    let container: ModelContainer
    @State private var settings = AppSettings.shared

    init() {
        do {
            container = try ModelContainer(
                for: QuizRecord.self, CardRecord.self, SessionRecord.self,
                configurations: ModelConfiguration()
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .task {
                    DebugLog.log("AIQuiz launched")
                    await SampleQuizzes.seedIfNeeded(in: container.mainContext)
                }
        }
    }
}
