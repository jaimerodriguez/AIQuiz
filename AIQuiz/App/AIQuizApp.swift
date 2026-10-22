import SwiftUI
import SwiftData

@main
struct AIQuizApp: App {
    let container: ModelContainer
    private let environment = AppEnvironment.current
    @State private var settings = AppSettings.shared
    @State private var router = AIRouter.makeForCurrentEnvironment()

    init() {
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: AppEnvironment.current.isUITest)
            container = try ModelContainer(
                for: QuizRecord.self, CardRecord.self, SessionRecord.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
                .environment(settings)
                .environment(router)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .task {
                    Log.app.info("AIQuiz launched (uiTest=\(environment.isUITest), scenario=\(environment.scenario.rawValue))")
                    if environment.isUITest {
                        await UITestFixtures.seed(scenario: environment.scenario, in: container.mainContext)
                    } else {
                        await SampleQuizzes.seedIfNeeded(in: container.mainContext)
                    }
                }
        }
    }
}
