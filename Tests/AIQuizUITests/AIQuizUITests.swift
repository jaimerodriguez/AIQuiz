import XCTest

/// UI flows under `-UITestMode` (PLAN §1.3, §1.5). Uses accessibility identifiers from SPEC §12 only.
final class AIQuizUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scenario: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        if let scenario {
            app.launchArguments += ["-UITestScenario", scenario]
        }
        app.launch()
        return app
    }

    private func openQuiz(_ app: XCUIApplication, named name: String) {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "quiz row \(name) not found")
        row.tap()
    }

    /// The Generate sheet is short on iPad and the keyboard shortens it further, so controls
    /// below the fold are not hittable until the form scrolls. Drags on a static text inside
    /// the form (never on a field, which would start text selection) until `target` is hittable.
    private func scrollGenerateForm(_ app: XCUIApplication, until target: XCUIElement) {
        let anchors = [
            app.staticTexts["Topic mode lets you set card count, difficulty, language, and tone."],
            app.staticTexts["Topic"],
            app.staticTexts["Generate"]
        ]
        for _ in 0..<6 {
            if target.waitForExistence(timeout: 1) && target.isHittable { return }
            guard let anchor = anchors.first(where: { $0.exists && $0.isHittable }) else { return }
            let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -350)))
        }
    }

    /// The first element with this identifier, whatever its accessibility type. SwiftUI often
    /// copies an identifier onto a wrapper and its child, so a plain subscript can be ambiguous.
    /// Use only for assertions; tap through typed queries (`app.buttons[...]`).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Typed button lookup by identifier, falling back to its visible label.
    private func button(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.buttons[id]
        return byID.waitForExistence(timeout: 2) ? byID : app.buttons[label]
    }

    // MARK: AI endpoints (PLAN Phase 1)

    /// Library → Settings → AI endpoints → Add → preset. Returns with the editor open.
    private func openEndpointEditor(_ app: XCUIApplication, preset id: String, label: String) {
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: timeout))
        app.buttons["library.settings"].tap()
        let endpointsLink = button(app, id: "settings.endpoints", label: "AI endpoints")
        XCTAssertTrue(endpointsLink.waitForExistence(timeout: timeout))
        endpointsLink.tap()
        let add = button(app, id: "endpoints.add", label: "Add endpoint")
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let preset = button(app, id: "endpoints.preset.\(id)", label: label)
        XCTAssertTrue(preset.waitForExistence(timeout: timeout), "preset menu did not open")
        preset.tap()
        XCTAssertTrue(app.buttons["endpoints.save"].waitForExistence(timeout: timeout))
    }

    /// The visible key field wraps, so XCUITest may expose it as a text view.
    private func keyField(_ app: XCUIApplication) -> XCUIElement {
        let view = app.textViews["endpoints.key"]
        return view.waitForExistence(timeout: 2) ? view : app.textFields["endpoints.key"]
    }

    /// Types the key, then the base URL ending in Return, which dismisses the keyboard.
    private func fillCustomEndpoint(_ app: XCUIApplication, key: String) {
        let keyInput = keyField(app)
        XCTAssertTrue(keyInput.exists, "key field is visible (not secure) by default")
        keyInput.tap()
        keyInput.typeText(key)
        let baseURL = app.textFields["endpoints.baseURL"]
        baseURL.tap()
        baseURL.typeText("http://example.local/v1\n")
    }

    func testAddEndpointTestSendsHelloThenSave() {
        let app = launch()
        openEndpointEditor(app, preset: "custom", label: "Custom OpenAI-compatible")
        fillCustomEndpoint(app, key: "local-token")

        button(app, id: "endpoints.test", label: "Test connection").tap()
        let result = element(app, "endpoints.testResult")
        XCTAssertTrue(result.waitForExistence(timeout: timeout))
        XCTAssertTrue(result.label.contains("fake-model-a replied"), "got: \(result.label)")
        XCTAssertTrue(result.label.contains("2 models"), "got: \(result.label)")
        XCTAssertEqual(app.textFields["endpoints.model"].value as? String, "fake-model-a")

        app.buttons["endpoints.save"].tap()
        XCTAssertTrue(element(app, "endpoints.row.Custom").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "endpoints.route.generation").exists, "routing appears once endpoints exist")
    }

    func testSavingANewKeyVerifiesItFirst() {
        let app = launch()
        openEndpointEditor(app, preset: "custom", label: "Custom OpenAI-compatible")
        fillCustomEndpoint(app, key: "local-token")
        app.buttons["endpoints.save"].tap()
        XCTAssertTrue(element(app, "endpoints.row.Custom").waitForExistence(timeout: timeout), "a passing hello saves and closes")
    }

    func testFailedVerificationOffersSaveAnyway() {
        let app = launch(scenario: "endpointError")
        openEndpointEditor(app, preset: "custom", label: "Custom OpenAI-compatible")
        fillCustomEndpoint(app, key: "local-token")
        app.buttons["endpoints.save"].tap()

        let alert = app.alerts["Couldn't confirm this key"]
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "endpoints.testResult").exists, "the failure is also shown inline")
        alert.buttons["Save anyway"].firstMatch.tap()
        XCTAssertTrue(element(app, "endpoints.row.Custom").waitForExistence(timeout: timeout))
    }

    func testKeyWarningAndHideToggle() {
        let app = launch()
        openEndpointEditor(app, preset: "anthropic", label: "Anthropic")
        let keyInput = keyField(app)
        XCTAssertTrue(keyInput.exists)
        keyInput.tap()
        keyInput.typeText("sk-proj-pasted-the-wrong-one")

        let warning = element(app, "endpoints.keyWarning")
        XCTAssertTrue(warning.waitForExistence(timeout: timeout))
        XCTAssertTrue(warning.label.contains("sk-ant-"), "got: \(warning.label)")

        app.buttons["endpoints.keyVisibility"].tap()
        XCTAssertTrue(app.secureTextFields["endpoints.key"].waitForExistence(timeout: timeout), "hide switches to a secure field")
        app.buttons["endpoints.keyVisibility"].tap()
        XCTAssertTrue(keyField(app).waitForExistence(timeout: timeout))
    }

    func testGenerateWithoutEndpointShowsSetupSheet() {
        let app = launch(scenario: "noEndpoints")
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        app.buttons["library.generate"].tap()
        let topic = app.textFields["generate.topic"]
        XCTAssertTrue(topic.waitForExistence(timeout: timeout))
        topic.tap()
        topic.typeText("Anything")
        let run = app.buttons["generate.run"]
        scrollGenerateForm(app, until: run)
        run.tap()

        let issue = element(app, "endpoints.setupIssue")
        XCTAssertTrue(issue.waitForExistence(timeout: timeout))
        XCTAssertTrue(issue.label.contains("Add an AI endpoint"), "got: \(issue.label)")
        XCTAssertTrue(element(app, "endpoints.done").exists)
    }

    // MARK: Library

    func testLibraryShowsSeededQuizzes() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Roman Emperors"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Common Spanish Verbs"].exists)
        XCTAssertTrue(app.staticTexts["Systems Design Fundamentals"].exists)
        XCTAssertTrue(app.staticTexts["UITest Deck"].exists)
        XCTAssertTrue(app.buttons["library.addButton"].exists)
        XCTAssertTrue(app.buttons["library.settings"].exists)
    }

    func testEmptyLibraryScenario() {
        let app = launch(scenario: "emptyLibrary")
        XCTAssertTrue(app.staticTexts["No quizzes yet"].waitForExistence(timeout: timeout))
    }

    // MARK: Study — User-paced read

    func testStudyReadFlipAndNext() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let mode = app.buttons["detail.mode.studyRead"]
        XCTAssertTrue(mode.waitForExistence(timeout: timeout))
        mode.tap()

        XCTAssertTrue(app.staticTexts["session.progress"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 1 of 6")
        XCTAssertFalse(app.staticTexts["session.card.longAnswer"].exists)

        let reveal = app.buttons["studyRead.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: timeout))
        reveal.tap()
        XCTAssertTrue(app.staticTexts["session.card.longAnswer"].waitForExistence(timeout: timeout))

        app.buttons["studyRead.next"].tap()
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 2 of 6")
        XCTAssertFalse(app.staticTexts["session.card.longAnswer"].exists, "reveal state must reset on next")

        app.buttons["studyRead.back"].tap()
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 1 of 6")
    }

    // MARK: Quiz — Voice answer (no microphone path; Show answer + self-grade)

    func testQuizVoiceShowAnswerAndGrade() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let mode = app.buttons["detail.mode.quizVoice"]
        XCTAssertTrue(mode.waitForExistence(timeout: timeout))
        mode.tap()

        XCTAssertTrue(app.buttons["quiz.tapToAnswer"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 1 of 6")

        app.buttons["quiz.showAnswer"].tap()
        XCTAssertTrue(app.staticTexts["session.card.longAnswer"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["quiz.grade.correct"].exists)
        XCTAssertFalse(app.buttons["quiz.askAI"].isEnabled, "no transcript, so AI judge is disabled")

        app.buttons["quiz.grade.correct"].tap()
        XCTAssertTrue(app.buttons["quiz.tapToAnswer"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 2 of 6")
    }

    func testQuizVoiceCompleteSessionShowsSummary() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.quizVoice"].tap()
        for i in 0..<6 {
            XCTAssertTrue(app.buttons["quiz.showAnswer"].waitForExistence(timeout: timeout), "card \(i + 1)")
            app.buttons["quiz.showAnswer"].tap()
            let grade = i % 2 == 0 ? "quiz.grade.correct" : "quiz.grade.wrong"
            XCTAssertTrue(app.buttons[grade].waitForExistence(timeout: timeout))
            app.buttons[grade].tap()
        }
        XCTAssertTrue(app.staticTexts["summary.score"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["summary.score"].label, "50%")
        app.buttons["summary.done"].tap()
        XCTAssertTrue(app.buttons["detail.mode.quizVoice"].waitForExistence(timeout: timeout))
    }

    func testEndSessionDiscardsProgress() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyRead"].tap()
        XCTAssertTrue(app.buttons["session.end"].waitForExistence(timeout: timeout))
        app.buttons["session.end"].tap()
        let endAlert = app.alerts.firstMatch
        XCTAssertTrue(endAlert.waitForExistence(timeout: timeout))
        endAlert.buttons["End"].tap()
        XCTAssertTrue(app.buttons["detail.mode.studyRead"].waitForExistence(timeout: timeout))
    }

    // MARK: Generate with the fake endpoint

    func testGenerateTopicQuizWithFakeEndpoint() {
        let app = launch()
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        let generate = app.buttons["library.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: timeout))
        generate.tap()

        let topic = app.textFields["generate.topic"]
        XCTAssertTrue(topic.waitForExistence(timeout: timeout))
        topic.tap()
        topic.typeText("Roman emperors")

        let run = app.buttons["generate.run"]
        scrollGenerateForm(app, until: run)
        XCTAssertTrue(run.isHittable, "Generate button must be scrolled into view")
        run.tap()
        let open = app.buttons["generate.openLibrary"]
        scrollGenerateForm(app, until: open)
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        XCTAssertTrue(app.staticTexts["Fake Generated Quiz"].waitForExistence(timeout: timeout))
    }

    func testGenerateShowsFriendlyErrorOnEndpointFailure() {
        let app = launch(scenario: "endpointError")
        app.buttons["library.addButton"].tap()
        app.buttons["library.generate"].tap()
        let topic = app.textFields["generate.topic"]
        XCTAssertTrue(topic.waitForExistence(timeout: timeout))
        topic.tap()
        topic.typeText("Anything")
        let run = app.buttons["generate.run"]
        scrollGenerateForm(app, until: run)
        XCTAssertTrue(run.isHittable, "Generate button must be scrolled into view")
        run.tap()
        let error = app.staticTexts["generate.error"]
        scrollGenerateForm(app, until: error)
        XCTAssertTrue(error.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["generate.openLibrary"].exists)
    }
}
