import XCTest

/// UI flows under `-UITestMode` (PLAN §1.3, §1.5). Uses accessibility identifiers from SPEC §12 only.
@MainActor
final class AIQuizUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(scenario: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extra
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
            // XCUITest rejects query strings over 128 characters; match long footers by prefix.
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "When you provide a source")).firstMatch,
            app.staticTexts["Topic"],
            app.staticTexts["Paste text or markdown"],
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

    // MARK: Original content (CR-007)

    /// Generate → Paste text, type a small Markdown document, generate, open the new quiz.
    private func generateFromPastedText(_ app: XCUIApplication, text: String) {
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        app.buttons["library.generate"].tap()

        let sourcePicker = button(app, id: "generate.source", label: "Source")
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: timeout))
        sourcePicker.tap()
        let paste = app.buttons["Paste text"]
        XCTAssertTrue(paste.waitForExistence(timeout: timeout), "source menu did not open")
        paste.tap()

        let editor = app.textViews["generate.paste"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText(text)

        let run = app.buttons["generate.run"]
        scrollGenerateForm(app, until: run)
        run.tap()
        waitForGeneratedQuiz(app)
        openQuiz(app, named: "Fake Generated Quiz")
    }

    /// Generation runs in the queue (F-61): the sheet closes and the quiz lands in the library.
    private func waitForGeneratedQuiz(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Fake Generated Quiz"].waitForExistence(timeout: 20), "the queued quiz arrives", file: file, line: line)
    }

    func testPastedTextQuizShowsItsOriginalText() {
        let app = launch()
        generateFromPastedText(app, text: "## My pasted heading\nThe body of what I pasted.\n\n| Term | Meaning |\n|---|---|\n| Cell A | Cell B |\n")

        let original = button(app, id: "detail.mode.source", label: "Read Source Materials")
        XCTAssertTrue(original.waitForExistence(timeout: timeout), "a pasted-text quiz offers Read Source Materials in Modes")
        XCTAssertFalse(app.staticTexts["Original content"].exists, "no separate section")
        original.tap()
        XCTAssertTrue(app.staticTexts["My pasted heading"].waitForExistence(timeout: timeout), "the original text renders")
        XCTAssertTrue(element(app, "reader.table").exists, "the table renders as a table")
        XCTAssertTrue(app.staticTexts["Cell B"].exists, "table cells render")
        XCTAssertTrue(app.buttons["reader.share"].exists)
    }

    func testTopicQuizHasNoOriginalContentSection() {
        let app = launch()
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        app.buttons["library.generate"].tap()
        let topic = app.textFields["generate.topic"]
        XCTAssertTrue(topic.waitForExistence(timeout: timeout))
        topic.tap()
        topic.typeText("Roman emperors")
        let run = app.buttons["generate.run"]
        scrollGenerateForm(app, until: run)
        XCTAssertFalse(app.switches["generate.writeNotes"].exists, "the AI notes toggle is gone")
        run.tap()
        waitForGeneratedQuiz(app)

        openQuiz(app, named: "Fake Generated Quiz")
        XCTAssertTrue(app.buttons["detail.mode.quizVoice"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["detail.mode.source"].exists, "topic quizzes have no source materials")
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
        XCTAssertFalse(app.buttons["quiz.askAI"].exists, "auto-grade is on (S-3), so there is no Ask AI button")
        XCTAssertFalse(element(app, "quiz.aiJudging").exists, "no transcript, so nothing to grade")

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
        XCTAssertTrue(element(app, "summary.recap").waitForExistence(timeout: timeout), "the AI recap arrives (F-44)")
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
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout), "the sheet closes right away")
        waitForGeneratedQuiz(app)
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
        // The failure shows in the job list with a friendly message and Retry (F-61, §7.3).
        let status = element(app, "library.job.0.status")
        XCTAssertTrue(status.waitForExistence(timeout: timeout))
        for _ in 0..<40 where !status.label.lowercased().contains("server") && !status.label.lowercased().contains("unavailable") {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(status.label.contains("Waiting"), "the job failed: \(status.label)")
        XCTAssertTrue(app.buttons["library.job.0.retry"].exists)
        XCTAssertFalse(app.staticTexts["Fake Generated Quiz"].exists)
    }

    // MARK: Library and card management (PLAN Phase 2)

    private func longPress(_ app: XCUIApplication, quiz name: String) {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "quiz row \(name) not found")
        row.press(forDuration: 1.2)
    }

    /// The library search: inline next to sort on iPad, the system search bar on iPhone.
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let inline = app.textFields["library.search"]
        return inline.waitForExistence(timeout: 2) ? inline : app.searchFields.firstMatch
    }

    private func firstRowLabel(_ app: XCUIApplication) -> String {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: timeout))
        return rows.firstMatch.label
    }

    func testEditACard() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let card = app.buttons["detail.card.0"]
        XCTAssertTrue(card.waitForExistence(timeout: timeout))
        card.tap()
        XCTAssertTrue(element(app, "card.prompt").waitForExistence(timeout: timeout), "the card sheet opens")
        app.buttons["card.edit"].tap()

        let prompt = app.textViews["cardEdit.prompt"].exists ? app.textViews["cardEdit.prompt"] : app.textFields["cardEdit.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout))
        prompt.tap()
        prompt.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        prompt.typeText("Edited prompt")
        app.buttons["cardEdit.save"].tap()

        XCTAssertTrue(app.staticTexts["Edited prompt"].waitForExistence(timeout: timeout), "the sheet shows the edit")
        app.buttons["card.done"].tap()
        XCTAssertTrue(app.buttons["detail.card.0"].staticTexts["Edited prompt"].waitForExistence(timeout: timeout), "the card list shows the edit")
    }

    func testCardEditRejectsAMultipleChoiceCardWithoutOptions() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.card.0"].tap()
        XCTAssertTrue(app.buttons["card.edit"].waitForExistence(timeout: timeout))
        app.buttons["card.edit"].tap()
        let kind = app.buttons["cardEdit.kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: timeout))
        kind.tap()
        let mcq = app.buttons["Multiple choice"]
        XCTAssertTrue(mcq.waitForExistence(timeout: timeout))
        mcq.tap()
        XCTAssertTrue(element(app, "cardEdit.problem").waitForExistence(timeout: timeout), "the D-2 rule is explained")
        XCTAssertFalse(app.buttons["cardEdit.save"].isEnabled, "Save is disabled while the card is invalid")
    }

    func testDeleteACard() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.card.0"].tap()
        let delete = app.buttons["card.delete"]
        let anchor = element(app, "card.longAnswer")
        XCTAssertTrue(anchor.waitForExistence(timeout: timeout))
        for _ in 0..<4 where !(delete.exists && delete.isHittable) {
            anchor.swipeUp()
        }
        XCTAssertTrue(delete.waitForExistence(timeout: timeout))
        delete.tap()
        // The confirmation dialog copies the identifier onto its wrapper; tap the first match.
        let confirm = app.buttons.matching(identifier: "card.confirmDelete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Fixture prompt two"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Fixture prompt one"].exists, "the card is gone")
        let cards = element(app, "detail.stat.cards")
        XCTAssertTrue(cards.waitForExistence(timeout: timeout))
        XCTAssertTrue("\(cards.label) \(cards.value ?? "")".contains("5"), "the stored card count drops to 5: \(cards.label)")
    }

    func testRenameAQuizFromTheLibrary() {
        let app = launch()
        longPress(app, quiz: "UITest Deck")
        let rename = button(app, id: "library.rename", label: "Rename")
        XCTAssertTrue(rename.waitForExistence(timeout: timeout), "context menu opens")
        rename.tap()
        let name = app.textFields["quizEdit.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        name.tap()
        if let value = name.value as? String {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        name.typeText("Renamed Deck")
        app.buttons["quizEdit.save"].tap()
        XCTAssertTrue(app.staticTexts["Renamed Deck"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["UITest Deck"].exists)
    }

    func testEditTagsThenSearchByTag() {
        let app = launch()
        longPress(app, quiz: "UITest Deck")
        let editTags = button(app, id: "library.editTags", label: "Edit tags")
        XCTAssertTrue(editTags.waitForExistence(timeout: timeout))
        editTags.tap()
        let tags = app.textFields["quizEdit.tags"]
        XCTAssertTrue(tags.waitForExistence(timeout: timeout))
        tags.tap()
        tags.typeText(", zebra")
        app.buttons["quizEdit.save"].tap()
        XCTAssertTrue(app.staticTexts["#fixture #zebra"].waitForExistence(timeout: timeout), "the row shows the tags")

        let search = searchField(app)
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.tap()
        search.typeText("#zebra")
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Roman Emperors"].exists, "search filters on tags")
    }

    func testArchiveMovesAQuizToTheArchivedSection() {
        let app = launch()
        longPress(app, quiz: "UITest Deck")
        let archive = button(app, id: "library.archive", label: "Archive")
        XCTAssertTrue(archive.waitForExistence(timeout: timeout))
        archive.tap()
        let archived = element(app, "library.archived")
        XCTAssertTrue(archived.waitForExistence(timeout: timeout), "an Archived section appears")
        XCTAssertFalse(app.staticTexts["UITest Deck"].isHittable && app.staticTexts["UITest Deck"].exists, "collapsed by default")
        app.buttons["library.archived"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout), "expanding shows it")
    }

    func testSortByName() {
        let app = launch()
        let sort = app.buttons["library.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: timeout))
        sort.tap()
        let byName = button(app, id: "library.sort.name", label: "Name")
        XCTAssertTrue(byName.waitForExistence(timeout: timeout))
        byName.tap()
        XCTAssertTrue(firstRowLabel(app).hasPrefix("Common Spanish Verbs"), "first row is \(firstRowLabel(app))")
    }

    func testExportJSONOpensTheFileExporter() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        more.tap()
        let export = button(app, id: "detail.export", label: "Export JSON")
        XCTAssertTrue(export.waitForExistence(timeout: timeout))
        export.tap()
        // The system document picker runs out of process; its buttons show up under the app.
        let picker = app.buttons["Move"].exists ? app.buttons["Move"] : app.navigationBars.buttons["Save"]
        let appeared = picker.waitForExistence(timeout: timeout)
            || app.buttons["Save"].waitForExistence(timeout: 2)
            || app.buttons["Cancel"].waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, "the file exporter appears")
    }

    // MARK: Scale (SPEC N-8, scenario largeLibrary)

    func testLargeLibraryLaunchScrollSortAndSearch() throws {
        // First launch seeds the on-disk library (slow, once); the second measures a cold start.
        var app = launch(scenario: "largeLibrary")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.row.'")).firstMatch.waitForExistence(timeout: 180))
        app.terminate()
        app = launch(scenario: "largeLibrary")
        let metric = element(app, "library.launchMetric")
        XCTAssertTrue(metric.waitForExistence(timeout: 30))
        let ms = Int(metric.label.filter(\.isNumber)) ?? Int.max
        print("PERF cold launch to first library row: \(ms) ms")
        XCTAssertLessThan(ms, 1500, "cold launch to first row")

        let list = app.collectionViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
        for _ in 0..<8 { list.swipeUp(velocity: .fast) }
        for _ in 0..<8 { list.swipeDown(velocity: .fast) }

        let sort = app.buttons["library.sort"]
        sort.tap()
        button(app, id: "library.sort.name", label: "Name").tap()
        let start = Date()
        let first = app.staticTexts["Large quiz 000"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        print("PERF sort by name visible after \(Int(Date().timeIntervalSince(start) * 1000)) ms (includes XCUITest polling)")

        let search = searchField(app)
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.tap()
        search.typeText("quiz 19")
        let searchStart = Date()
        XCTAssertTrue(app.staticTexts["Large quiz 199"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Large quiz 000"].exists)
        print("PERF search result visible after \(Int(Date().timeIntervalSince(searchStart) * 1000)) ms (includes XCUITest polling)")

        let chip = app.buttons["library.tag.history"]
        XCTAssertTrue(chip.exists || app.buttons["#history"].exists, "tag chips show above a library of more than 10 quizzes")
    }

    // MARK: Phase 3: onboarding, modes end to end, practice missed, privacy

    func testOnboardingWalksThroughAndClosesWithLater() {
        let app = launch(extra: ["-UITestOnboarding"])
        XCTAssertTrue(element(app, "onboarding.title.0").waitForExistence(timeout: timeout), "onboarding appears on first launch")
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(element(app, "onboarding.title.1").waitForExistence(timeout: timeout))
        app.buttons["onboarding.next"].tap()
        let start = app.buttons["onboarding.start"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "the last page ends with Let's get started")
        XCTAssertEqual(start.label, "Let's get started")
        XCTAssertFalse(app.buttons["onboarding.addEndpoint"].exists, "no Add endpoint or Later on the last page")
        start.tap()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout), "the library shows; samples were seeded regardless")
    }

    func testOnboardingSkip() {
        let app = launch(extra: ["-UITestOnboarding"])
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: timeout))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout))
    }

    func testGenerateIsDisabledUntilTheSourceIsReady() {
        let app = launch()
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        app.buttons["library.generate"].tap()
        let run = app.buttons["generate.run"]
        XCTAssertTrue(run.waitForExistence(timeout: timeout))
        XCTAssertFalse(run.isEnabled, "nothing to generate from yet")
        let cancel = app.buttons["generate.cancel"]
        XCTAssertLessThan(cancel.frame.minX, run.frame.minX, "Cancel is on the left, Generate on the right")
        let topic = app.textFields["generate.topic"]
        topic.tap()
        topic.typeText("Roman emperors")
        XCTAssertTrue(run.isEnabled, "a topic makes the quiz ready")
    }

    func testOnboardingIsNotShownByDefaultInTests() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["onboarding.skip"].exists)
    }

    func testStudyVoicePlaysPausesAndSkipsToTheEnd() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyVoice"].tap()
        let state = app.staticTexts["studyVoice.state"]
        XCTAssertTrue(state.waitForExistence(timeout: timeout))
        XCTAssertEqual(state.label, "Playing")
        app.buttons["studyVoice.pause"].tap()
        XCTAssertEqual(state.label, "Paused")
        app.buttons["studyVoice.play"].tap()
        XCTAssertEqual(state.label, "Playing")
        // Smart ordering shuffles the deck; skip to a card that has a hint, then pause on it.
        let hint = app.buttons["session.hint"]
        // Pause first, so playback can't move on between the check and the tap.
        app.buttons["studyVoice.pause"].tap()
        var skips = 0
        while !hint.isEnabled && skips < 5 {
            app.buttons["studyVoice.skip"].tap()
            if app.buttons["studyVoice.pause"].waitForExistence(timeout: 2) { app.buttons["studyVoice.pause"].tap() }
            skips += 1
        }
        hint.tap()
        XCTAssertTrue(element(app, "session.card.hint").waitForExistence(timeout: timeout))
        // Playback also advances on its own, so skip until the session ends.
        let skip = app.buttons["studyVoice.skip"]
        for _ in 0..<8 where skip.exists && skip.isHittable {
            skip.tap()
        }
        XCTAssertTrue(app.buttons["detail.mode.studyVoice"].waitForExistence(timeout: timeout), "the session ends and returns to the quiz")
        let sessions = element(app, "detail.stat.sessions")
        XCTAssertTrue(sessions.label.contains("1"), "the session was recorded: \(sessions.label)")
    }

    func testStudyReadToTheEndRecordsASessionAndHintResets() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyRead"].tap()
        let hint = app.buttons["session.hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: timeout))
        // Smart ordering shuffles the deck; move to a card that has a hint.
        var position = 1
        while !hint.isEnabled && position < 6 {
            app.buttons["studyRead.next"].tap()
            position += 1
        }
        XCTAssertLessThan(position, 6, "4 of the 6 fixture cards have hints")
        hint.tap()
        XCTAssertTrue(element(app, "session.card.hint").waitForExistence(timeout: timeout))
        app.buttons["studyRead.next"].tap()
        XCTAssertFalse(element(app, "session.card.hint").exists, "the hint resets on the next card")
        for _ in (position + 1)...6 { app.buttons["studyRead.next"].tap() }
        XCTAssertTrue(app.buttons["detail.mode.studyRead"].waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "detail.stat.sessions").label.contains("1"))
    }

    func testQuizVoiceAnswerByVoiceWithScriptedRecognition() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.quizVoice"].tap()
        XCTAssertTrue(app.buttons["quiz.tapToAnswer"].waitForExistence(timeout: timeout))
        app.buttons["quiz.tapToAnswer"].tap()
        let transcript = app.staticTexts["quiz.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: timeout))
        for _ in 0..<50 where transcript.label != "Fixture answer" {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(transcript.label, "Fixture answer", "the final transcript replaces the partial one")
        app.buttons["quiz.stopReveal"].tap()
        XCTAssertTrue(app.staticTexts["session.card.longAnswer"].waitForExistence(timeout: timeout))
        app.buttons["quiz.grade.correct"].tap()
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 2 of 6")
    }

    func testPracticeMissedCardsRunsARecordedSession() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.quizVoice"].tap()
        for i in 0..<6 {
            XCTAssertTrue(app.buttons["quiz.showAnswer"].waitForExistence(timeout: timeout))
            app.buttons["quiz.showAnswer"].tap()
            app.buttons[i < 2 ? "quiz.grade.wrong" : "quiz.grade.correct"].tap()
        }
        let practice = app.buttons["summary.practiceMissed"]
        XCTAssertTrue(practice.waitForExistence(timeout: timeout))
        practice.tap()
        XCTAssertTrue(app.staticTexts["session.progress"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 1 of 2", "only the missed cards")
        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["quiz.showAnswer"].waitForExistence(timeout: timeout))
            app.buttons["quiz.showAnswer"].tap()
            app.buttons["quiz.grade.correct"].tap()
        }
        XCTAssertTrue(app.staticTexts["summary.score"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["summary.score"].label, "100%")
        app.buttons["summary.done"].tap()
        let sessions = element(app, "detail.stat.sessions")
        XCTAssertTrue(sessions.waitForExistence(timeout: timeout))
        XCTAssertTrue(sessions.label.contains("2"), "both sessions are recorded: \(sessions.label)")
    }

    func testClearQuizLibraryEmptiesTheLibrary() {
        let app = launch()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: timeout))
        app.buttons["library.settings"].tap()
        let clear = app.buttons["settings.clearLibrary"]
        for _ in 0..<8 where !(clear.exists && clear.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(clear.waitForExistence(timeout: timeout))
        clear.tap()
        let confirm = app.buttons.matching(identifier: "settings.confirmClear").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: timeout))
        app.buttons["OK"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["No quizzes yet"].waitForExistence(timeout: timeout), "the library is empty, like the emptyLibrary scenario")
    }

    // MARK: Phase 4: AI grading, card AI actions, lint

    func testVoiceAnswerIsAutoGradedAndCanBeOverridden() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.quizVoice"].tap()
        XCTAssertTrue(app.buttons["quiz.tapToAnswer"].waitForExistence(timeout: timeout))
        app.buttons["quiz.tapToAnswer"].tap()
        // No tap on Stop: two seconds of silence after the answer reveal it (F-14).
        let verdict = element(app, "quiz.aiVerdict")
        XCTAssertTrue(verdict.waitForExistence(timeout: timeout), "the AI verdict chip appears (F-15)")
        XCTAssertTrue(app.staticTexts["AI: Partial"].exists)
        XCTAssertTrue(app.buttons["quiz.grade.partial"].isSelected, "the AI's grade is pre-selected")
        XCTAssertFalse(app.buttons["quiz.askAI"].exists, "auto-grade replaces Ask AI")

        let why = app.buttons["quiz.whyWrong"]
        XCTAssertTrue(why.waitForExistence(timeout: timeout), "Why was I wrong? appears after a partial verdict (F-16)")
        why.tap()
        XCTAssertTrue(element(app, "quiz.whyWrongText").waitForExistence(timeout: timeout))

        app.buttons["quiz.grade.correct"].tap()
        XCTAssertEqual(app.staticTexts["session.progress"].label, "Card 2 of 6", "the user's grade wins")
    }

    func testLintListsIssuesAndAppliesAFix() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let lint = app.buttons["detail.lint"]
        XCTAssertTrue(lint.waitForExistence(timeout: timeout))
        lint.tap()
        XCTAssertTrue(element(app, "lint.issue.0").waitForExistence(timeout: timeout), "lint lists issues (F-29)")
        XCTAssertTrue(element(app, "lint.issue.1").exists)
        XCTAssertFalse(app.buttons["lint.apply.1"].exists, "no fix offered without a suggestion")
        app.buttons["lint.apply.0"].tap()
        XCTAssertFalse(element(app, "lint.issue.0").exists, "an applied issue leaves the list")
        app.buttons["lint.done"].tap()
        XCTAssertTrue(app.buttons["detail.card.0"].staticTexts["Linted fixture prompt"].waitForExistence(timeout: timeout), "the fix is applied to the card")
    }

    func testExpandAddsCards() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.card.0"].tap()
        let expand = app.buttons["card.ai.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: timeout))
        expand.tap()
        let add = app.buttons["card.ai.save"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout), "a preview of the new cards appears (F-27)")
        XCTAssertEqual(add.label, "Add 3")
        add.tap()
        app.buttons["card.done"].tap()
        XCTAssertTrue(app.buttons["detail.card.1"].staticTexts["Expanded prompt one"].waitForExistence(timeout: timeout), "new cards follow the expanded card")
        XCTAssertTrue(element(app, "detail.stat.cards").label.contains("9"))
    }

    func testRewriteAndExplainOnACard() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.card.0"].tap()
        let explain = app.buttons["card.ai.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: timeout))
        explain.tap()
        XCTAssertTrue(element(app, "card.ai.result").waitForExistence(timeout: timeout), "the explanation appears (F-23)")
        app.buttons["card.ai.save"].tap()
        XCTAssertTrue(element(app, "card.explanation").waitForExistence(timeout: timeout), "saved as the card's explanation")

        app.buttons["card.ai.rewrite"].tap()
        let simplify = button(app, id: "card.ai.rewrite.Simplify", label: "Simplify")
        XCTAssertTrue(simplify.waitForExistence(timeout: timeout))
        simplify.tap()
        XCTAssertTrue(app.buttons["card.ai.save"].waitForExistence(timeout: timeout))
        app.buttons["card.ai.save"].tap()
        XCTAssertTrue(app.staticTexts["Rewritten fixture prompt"].waitForExistence(timeout: timeout), "the card is replaced (F-28)")
    }

    // MARK: Phase 5: sources, queue, batch

    private func openGenerate(_ app: XCUIApplication, entry: String) {
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        app.buttons["library.addButton"].tap()
        let item = app.buttons[entry]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "\(entry) is in the Add menu")
        item.tap()
    }

    func testGenerateFromAWebPageKeepsTheArticle() {
        let app = launch()
        openGenerate(app, entry: "library.fromURL")
        let url = app.textFields["generate.url"]
        XCTAssertTrue(url.waitForExistence(timeout: timeout), "the web page source is pre-selected (F-3)")
        url.tap()
        url.typeText("https://en.wikipedia.org/wiki/Tiberius")
        app.buttons["generate.run"].tap()
        waitForGeneratedQuiz(app)
        openQuiz(app, named: "Fake Generated Quiz")
        let source = button(app, id: "detail.mode.source", label: "Read Source Materials")
        XCTAssertTrue(source.waitForExistence(timeout: timeout))
        source.tap()
        XCTAssertTrue(app.staticTexts["Fixture article"].waitForExistence(timeout: timeout), "the extracted article is kept")
        XCTAssertTrue(app.buttons["reader.originalPage"].exists, "with a link to the page")
    }

    func testAFailingPageCanBeRetriedOrRemoved() {
        let app = launch()
        openGenerate(app, entry: "library.fromURL")
        let url = app.textFields["generate.url"]
        XCTAssertTrue(url.waitForExistence(timeout: timeout))
        url.tap()
        url.typeText("https://fail.example/paywalled")
        app.buttons["generate.run"].tap()
        let status = element(app, "library.job.0.status")
        XCTAssertTrue(status.waitForExistence(timeout: timeout))
        for _ in 0..<40 where !status.label.contains("Paste the text") { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(status.label.contains("Paste the text instead"), "reader mode explains the failure: \(status.label)")
        XCTAssertTrue(app.buttons["library.job.0.retry"].exists)
        app.buttons["library.job.0.remove"].tap()
        XCTAssertFalse(element(app, "library.generating").waitForExistence(timeout: 2), "the queue is empty again")
    }

    func testBatchFromListMakesFiveQuizzesWhileStudyingAnother() {
        let app = launch(scenario: "slowGeneration")
        openGenerate(app, entry: "library.batch")
        let text = app.textViews["batch.text"]
        XCTAssertTrue(text.waitForExistence(timeout: timeout))
        text.tap()
        text.typeText((1...5).map { "https://example.com/page\($0)" }.joined(separator: "\n") + "\nnot a link")
        let add = app.buttons["batch.add"]
        XCTAssertEqual(add.label, "Add 5", "the bad line is skipped")
        add.tap()

        let generating = element(app, "library.generating")
        XCTAssertTrue(generating.waitForExistence(timeout: timeout))
        XCTAssertTrue(generating.label.contains("Generating (5)") || generating.label.contains("Generating (4)"), generating.label)

        // Study another quiz while the queue works.
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyRead"].tap()
        XCTAssertTrue(app.buttons["studyRead.next"].waitForExistence(timeout: timeout))
        app.buttons["studyRead.next"].tap()
        app.buttons["session.end"].tap()
        app.alerts.buttons["End"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let generated = app.staticTexts.matching(identifier: "Fake Generated Quiz")
        for _ in 0..<120 where app.staticTexts.matching(NSPredicate(format: "label == %@", "Fake Generated Quiz")).count < 5 {
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = generated
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Fake Generated Quiz")).count, 5, "five new quizzes")
        XCTAssertFalse(element(app, "library.generating").exists, "the queue drains")
    }

    // MARK: Phase 6: Quiz — Choice

    func testChoiceQuizOnTheMixedDeckEndToEnd() {
        let app = launch()
        openQuiz(app, named: "UITest Mixed Deck")
        let mode = app.buttons["detail.mode.quizChoice"]
        XCTAssertTrue(mode.waitForExistence(timeout: timeout), "a deck with choice cards offers Quiz — Choice")
        mode.tap()

        var overrodeOnce = false
        for card in 1...4 {
            let kind = app.staticTexts["choice.kind"]
            XCTAssertTrue(kind.waitForExistence(timeout: timeout), "card \(card)")
            switch kind.label {
            case "Multiple choice":
                let pick = overrodeOnce ? "Blue" : "Red"
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'choice.option.' AND label CONTAINS %@", pick)).firstMatch.tap()
                XCTAssertTrue(element(app, "choice.verdict").label.contains(overrodeOnce ? "Correct" : "Wrong"))
                if !overrodeOnce {
                    app.buttons["choice.override"].tap()
                    app.buttons["Correct"].firstMatch.tap()
                    XCTAssertTrue(element(app, "choice.verdict").label.contains("your call"), "the override is shown")
                    overrodeOnce = true
                }
                app.buttons["choice.next"].tap()
            case "Fill in the blank":
                let field = app.textFields["choice.blank.0"]
                field.tap()
                field.typeText("  BLUE ")
                app.buttons["choice.check"].tap()
                XCTAssertTrue(element(app, "choice.verdict").label.contains("Correct"), "case and spaces are ignored")
                app.buttons["choice.next"].tap()
            case "True or false":
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'choice.option.' AND label CONTAINS 'True'")).firstMatch.tap()
                XCTAssertTrue(element(app, "choice.verdict").label.contains("Correct"))
                app.buttons["choice.next"].tap()
            default:
                app.buttons["choice.reveal"].tap()
                XCTAssertTrue(app.buttons["choice.grade.correct"].waitForExistence(timeout: timeout))
                app.buttons["choice.grade.correct"].tap()
            }
        }
        XCTAssertTrue(app.staticTexts["summary.score"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["summary.score"].label, "100%", "the override counts")
        app.buttons["summary.done"].tap()
        XCTAssertTrue(element(app, "detail.stat.sessions").label.contains("1"))
    }

    func testRecallOnlyDecksHaveNoChoiceModeUntilACardIsConverted() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        XCTAssertTrue(app.buttons["detail.mode.quizVoice"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["detail.mode.quizChoice"].exists)
        app.buttons["detail.card.0"].tap()
        XCTAssertTrue(app.buttons["card.ai.rewrite"].waitForExistence(timeout: timeout))
        app.buttons["card.ai.rewrite"].tap()
        let convert = button(app, id: "card.ai.convert.multipleChoice", label: "Make multiple choice")
        XCTAssertTrue(convert.waitForExistence(timeout: timeout))
        convert.tap()
        XCTAssertTrue(app.buttons["card.ai.save"].waitForExistence(timeout: timeout))
        app.buttons["card.ai.save"].tap()
        app.buttons["card.done"].tap()
        XCTAssertTrue(app.buttons["detail.mode.quizChoice"].waitForExistence(timeout: timeout), "a converted card makes the deck playable as Choice")
    }

    // MARK: Phase 7: Due today, scheduling, insights

    func testDueTodayReviewsTheTwoDueCardsGroupedByQuiz() {
        let app = launch()
        let due = app.buttons["library.dueToday"]
        XCTAssertTrue(due.waitForExistence(timeout: timeout), "the Due today row shows (F-2)")
        XCTAssertTrue(due.label.contains("2 cards"), due.label)
        due.tap()
        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["choice.reveal"].waitForExistence(timeout: timeout), "recall cards flip in the review")
            app.buttons["choice.reveal"].tap()
            app.buttons["choice.grade.correct"].tap()
        }
        XCTAssertTrue(app.staticTexts["summary.score"].waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "summary.quiz.UITest Due Deck").exists, "the summary groups by quiz (F-41)")
        app.buttons["summary.done"].tap()
        XCTAssertTrue(app.buttons["library.addButton"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["library.dueToday"].waitForExistence(timeout: 2), "nothing is due after the review")
    }

    func testMostDueSortAndDueBadge() {
        let app = launch()
        XCTAssertTrue(app.buttons["library.sort"].waitForExistence(timeout: timeout))
        app.buttons["library.sort"].tap()
        button(app, id: "library.sort.mostDue", label: "Most due").tap()
        XCTAssertTrue(firstRowLabel(app).hasPrefix("UITest Due Deck"), firstRowLabel(app))
        XCTAssertTrue(element(app, "library.due").exists, "a due badge on the due deck")
    }

    func testInsightsShowsTheReportAndCreatesADrillDeck() {
        let app = launch()
        let insights = app.buttons["library.insights"]
        XCTAssertTrue(insights.waitForExistence(timeout: timeout))
        insights.tap()
        let headline = element(app, "insights.headline")
        XCTAssertTrue(headline.waitForExistence(timeout: timeout), "the fake report renders (F-43)")
        XCTAssertTrue(headline.label.contains("Fixture insights"))
        let create = app.buttons["insights.createDrill"]
        for _ in 0..<4 where !(create.exists && create.isHittable) { app.swipeUp() }
        create.tap()
        XCTAssertTrue(element(app, "insights.saved").waitForExistence(timeout: timeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Drill ·'")).firstMatch.waitForExistence(timeout: timeout), "the drill deck is in the library")
    }

    // MARK: Phase 8: tutor chat, oral exam, spoken hint

    func testTutorChatStreamsAReplyAndMakeCardsAddsThemToTheQuiz() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let cards = element(app, "detail.stat.cards")
        XCTAssertTrue(cards.waitForExistence(timeout: timeout))
        XCTAssertTrue(cards.label.contains("6"), cards.label)
        app.buttons["detail.chat"].tap()
        let starter = app.buttons["chat.starter.0"]
        XCTAssertTrue(starter.waitForExistence(timeout: timeout))
        starter.tap()
        let reply = element(app, "chat.message.1")
        XCTAssertTrue(reply.waitForExistence(timeout: timeout), "the fake reply streams in (F-30)")
        let makeCards = app.buttons["chat.makeCards"]
        XCTAssertTrue(makeCards.waitForExistence(timeout: timeout))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: makeCards)
        wait(for: [enabled], timeout: timeout)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Fixture tutor'")).firstMatch.exists)
        makeCards.tap()
        let add = app.buttons["chat.cards.add"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout), "the new cards open in a preview")
        add.tap()
        XCTAssertTrue(element(app, "chat.added").waitForExistence(timeout: timeout))
        app.buttons["chat.done"].tap()
        XCTAssertTrue(cards.waitForExistence(timeout: timeout))
        let nine = expectation(for: NSPredicate(format: "label CONTAINS '9'"), evaluatedWith: cards)
        wait(for: [nine], timeout: timeout)
    }

    func testTutorChatFromASessionShowsTheCurrentCard() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyRead"].tap()
        let prompt = element(app, "session.card.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout))
        let promptText = prompt.label
        app.buttons["session.chat"].tap()
        let card = element(app, "chat.card")
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "the chat knows the card it was opened from")
        XCTAssertEqual(card.label, promptText)
        XCTAssertTrue(app.buttons["chat.starter.0"].label.contains("Explain this card"))
        app.buttons["chat.done"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout), "the session is still there")
    }

    func testOralExamRunsFiveCardsWithFollowUpsAndRecordsTheSession() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let examRow = app.buttons["detail.mode.oralExam"]
        XCTAssertTrue(examRow.waitForExistence(timeout: timeout))
        examRow.tap()
        let start = app.buttons["oralExam.start"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        start.tap()
        XCTAssertTrue(element(app, "oralExam.question").waitForExistence(timeout: timeout))
        let followUp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fixture follow-up'")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: timeout), "the examiner asks a follow-up (F-45)")
        let recap = element(app, "summary.recap")
        XCTAssertTrue(recap.waitForExistence(timeout: 60), "five cards, two turns each, then grading")
        XCTAssertTrue(recap.label.contains("Fixture overall"), recap.label)
        XCTAssertTrue(element(app, "summary.count.correct").exists)
        app.buttons["summary.done"].tap()
        let sessions = element(app, "detail.stat.sessions")
        XCTAssertTrue(sessions.waitForExistence(timeout: timeout))
        XCTAssertTrue(sessions.label.contains("1"), "the exam was recorded: \(sessions.label)")
    }

    func testSayingHintInStudyVoiceRevealsTheHint() {
        let app = launch(extra: ["-voiceHint", "YES"])
        openQuiz(app, named: "UITest Deck")
        app.buttons["detail.mode.studyVoice"].tap()
        XCTAssertTrue(app.staticTexts["studyVoice.state"].waitForExistence(timeout: timeout))
        // The UI-test hint listener always hears "hint"; the first card with a hint reveals it.
        XCTAssertTrue(element(app, "session.card.hint").waitForExistence(timeout: 30), "saying hint reveals the hint (F-12)")
        app.buttons["studyVoice.pause"].tap()
    }

    // MARK: Anki (F-62)

    func testAnAnkiDeckImportsAsQuizzesWithASummary() {
        let app = launch(extra: ["-UITestAnkiImport", "anki-latest"])
        let summary = element(app, "anki.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: timeout), "the import sheet reads the deck")
        XCTAssertEqual(summary.label, "2 quizzes, 9 cards")
        XCTAssertTrue(element(app, "anki.quiz.0").exists)
        XCTAssertTrue(element(app, "anki.skipped").exists || app.staticTexts["1 image left out"].exists, "media is reported as left out")
        app.buttons["anki.done"].tap()
        XCTAssertTrue(app.staticTexts["Spanish › Verbs"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Geography"].exists)
    }

    func testTheAddMenuOffersAnkiImport() {
        let app = launch()
        let add = app.buttons["library.addButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let anki = button(app, id: "library.importAnki", label: "Import Anki deck")
        XCTAssertTrue(anki.waitForExistence(timeout: timeout))
        anki.tap()
        let appeared = app.buttons["Cancel"].waitForExistence(timeout: timeout) || app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, "the document picker opens")
    }

    func testExportToAnkiOpensTheFileExporter() {
        let app = launch()
        openQuiz(app, named: "UITest Deck")
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        more.tap()
        let export = button(app, id: "detail.exportAnki", label: "Export to Anki")
        XCTAssertTrue(export.waitForExistence(timeout: timeout))
        export.tap()
        let picker = app.buttons["Move"].exists ? app.buttons["Move"] : app.navigationBars.buttons["Save"]
        let appeared = picker.waitForExistence(timeout: timeout)
            || app.buttons["Save"].waitForExistence(timeout: 2)
            || app.buttons["Cancel"].waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, "the file exporter appears with the .apkg")
    }
}
