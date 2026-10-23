import Foundation

/// Process-level configuration decided once at launch from the launch arguments
/// (DECISIONS ADR-005, PLAN §1.5). The only composition-root static in the app.
///
/// Launch arguments:
/// - `-UITestMode`            in-memory store, seeded fixtures, fake AI provider, throwaway defaults
/// - `-UITestScenario <name>` one of `standard`, `emptyLibrary`, `endpointError`, `malformedJSON`, `noEndpoints`
struct AppEnvironment: Sendable {
    enum Scenario: String, Sendable, CaseIterable {
        case standard
        case emptyLibrary
        case endpointError
        case malformedJSON
        /// No AI endpoint configured, to exercise the lazy setup sheet.
        case noEndpoints
    }

    let isUITest: Bool
    let scenario: Scenario

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

    init(arguments: [String]) {
        isUITest = arguments.contains("-UITestMode")
        if let i = arguments.firstIndex(of: "-UITestScenario"),
           i + 1 < arguments.count,
           let s = Scenario(rawValue: arguments[i + 1]) {
            scenario = s
        } else {
            scenario = .standard
        }
    }
}
