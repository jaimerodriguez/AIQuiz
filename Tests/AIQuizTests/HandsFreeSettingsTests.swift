import XCTest
@testable import AIQuiz

/// S-18, S-19: auto-listen in Quiz — Voice.
@MainActor
final class HandsFreeSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "handsfree-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testAutoListenIsOffWithThreeSecondsAndPersists() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoListen)
        XCTAssertEqual(settings.autoListenSeconds, 3)
        settings.autoListen = true
        settings.autoListenSeconds = 12
        let again = AppSettings(defaults: defaults)
        XCTAssertTrue(again.autoListen)
        XCTAssertEqual(again.autoListenSeconds, 12)
    }

    func testAStoredWaitOutsideOneToThirtyIsClamped() {
        let defaults = freshDefaults()
        defaults.set(0, forKey: "autoListenSeconds")
        XCTAssertEqual(AppSettings(defaults: defaults).autoListenSeconds, 1)
        defaults.set(90, forKey: "autoListenSeconds")
        XCTAssertEqual(AppSettings(defaults: defaults).autoListenSeconds, 30)
        defaults.set("8", forKey: "autoListenSeconds")
        XCTAssertEqual(AppSettings(defaults: defaults).autoListenSeconds, 8, "a value stored as text still reads")
    }
}
