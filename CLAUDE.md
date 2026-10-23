# CLAUDE.md — working on AIQuiz

Read this before touching the code. `SPEC.md` is the behaviour contract, `PLAN.md` is the order of work and the test bar, `REVIEW.md` is the rationale, `known_issues.md` is the list of traps.

## What this is
Native iPad/iPhone flashcard app. SwiftUI + SwiftData, Swift 6 strict concurrency, iOS 26 minimum (after PLAN Phase 0). Project is generated from `Project.yml` with XcodeGen; never hand-edit `AIQuiz.xcodeproj`.

## Build, run, test

Regenerate the project after any change to `Project.yml` or when files are added/removed:
```bash
xcodegen
```

Simulator to use: **iPad Pro 13-inch (M5), iOS 26.5**, UDID `D62334E0-1BBB-4781-A549-36CFD4B56907`. Layout checks also on `iPhone 17 Pro`. Find others with `xcrun simctl list devices available`.

Build for the simulator:
```bash
xcodebuild -project AIQuiz.xcodeproj -scheme AIQuiz -destination 'platform=iOS Simulator,id=D62334E0-1BBB-4781-A549-36CFD4B56907' -configuration Debug build
```

Run all tests (packages first, then app + UI tests on the simulator). Exists after Phase 0:
```bash
scripts/test.sh
```

Package tests alone (fast, macOS):
```bash
swift test --package-path Packages/AIQuizCore
```
```bash
swift test --package-path Packages/LLMKit
```

Live API tests (spend real money, a few cents a run; never in CI). Keys live in the macOS login Keychain under `AIQuiz_Ant_test_key` and `AIQuiz_Oai_test_key`; the script reads them, never prints them, and skips a provider whose key is missing. OpenAI also needs a chat model because none is hardcoded:
```bash
scripts/live-test.sh
```
Defaults are `claude-sonnet-5-5` and `gpt-6-luna` (owner's choice); override with `-m <openai-model>` or `AIQuiz_Ant_test_model=<model>`.
The owner stores the keys; agents never ask for them, read them, or type them anywhere. Run the live tests at the end of any phase that changes `Packages/LLMKit` or a client.

App tests alone:
```bash
xcodebuild test -project AIQuiz.xcodeproj -scheme AIQuiz -destination 'platform=iOS Simulator,id=D62334E0-1BBB-4781-A549-36CFD4B56907' -only-testing:AIQuizTests
```

Deploy to the owner's iPad (connected over USB, UDID `00008103-0001194C0107001E`, iPadOS 26.6):
```bash
scripts/deploy.sh
```
Then launch it:
```bash
xcrun devicectl device process launch --device 00008103-0001194C0107001E com.jaimerodriguez.aiquiz
```

## Driving the simulator yourself
Use the iOS Simulator MCP tool: `attach` to the UDID above, `build`/`build_status`, then `launch` with the `.app` path it returns, then `screenshot` / `tap` / `swipe` / `text`. Coordinates are in points (1032×1376 on this iPad). Take a screenshot before every tap; screenshots are 2× the point size. Launch with `-UITestMode` (after Phase 0) for deterministic data and a fake AI endpoint. Tap and screenshot sequentially, not in the same batch, or the screenshot may precede the tap.

Device and simulator logs:
```bash
xcrun simctl spawn D62334E0-1BBB-4781-A549-36CFD4B56907 log show --last 5m --predicate 'process == "AIQuiz"' --style compact
```
Back up or inspect the iPad's library (read-only) by copying `default.store`, `default.store-wal` and `default.store-shm` from `Library/Application Support` with `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.jaimerodriguez.aiquiz`. Copy all three, and only after the app has opened its library (check that the files' modification time is after launch): a copy taken before or during a SwiftData migration shows the old columns or zero rows. Open a copy with `sqlite3`, never the originals. Back up before any change to a `@Model`, and compare quiz and card counts after deploying.

Crash reports from the iPad: Xcode → Window → Devices and Simulators → View Device Logs, or `~/Library/Developer/Xcode/DeviceLogs/`.

Voice capture (microphone + speech recognition) is only trusted on the physical iPad. The simulator is fine for everything else.

XCUITest gotchas seen in this project:
- On iPad, form sheets (Generate quiz) are short and the keyboard shortens them further. `tap()` on an element below the fold does nothing and raises no error. Scroll first; `AIQuizUITests.scrollGenerateForm` drags on a static text in the form until the target is hittable. Never drag on a text field (it starts text selection).
- A failing `waitForExistence` right after a tap usually means the tap did not land, not that the view is missing.
- Tap through typed queries (`app.buttons["id"]`). `descendants(matching: .any)["id"]` can match a wrapper and its child; use `.matching(identifier:).firstMatch` for assertions only.
- A SwiftUI `Label` with an identifier exposes the icon as its first match (label "Warning", "Selected"). Add `.accessibilityElement(children: .combine)` before the identifier when a test reads the text.
- A `Menu` in a `Form` row only opens when its label content is hit; XCUITest taps the row's centre. Give the menu label `.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`.
- XCUITest throws if a query string (identifier or label) is longer than 128 characters. Match long labels with `NSPredicate(format: "label BEGINSWITH %@", prefix)`.
- To read why a UI test failed, export the xcresult attachments: `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`; the `.txt` files hold the element hierarchy at failure.
- Test bundles need `GENERATE_INFOPLIST_FILE: YES` in `Project.yml`; the app target sets it to NO.
- `scripts/test.sh` runs under macOS bash 3.2: expand optional arrays as `${ARR[@]+"${ARR[@]}"}` with `set -u`.
- Rows of a `List` or `Form` that are off screen do not exist for XCUITest. Put anything a test must find near the top, or swipe on a static text until it is hittable.
- `Text("\(number)")` localizes the number (`1,177`). Use `Text(verbatim:)` for values a test parses.
- A `confirmationDialog` button's identifier matches twice; tap `app.buttons.matching(identifier:).firstMatch`.

SwiftData gotchas seen in this project:
- `#Predicate` cannot force-unwrap. Write `(card.dueAt ?? distantPast) <= now` with `distantPast` captured as a local.
- The schemas in `AIQuiz/Models/Schema/` are frozen once shipped. A model change means a new `SchemaVn`, a stage in `AIQuizMigrationPlan`, and a test that opens the previous shape (ADR-014).
- To prove a migration against the owner's real data, copy the iPad store (see below) and run `TEST_RUNNER_AIQUIZ_REAL_STORES=<folder>[:<folder>] ONLY=AIQuizTests/MigrationTests scripts/test.sh`.

## Visual design (SPEC N-9, ADR-016)
- One accent color (`AccentColor`, blue). Use it for the single primary action on a screen (`primaryActionStyle()`, disabled and grey until it can run) and for feature icons (`AccentIcon`). Nowhere else.
- Red, orange and green only when they mean something: destructive, recording, Wrong / Partial / Correct.
- Explain with icons and tiles, not paragraphs. Use `Theme` radii and readable width.
- iOS 26 toolbars render buttons as monochrome glass; a toolbar `Menu` ignores button styles. For an accent toolbar control, draw it and hide the shared background (see the library's add button).
- Check every changed screen on iPad Pro 13-inch and iPhone 17 Pro, and put both in the PR.

## Change tracking 
1. For major features, while in development. Keep a Changelog 1.1.0, date-stamped records in `CHANGELOG.md`
2. Document all decisions and feature chagnes as we go. keep track of these in SPEC.md as Change requests.   
3. Keep major architecture decisions in a `DECISIONS.md` file; document conversation with owner, the trade-offs asssessed, and the final decision. 


## Definition of done for any task
1. Builds with zero warnings.
2. Tests added at the layers `PLAN.md` §1 names for that task, all green.
3. The phase checklist in `PLAN.md` run on the simulator with screenshots in the PR.
4. Audio changes verified on the iPad; device log clean.
5. `SPEC.md` / `PLAN.md` status updated. New controls get accessibility identifiers (`screen.element`) and are listed in SPEC §12.


## Code rules
- Swift 6 strict concurrency stays on. No `@unchecked Sendable` except the two boxes in `STTService` (see `known_issues.md`); no `nonisolated(unsafe)`.
- No new singletons. Dependencies come through `init` or `@Environment`. `.shared` is allowed only at the composition root in `AIQuizApp`.
- Views are dumb; state machines live in `@Observable` players/models that take protocols (`LLMClient`, `SpeechSynthesizing`, `SpeechRecognizing`).
- Non-UI logic goes in `Packages/AIQuizCore` or `Packages/LLMKit` so it is testable with `swift test`.
- Third-party dependencies: `SwiftSoup` only. Ask before adding another.
- Never log transcripts, source text or keys outside the opt-in debug file sink. Never show HTTP bodies to users.
- Audio: only `AudioSessionCoordinator` touches `AVAudioSession` (after Phase 8). Closures that run on audio threads or recogniser callbacks are typed `@Sendable` and capture only Sendable boxes.
- Prompts live in `AIQuizCore/Prompts/`, one file per feature, with a version comment. Every structured feature has a `JSONSchema` and a `Decodable` output type.

## AI provider facts (do not guess; these were verified 2026-10-22)
- Anthropic: `POST /v1/messages`, header `anthropic-version: 2026-10-21`. Current models reject `temperature`, `top_p`, `top_k` and assistant-message prefill with HTTP 400. JSON output goes through `output_config: { format: { type: "json_schema", schema } }`; depth through `output_config.effort` (`low`/`medium`/`high`). Default model id `claude-opus-5-5`; `claude-haiku-5-5` is the cheap option. Streaming is SSE with `content_block_delta` / `text_delta`.
- OpenAI and every OpenAI-compatible server (Ollama, LM Studio, llama.cpp, vLLM, OpenRouter): `POST {baseURL}/chat/completions`, `response_format` with `json_schema` (strict) when supported, `GET {baseURL}/models` to list models. Do not hardcode an OpenAI model name.
- Apple on-device: `FoundationModels.LanguageModelSession`, ~4k token context, JSON-in-text for now.
- Keys are Keychain-only. UI-test mode uses `FakeLLMClient`; live API tests run only with `AIQUIZ_LIVE_TESTS=1`.

## Git
- **Integration branch is `claude`.** Nothing Claude produces is committed to `main` directly. Every milestone/phase gets its own branch cut from `claude` (`phase-N-short-title`) and merges back into `claude` via PR. Merging `claude` into `main` is the owner's call.
- One PR per phase unless the plan says otherwise.
- Commit messages: imperative, first line ≤ 72 chars, body explains why. When Claude wrote it, end with a `Co-Authored-By: Claude <model name> <noreply@anthropic.com>` line naming the model that actually did the work (for example `Claude Opus 5.5`).
- Never commit `build/`, `build-device/`, `*.ips`, `debug.log` (already in `.gitignore`).

## Owner context
Jaime uses the app daily on the iPad; the library on that device must survive every schema change (PLAN Phase 2 backs up and migrates). Phone is an iPhone on iOS 26.7. API keys for Anthropic and OpenAI are entered by Jaime on the device, never in source or fixtures.
