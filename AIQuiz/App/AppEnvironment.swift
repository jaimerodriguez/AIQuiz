import Foundation

/// Process-level configuration decided once at launch from the launch arguments
/// (DECISIONS ADR-005, PLAN §1.5). The only composition-root static in the app.
///
/// Launch arguments:
/// - `-UITestMode`            in-memory store, seeded fixtures, fake AI provider, throwaway defaults
/// - `-UITestOnboarding`     show onboarding (UI-test mode skips it otherwise)
/// - `-UITestScenario <name>` one of `standard`, `emptyLibrary`, `endpointError`, `malformedJSON`, `noEndpoints`, `largeLibrary`
struct AppEnvironment: Sendable {
    enum Scenario: String, Sendable, CaseIterable {
        case standard
        case emptyLibrary
        case endpointError
        case malformedJSON
        /// No AI endpoint configured, to exercise the lazy setup sheet.
        case noEndpoints
        /// 200 quizzes, 10 000 cards and 5 000 sessions in an on-disk store that survives
        /// relaunches, for the SPEC N-8 scale checks.
        case largeLibrary
    }

    let isUITest: Bool
    let scenario: Scenario
    /// Onboarding (F-60) is skipped in UI-test mode unless a test asks for it.
    let allowsOnboarding: Bool

    static let current = AppEnvironment(arguments: ProcessInfo.processInfo.arguments)

    /// The defaults store for this process. UI-test mode uses a suite that is wiped at launch
    /// so no setting leaks between test runs.
    @MainActor
    static let defaults: UserDefaults = {
        guard current.isUITest else { return .standard }
        let suite = "com.jaimerodriguez.aiquiz.uitest"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        return d
    }()

    /// Where the library lives: the real store, nothing (in memory) for UI tests, or a
    /// reusable on-disk store for the large-library scenario.
    var storeURL: URL? {
        guard isUITest else { return StoreLoader.defaultStoreURL }
        guard scenario == .largeLibrary else { return nil }
        return URL.cachesDirectory.appending(path: "uitest-largeLibrary/default.store")
    }

    init(arguments: [String]) {
        isUITest = arguments.contains("-UITestMode")
        allowsOnboarding = !isUITest || arguments.contains("-UITestOnboarding")
        if let i = arguments.firstIndex(of: "-UITestScenario"),
           i + 1 < arguments.count,
           let s = Scenario(rawValue: arguments[i + 1]) {
            scenario = s
        } else {
            scenario = .standard
        }
    }
}
