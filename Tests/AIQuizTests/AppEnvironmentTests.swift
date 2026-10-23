import XCTest
@testable import AIQuiz

final class AppEnvironmentTests: XCTestCase {
    func testDefaultsToProduction() {
        let env = AppEnvironment(arguments: ["AIQuiz"])
        XCTAssertFalse(env.isUITest)
        XCTAssertEqual(env.scenario, .standard)
    }

    func testUITestModeFlag() {
        let env = AppEnvironment(arguments: ["AIQuiz", "-UITestMode"])
        XCTAssertTrue(env.isUITest)
        XCTAssertEqual(env.scenario, .standard)
    }

    func testScenarioParsing() {
        let env = AppEnvironment(arguments: ["AIQuiz", "-UITestMode", "-UITestScenario", "emptyLibrary"])
        XCTAssertEqual(env.scenario, .emptyLibrary)
    }

    func testUnknownScenarioFallsBackToStandard() {
        let env = AppEnvironment(arguments: ["-UITestMode", "-UITestScenario", "nope"])
        XCTAssertEqual(env.scenario, .standard)
    }

    func testDanglingScenarioFlagIsIgnored() {
        let env = AppEnvironment(arguments: ["-UITestMode", "-UITestScenario"])
        XCTAssertEqual(env.scenario, .standard)
    }
}
