import SwiftUI
import SwiftData
import UserNotifications
import AIQuizCore

@main
struct AIQuizApp: App {
    let container: ModelContainer
    /// Set when the library could not be opened and a fresh one was started (SPEC D-10).
    let recoveredBackup: URL?
    private let environment = AppEnvironment.current
    @State private var settings = AppSettings.shared
    @State private var router: AIRouter
    @State private var speech = SpeechServices.make(for: AppEnvironment.current)
    @State private var queue: GenerationQueue
    @State private var reviewRouter = ReviewRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LaunchMetric.markProcessStart()
        let container: ModelContainer
        do {
            let result = try StoreLoader.makeContainer(storeURL: AppEnvironment.current.storeURL, defaults: AppEnvironment.defaults)
            container = result.container
            recoveredBackup = result.recoveredFromFailure
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container
        let router = AIRouter.makeForCurrentEnvironment()
        _router = State(initialValue: router)
        _queue = State(initialValue: GenerationQueue.make(for: AppEnvironment.current, router: router, context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView(recoveredBackup: recoveredBackup)
                .modelContainer(container)
                .environment(settings)
                .environment(router)
                .environment(speech)
                .environment(queue)
                .environment(reviewRouter)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .task {
                    Log.app.info("AIQuiz launched (uiTest=\(environment.isUITest), scenario=\(environment.scenario.rawValue))")
                    if environment.isUITest {
                        await UITestFixtures.seed(scenario: environment.scenario, in: container.mainContext)
                    } else {
                        SampleQuizzes.seedOnFirstLaunch(in: container.mainContext, defaults: AppEnvironment.defaults)
                    }
                    QuizStats.refreshStale(in: container.mainContext)
                    ShareInbox.drain(into: queue)
                    queue.start()
                    UNUserNotificationCenter.current().delegate = reviewRouter
                    DueNotifications.reschedule(settings: settings, context: container.mainContext)
                }
                .onChange(of: settings.reminderOn) { _, _ in DueNotifications.reschedule(settings: settings, context: container.mainContext) }
                .onChange(of: settings.reminderMinutes) { _, _ in DueNotifications.reschedule(settings: settings, context: container.mainContext) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                QuizStats.refreshStale(in: container.mainContext)
                ShareInbox.drain(into: queue)
                queue.start()
            }
            if phase == .background {
                DueNotifications.reschedule(settings: settings, context: container.mainContext)
            }
        }
    }
}

extension GenerationQueue {
    /// The composition root's queue: live extraction and the real store, or fakes and a
    /// throwaway job file in UI-test mode.
    static func make(for environment: AppEnvironment, router: AIRouter, context: ModelContext) -> GenerationQueue {
        let root = environment.isUITest
            ? URL.cachesDirectory.appending(path: "uitest-generation")
            : URL.applicationSupportDirectory.appending(path: "Generation")
        if environment.isUITest { try? FileManager.default.removeItem(at: root) }
        let foldersRoot = root.appending(path: "Jobs")
        let pipeline = GenerationPipeline(
            extractor: environment.isUITest ? FakeSourceExtractor() : LiveSourceExtractor(),
            client: { try router.client(for: .generation) },
            jobFolder: { foldersRoot.appending(path: $0.uuidString) }
        )
        let queue = GenerationQueue(
            store: GenerationJobStore(url: root.appending(path: "jobs.json")),
            foldersRoot: foldersRoot,
            pipeline: { job, report in try await pipeline.run(job, report: report) },
            save: { output, job in try GenerationQueue.saveQuiz(output, job: job, in: context) }
        )
        queue.onFinished = { name in
            guard !environment.isUITest, UIApplication.shared.applicationState != .active else { return }
            Notifier.post(title: "Quiz ready", body: name)
        }
        return queue
    }

    /// Saves a finished job as a quiz with its original content (CR-007).
    static func saveQuiz(_ output: GenerationOutput, job: GenerationJob, in context: ModelContext) throws -> UUID {
        let record = QuizRecord.make(from: output.payload, origin: output.origin, source: output.original)
        record.generatedByEndpointName = output.endpoint.name
        record.generatedByModel = output.endpoint.model
        context.insert(record)
        try context.save()
        return record.id
    }
}

/// Local notifications for finished background jobs (F-61).
enum Notifier {
    /// Asks once, the first time the user queues a quiz.
    static func requestPermissionIfNeeded() {
        guard !AppEnvironment.current.isUITest else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
