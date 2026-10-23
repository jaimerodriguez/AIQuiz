import SwiftUI
import SwiftData

@main
struct AIQuizApp: App {
    let container: ModelContainer
    /// Set when the library could not be opened and a fresh one was started (SPEC D-10).
    let recoveredBackup: URL?
    private let environment = AppEnvironment.current
    @State private var settings = AppSettings.shared
    @State private var router = AIRouter.makeForCurrentEnvironment()
    @State private var speech = SpeechServices.make(for: AppEnvironment.current)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LaunchMetric.markProcessStart()
        do {
            let result = try StoreLoader.makeContainer(storeURL: AppEnvironment.current.storeURL, defaults: AppEnvironment.defaults)
            container = result.container
            recoveredBackup = result.recoveredFromFailure
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(recoveredBackup: recoveredBackup)
                .modelContainer(container)
                .environment(settings)
                .environment(router)
                .environment(speech)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .task {
                    Log.app.info("AIQuiz launched (uiTest=\(environment.isUITest), scenario=\(environment.scenario.rawValue))")
                    if environment.isUITest {
                        await UITestFixtures.seed(scenario: environment.scenario, in: container.mainContext)
                    } else {
                        SampleQuizzes.seedOnFirstLaunch(in: container.mainContext, defaults: AppEnvironment.defaults)
                    }
                    QuizStats.refreshStale(in: container.mainContext)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                QuizStats.refreshStale(in: container.mainContext)
            }
        }
    }
}
