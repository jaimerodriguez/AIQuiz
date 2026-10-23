import XCTest

/// UI flows under `-UITestMode` (PLAN §1.3, §1.5). Uses accessibility identifiers from SPEC §12 only.
final class AIQuizUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() {
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
        let open = app.buttons["generate.openLibrary"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        openQuiz(app, named: "Fake Generated Quiz")
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
        let open = app.buttons["generate.openLibrary"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()

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

    // MARK: Library and card management (PLAN Phase 2)

    private func longPress(_ app: XCUIApplication, quiz name: String) {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "quiz row \(name) not found")
        row.press(forDuration: 1.2)
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

        let search = app.searchFields.firstMatch
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

        let search = app.searchFields.firstMatch
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
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["onboarding.addEndpoint"].exists)
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout), "the library shows; samples were seeded regardless")
    }

    func testOnboardingSkipAndAddEndpointNow() {
        var app = launch(extra: ["-UITestOnboarding"])
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: timeout))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.staticTexts["UITest Deck"].waitForExistence(timeout: timeout))
        app.terminate()

        app = launch(extra: ["-UITestOnboarding"])
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: timeout))
        app.buttons["onboarding.next"].tap()
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.buttons["onboarding.addEndpoint"].waitForExistence(timeout: timeout))
        app.buttons["onboarding.addEndpoint"].tap()
        XCTAssertTrue(button(app, id: "endpoints.add", label: "Add endpoint").waitForExistence(timeout: timeout), "the endpoint list opens")
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
        var skips = 0
        while !hint.isEnabled && skips < 5 {
            app.buttons["studyVoice.skip"].tap()
            skips += 1
        }
        app.buttons["studyVoice.pause"].tap()
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
}
