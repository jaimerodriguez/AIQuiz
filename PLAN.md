# AIQuiz v2 — Implementation plan

Companion to `SPEC.md` (v2) and `REVIEW.md`. Written for implementing agents. Read `CLAUDE.md` first for build, test and verification commands.

How to use this document:
- Work phase by phase, in order. Each phase is one PR (or a small series) and ends with the app in a releasable state.
- Every task lists the SPEC IDs it implements, the files it touches, the tests it must add, and its acceptance criteria. A task is done only when all four are satisfied and the verification checklist at the end of the phase passes.
- Update the status table in §0 as you go. Do not reorder phases without recording why in the §0 decision log.

---

## 0. Status and decisions

| Phase | Title | Status | PR |
|---|---|---|---|
| 0 | Test scaffolding and packages | merged into `claude` | jaimerodriguez/AIQuiz#2 |
| 1 | LLMKit foundation and endpoint settings | merged into `claude` | jaimerodriguez/AIQuiz#3, landed by jaimerodriguez/AIQuiz#6 |
| — | Original content and Read Source Materials (CR-007, CR-008) | merged into `claude` | jaimerodriguez/AIQuiz#4, landed by jaimerodriguez/AIQuiz#6 |
| 2 | Schema v2 and migration | merged into `claude` | jaimerodriguez/AIQuiz#5 |
| 3 | Session UI consolidation and v1 drift fixes | merged into `claude` | jaimerodriguez/AIQuiz#7 |
| 4 | AI grading, explanations, hints, lint | in review; accepted on the iPad 2026-10-23 | jaimerodriguez/AIQuiz#8 |
| 5 | Ingestion: notes, PDF, reader mode, photo, share | in review | phase-5-ingestion (merge after #8) |
| 6 | Card types and the Choice player | not started | |
| 7 | FSRS scheduling, Due today, notifications, insights | not started | |
| 8 | Audio coordinator, tutor chat, oral exam | not started | |

Decisions already taken (change only with the owner's agreement):

- **D-1** Minimum OS raised to iOS 26.0 (all target devices run 26.x). Removes `#available` guards around FoundationModels and allows `SpeechAnalyzer`.
- **D-2** Hand-rolled LLM layer; no vendor SDKs. `SwiftSoup` is the only third-party dependency, added in Phase 5.
- **D-3** Anthropic default model `claude-opus-5-5`. No OpenAI model is hardcoded; the user picks from `GET /models`.
- **D-4** Local Swift packages (`Packages/AIQuizCore`, `Packages/LLMKit`) hold all non-UI logic so `swift test` runs on macOS.
- **D-5** Deterministic UI-test mode (`-UITestMode` launch argument) with an in-memory store, seeded fixtures and a scripted fake endpoint. Both XCUITests and the agent's simulator runs use it.
- **D-6** Voice capture is verified on the physical iPad only. The simulator verifies everything else.

---

## 1. Testing strategy (applies to every phase)

Four layers. A phase is not complete until all four that apply are green.

### 1.1 Package unit tests (macOS, seconds)
`swift test --package-path Packages/AIQuizCore` and `... Packages/LLMKit`. Pure logic: parsers, prompts, schemas, FSRS, deck ordering, wire-format encoding/decoding, SSE parsing, retry policy, chunking. HTTP is stubbed with a `URLProtocol` subclass that serves recorded fixtures from `Packages/LLMKit/Tests/Fixtures/`. Target: every public function has at least one test; every bug fixed gets a regression test.

### 1.2 App unit tests (`AIQuizTests`, simulator)
XCTest target in the app. SwiftData migrations (open a v1 store, migrate, assert), `AIRouter` persistence, players driven with `FakeSpeech*` and `FakeLLMClient`, view models. Run with `xcodebuild test -only-testing:AIQuizTests`.

### 1.3 UI tests (`AIQuizUITests`, simulator)
XCUITest driving the app launched with `-UITestMode`. Covers each user-visible flow in the spec once: import, generate with the fake endpoint, each mode end to end, settings, endpoint add/test, review session, chat. Uses accessibility identifiers from SPEC §12 only; never coordinates. Run on `iPad Pro 13-inch (M5)` and once per phase on `iPhone 17 Pro` to catch layout breaks.

### 1.4 Agent verification (simulator + device)
After the automated suites pass, the implementing agent drives the simulator through the phase checklist with the Simulator MCP tool, takes screenshots at each step, and attaches them to the PR description. Voice features are then deployed to the iPad with `scripts/deploy.sh` and checked by the agent as far as possible (launch, navigate, confirm no crash in device logs) and by the owner for actual speech.

### 1.5 UI-test mode contract (implemented in Phase 0)
Launch argument `-UITestMode` makes the app:
- use an in-memory `ModelContainer`;
- seed the three bundled samples plus a fixture quiz `UITest Mixed Deck` with every card kind and pre-set scheduling state (2 due, 2 new, 2 future);
- register one endpoint named `Fake` of kind `fake` whose client replays responses from `AIQuiz/Resources/TestFixtures/*.json` keyed by purpose, with a 300 ms artificial delay and a scripted stream for summary/chat;
- route every purpose to `Fake`;
- skip onboarding;
- disable notifications scheduling.
Additional arguments: `-UITestScenario <name>` selects alternative fixture sets (e.g. `endpointError`, `malformedJSON`, `emptyLibrary`, `largeLibrary`). `largeLibrary` generates 120 quizzes × 40 cards × 15 sessions in the in-memory store (synthetic text, deterministic seed) and is the fixture for every performance assertion (SPEC N-8).

### 1.6 Live tests (opt-in)
`scripts/live-test.sh` reads `AIQuiz_Ant_test_key` and `AIQuiz_Oai_test_key` from the macOS login Keychain and sets `AIQUIZ_LIVE_TESTS=1`, enabling a small suite in `LLMKit` that hits the real APIs once per client (complete, stream, structured). Never run in CI by default. Run before merging Phase 1 and whenever a wire format changes.

---

## 2. Phases

### Phase 0 — Test scaffolding and packages
Goal: make everything after this testable. No user-visible change.

**Tasks**
1. Raise deployment target to iOS 26.0 in `Project.yml` (D-1). Remove `#available(iOS 26.0, *)` guards and `canImport(FoundationModels)` conditionals that become unconditional.
2. Create `Packages/AIQuizCore` (targets `AIQuizCore`, `AIQuizCoreTests`) and `Packages/LLMKit` (targets `LLMKit`, `LLMKitTests`). Move into `AIQuizCore`: `Quiz.swift` (payload types + decoder), `SessionDeck`, `PromptBuilder` → `Prompts/`, `LLMResponseParser`, `CardVerdict`/`CardOutcome`/`SessionMode` (as plain enums; SwiftData models stay in the app). Keep public API minimal and documented.
3. Add to `Project.yml`:
   ```yaml
   packages:
     AIQuizCore: { path: Packages/AIQuizCore }
     LLMKit:     { path: Packages/LLMKit }
   targets:
     AIQuiz:
       dependencies:
         - package: AIQuizCore
         - package: LLMKit
     AIQuizTests:
       type: bundle.unit-test
       platform: iOS
       sources: [Tests/AIQuizTests]
       dependencies: [{ target: AIQuiz }]
     AIQuizUITests:
       type: bundle.ui-testing
       platform: iOS
       sources: [Tests/AIQuizUITests]
       dependencies: [{ target: AIQuiz }]
   schemes:
     AIQuiz:
       build: { targets: { AIQuiz: all } }
       test: { targets: [AIQuizTests, AIQuizUITests] }
   ```
4. Delete `ExceptionCatcher.h/.m`, the bridging header, and `SWIFT_OBJC_BRIDGING_HEADER`.
5. Implement UI-test mode (§1.5): `AppEnvironment` built in `AIQuizApp.init` from `ProcessInfo.arguments`; in-memory container; fixtures folder; `FakeLLMClient` in `LLMKit` (public, so previews use it too).
6. Add accessibility identifiers from SPEC §12 to every existing control.
7. Inject `AppSettings` and the provider registry through `.environment(...)`; replace all `.shared` reads in views with `@Environment`. Keep `.shared` only at the composition root.
8. Write `scripts/test.sh` (runs package tests, then `xcodebuild test` on the iPad Pro simulator) and `scripts/build-sim.sh`.
9. Replace `DebugLog` with `os.Logger` wrappers (`Log.ai`, `Log.audio`, `Log.data`); keep the file sink behind S-14 (implemented in Phase 3; for now a constant `false`).

**Tests**: `AIQuizCoreTests`: `CardPayload` decoding (underscore, hyphen, missing key, extra keys), `LLMResponseParser` (fenced, nested, prose-wrapped, none), `SessionDeck` transitions. `AIQuizUITests`: `testLibraryShowsSeededQuizzes`, `testStudyReadFlipAndNext`, `testQuizVoiceShowAnswerAndGrade` (the flow verified manually on 2026-10-22).

**Acceptance**: `scripts/test.sh` green; app behaves exactly as before; zero compiler warnings (fix the `try?` warning in the old `DebugLog` along the way).

**Checklist (simulator)**: launch with `-UITestMode`, screenshot library (3 samples + `UITest Mixed Deck`), open Roman Emperors → Quiz voice → Show answer → Correct → card 2.

---

### Phase 1 — LLMKit foundation and endpoint settings
Implements SPEC §7.2–7.5, §8 (S-1, S-2, S-16). Fixes the broken Claude path.

**Tasks**
1. `LLMKit` public types: `LLMEndpoint`, `ChatRequest`, `ChatMessage`, `ContentPart`, `JSONSchema` (a small Codable schema builder with `object(properties:required:)`, `array(of:)`, `string(enum:)`, `integer`, `boolean`; always emits `additionalProperties: false`), `ChatResponse`, `TokenUsage`, `StopReason`, `ChatEvent`, `LLMError`, `Effort`.
2. `protocol LLMClient` with `complete`, `stream`, `listModels`. Extension `run<T: Decodable>(_ task: StructuredTask<T>)` with one retry carrying the decoder error.
3. `HTTPClient`: `URLSession` wrapper with timeouts, retry/backoff honouring `Retry-After`, typed error mapping, cancellation. `SSEParser` as an `AsyncSequence` over `URLSession.bytes`.
4. `AnthropicClient` per SPEC §8.4. Headers, `output_config.format` + `effort`, no `temperature`, no prefill, SSE events. `listModels` → `GET /v1/models`.
5. `OpenAICompatibleClient` per SPEC §8.4 with the three-step `response_format` fallback and `supportsJSONSchema` learning (reported back through a delegate closure the router persists).
6. `AppleOnDeviceClient` wrapping `LanguageModelSession`; text only; `listModels` returns `["apple-on-device"]`.
7. `FakeLLMClient` (from Phase 0) gains scripted streaming and error injection.
8. `AIRouter` (app target, `@Observable @MainActor`): endpoints list + routing map persisted in UserDefaults as JSON; keys via `KeychainStore`; `client(for purpose:)` with fallback; usage accumulation (S-16); migration from v1 `ProviderRegistry` defaults (if an OpenAI or Anthropic key exists in the Keychain, create the matching endpoint and route everything to it).
9. Use cases in `AIQuizCore`: `QuizGenerator`, `AnswerJudge` rewritten against `LLMClient` + `StructuredTask`. Delete `OpenAIProvider`, `ClaudeProvider`, `AppleFoundationProvider`, `LLMProvider`, `ProviderRegistry`.
10. Settings UI: `EndpointsListView`, `EndpointEditView` (presets, fields, Test button with model picker, cost fields), `RoutingView`, `UsageView`. Lazy-setup sheet reused by Generate and Quiz.
11. `Info.plist`: `NSAllowsLocalNetworking` under ATS, `NSLocalNetworkUsageDescription`.

**Tests**
- `LLMKitTests`: request encoding golden tests for both wire formats (compare JSON against fixtures); response decoding (text, usage, stop reasons, error statuses); SSE parsing for both formats including split chunks and `[DONE]`; retry policy (429 then 200, 500 ×3 then failure, `Retry-After` honoured); `response_format` fallback ladder; `StructuredTask` retry-with-error; `JSONSchema` builder output; cancellation stops the stream.
- `AIQuizCoreTests`: `QuizGenerator` and `AnswerJudge` with `FakeLLMClient` (happy path, malformed-then-valid, twice-malformed).
- `AIQuizTests`: `AIRouter` persistence round-trip, v1 key migration, fallback selection, usage totals.
- `AIQuizUITests`: add endpoint (Custom, fake base URL served by the test's in-process server or `FakeLLMClient`), Test shows models, route generation, generate topic quiz appears in library; endpoint error scenario shows friendly message.
- Live tests (§1.6) against Anthropic and OpenAI once.

**Acceptance**: generating a quiz and judging an answer work against Anthropic (live), OpenAI (live), Ollama on the LAN (manual, document in PR), and Apple on-device (device). Old provider files deleted. No `temperature`/prefill anywhere.

**Checklist**: Settings → AI endpoints → Add Anthropic → paste key (owner does this on device) → Test lists models → Generate "Roman emperors" 10 cards → library shows it → Quiz voice → Show answer → Ask AI to judge returns a verdict.

---

### Phase 2 — Schema v2 and migration
Implements SPEC §3, D-10. No new UI except what is needed to show new fields.

**Tasks**
1. `SchemaV0` (v0.1) and `SchemaV1` (exact copy of today's models; both shapes exist on devices, ADR-014) and `SchemaV2` (SPEC §3) as `VersionedSchema`s; `AIQuizMigrationPlan` with a lightweight stage where possible and a custom stage for defaults (`kind = recall`, `sourceKind` derived from `bundledSampleId`/`sourceBookmark`, `createdAt = importedAt`, scheduling fields zero/nil).
2. Container creation uses the plan. On migration failure: log, back up the store file with a timestamp, recreate empty, show a one-time alert ("Library could not be migrated; a backup was kept at …").
3. Update `FileImportService` (now `QuizImporter` enum, no actor) and `SampleQuizzes` to fill new fields. Decode/encode `kind`, `options`, `explanation`, `mnemonic`, `description`, `tags`, `language` (SPEC §2).
4. Card sheet (F-9) with Edit and Delete; quiz Rename / Edit tags / Archive / Export JSON (F-4); library sort menu, archived section, tag chips (F-1). Due badge, *Most due* and multi-select are deferred (CR-009).
5. Stored counters (D-11): `QuizStats.refresh`, called from every write path listed in SPEC §3 and from a foreground hook; `#Index` on `CardRecord.dueAt` and `SessionRecord.startedAt`; `tagsSearch` maintained on rename/tag edit; `summaryMarkdown` as external storage. Library rows and Due today read only stored fields (SPEC N-8). Migration stage fills the counters for existing quizzes.

**Tests**
- `AIQuizTests`: build a V1 store on disk with fixtures, open with the plan, assert every record and field; idempotent re-open; corrupt store path triggers backup + fresh store.
- `AIQuizTests` (performance, `largeLibrary`): `measure` blocks for library fetch sorted by `lastStudiedAt` (< 50 ms), Due today `fetchCount` (< 100 ms), `QuizStats.refresh` for one 300-card quiz (< 20 ms); a grep-style test that fails if any view under `Library/` references `.cards` or `.sessions` of a `QuizRecord`.
- `AIQuizUITests` (`largeLibrary`): cold launch to first library row under 1.5 s; scroll to bottom and back with no dropped-frame assertion failures (use `XCTOSSignpostMetric.scrollDecelerationMetric`); sort and search respond within 300 ms.
- `AIQuizCoreTests`: payload round-trip with new fields; hyphen keys still accepted; `kind` validation (MCQ without options is an error with a clear message).
- `AIQuizUITests`: edit a card, rename a quiz, export JSON (file exporter appears).

**Acceptance**: the owner's real iPad library migrates with no data loss (deploy a build, open, check counts and history). Document the counts before/after in the PR.

---

### Phase 3 — Session UI consolidation and v1 drift fixes
Implements F-5, F-13 unchanged, F-18 practice missed, S-5, S-14, S-15, F-60, REVIEW §4.4.

**Tasks**
1. Extract `CardFaceView`, `SessionProgressHeader`, `.endSessionConfirmation`, `.swipeToNavigate`; use `HintButton` everywhere.
2. `StudyReadPlayer` so all modes are view + player. Players take `SpeechSynthesizing` / `SpeechRecognizing` protocols (F-51) and the deck; introduce the protocols now with Apple implementations (coordinator comes in Phase 8).
3. Wire *Practice missed cards* in every mode; its session is recorded.
4. Source-missing badge + Re-link (F-5).
5. Settings: STT language (S-5), debug logging toggle with file sink (S-14), privacy clears (S-15), reading-size unchanged.
6. Onboarding (F-60).
7. Library search (F-1 search only; due badge comes in Phase 7).

**Tests**
- `AIQuizTests`: each player with fake speech (start, pause, resume, skip, back, repeat, end, abandon); practice-missed deck contains exactly the wrong/partial cards; re-link replaces bookmark.
- `AIQuizUITests`: onboarding appears once; each mode end to end; practice missed; privacy clears empty the library in `emptyLibrary` scenario.

**Acceptance**: the three modes look and behave as before on iPad and iPhone; code for the three views shrinks (report line counts in PR).

**Checklist**: run all three modes on the simulator; on the iPad run Study voice (hear TTS) and Quiz voice (live transcript) once.

---

### Phase 4 — AI grading, explanations, hints, lint
Implements F-15, F-16, F-23, F-24, F-25, F-26, F-27, F-28, F-29, F-44, S-3.

**Tasks**
1. Use cases in `AIQuizCore`: `Explainer` (F-16, F-23), `HintGenerator` (F-24), `MnemonicGenerator` (F-25), `DifficultyRater` (F-26, batched 20 cards per call), `CardExpander` (F-27), `CardRewriter` (F-28), `CardLinter` (F-29), `SessionRecapper` (F-44). Each: prompt file, output type, schema, one function.
2. Auto-grade in `QuizVoicePlayer`: on final transcript, if S-3 and a grading client exists, call `AnswerJudge` in a child task; show verdict chip; pre-select grade; record both verdicts; cancel on advance.
3. Silence auto-stop (2 s after final transcript) in the voice quiz.
4. Card sheet actions (F-9) and Lint toolbar action with an issues list that offers "Apply fix" per issue.
5. Session summary recap (F-44) requested in the background.
6. Outcome model carries `aiVerdict`, `aiReason`, `userOverrode`; detail "recent sessions" shows them.

**Tests**
- `AIQuizCoreTests`: every use case with `FakeLLMClient` fixtures, including schema violations.
- `AIQuizTests`: `QuizVoicePlayer` auto-grade state machine with a fake client that resolves late / errors / is cancelled by advance.
- `AIQuizUITests`: quiz voice with fake endpoint shows AI verdict chip and allows override; why-wrong appears; lint lists issues; expand adds cards.

**Acceptance**: a full quiz session with auto-grade on the iPad against Anthropic produces sensible verdicts; errors never block grading (self-grade always works).

---

### Phase 5 — Ingestion: notes, PDF, reader mode, photo, share

> **Partly delivered early (CR-007):** quizzes keep their original content (page link, file bookmark, pasted text) and show it on the quiz screen. AI study notes (F-20) are on hold at the owner's request. Phase 5 still owns PDF and photo sources, reader-mode extraction, chunking, the share extension and the generation queue.
Implements F-3, F-19 sources, F-20, F-21, F-22, S-4, §7.4 chunking.

**Tasks**
1. `ContentExtractor` rewritten: `ReaderModeExtractor` (SwiftSoup, SPEC §6 F-21 rules, User-Agent), `PDFTextExtractor` (PDFKit + Vision OCR fallback per page), `ImageTextExtractor` (Vision), `MarkdownLoader`. All off main actor, cancellable, with progress.
2. `Summarizer` use case (streaming) and `Chunker` (§7.4) in `AIQuizCore`.
3. `GenerateQuizModel` (`@Observable`) owning the pipeline: phases, cancellation, errors, result. `GenerateQuizView` becomes a form over it with the progress sheet.
4. Add-menu entries and source pre-fill (F-3). Document scanner (VisionKit) for Photo. Clipboard offer.
5. Share extension target `AIQuizShare` + App Group `group.com.jaimerodriguez.aiquiz`; inbox folder; main app drains inbox on launch and on foreground.
6. Regenerate from source (F-4).
7. Generation queue (F-61): `GenerationQueue` actor in the app target (serial, persistent `GenerationJob` JSON in Application Support, resume on launch, cancel/retry), `GeneratingRow` in the library with an expandable job list, *Batch from list* entry, local notification on completion in background. `GenerateQuizModel` from task 3 becomes the job runner; the Generate screen only builds and enqueues a job.

**Tests**
- `AIQuizCoreTests`: `Chunker` boundaries; `Summarizer` streaming assembly; reader-mode extraction on 6 saved HTML fixtures (Wikipedia, a blog, a news site with nav, a paywalled stub, a page with no article, a non-UTF-8 page) asserting the expected first/last paragraphs and absence of nav text.
- `AIQuizTests`: `GenerateQuizModel` phase sequence with fakes; cancellation mid-summary leaves no quiz; share inbox drain creates the right source.
- `AIQuizUITests`: generate from URL (fake extractor via scenario), generate from paste with notes streaming visible, notes tab on detail, skip-notes toggle.

- `AIQuizTests`: `GenerationQueue` runs jobs serially, persists pending jobs, resumes after a simulated relaunch, cancels a running job cleanly, retries a failed one; 10 queued jobs with `FakeLLMClient` complete in order and each produces one quiz with counters filled.
- `AIQuizUITests`: *Batch from list* with 5 URLs (fake extractor) shows *Generating (5)*, counts down, and the library ends with 5 new quizzes while the user opens and plays another quiz mid-way.

**Acceptance**: generate from a real Wikipedia URL, a real PDF, and a scanned photo on the iPad; share a Safari page to AIQuiz and get a quiz; queue 5 URLs and study a different quiz while they generate. Attach the notes screenshots.

---

### Phase 6 — Card types and the Choice player
Implements D-2, F-17, generation of mixed decks, F-19 card-kind toggles.

**Tasks**
1. `ChoicePlayer` and `QuizChoiceView` with MCQ / cloze / true-false sub-views; cloze comparison rules; `recall` fallback to flip-card self-grade.
2. `QuizGenerator` prompt and schema accept requested kinds; validation rejects MCQ without a matching option.
3. `CardRewriter` can convert kinds ("make this multiple choice").
4. Detail shows *Quiz — Choice* when the deck has at least one non-recall card.

**Tests**
- `AIQuizCoreTests`: cloze parsing and comparison; MCQ validation; generator with kinds.
- `AIQuizTests`: `ChoicePlayer` for each kind including override.
- `AIQuizUITests`: Choice quiz on `UITest Mixed Deck` end to end.

**Acceptance**: a generated mixed deck plays through without a verdict mismatch.

---

### Phase 7 — FSRS scheduling, Due today, notifications, insights
Implements F-2, F-7, F-40, F-41, F-42, F-43, S-11, S-12, library due badge.

**Tasks**
1. `FSRS.swift` in `AIQuizCore/Scheduling` with default parameters; `Scheduler.order(cards:)` per SPEC §10; `Scheduler.apply(rating:to:)`.
2. `ScoreStore.recordSession` applies ratings. Remove v1 weighting.
3. Due today row and cross-quiz review session (F-41) with grouped summary.
4. `NotificationScheduler` (S-12) using `UNUserNotificationCenter`; reschedules after every session and on foreground.
5. `InsightsReporter` use case (F-43) and `InsightsView`: builds a compact history digest (per quiz: last 10 sessions, per card: counts and lapses, capped at 6 000 tokens), shows the report, *Create drill deck* saves `drillCards` as a new quiz.

**Tests**
- `AIQuizCoreTests`: FSRS against reference values (Again/Hard/Good/Easy sequences from the published algorithm, tolerance 1 %); ordering rules; light shuffle never moves a card across groups.
- `AIQuizTests`: recordSession updates scheduling; dueCount; notification scheduling computes the right date; insights digest size cap.
- `AIQuizUITests`: Due today row shows the fixture's 2 due cards; review session groups by quiz; insights view renders the fake report and creates the drill deck.

**Acceptance**: after a week of use on the iPad, due counts behave plausibly (owner verification); notification fires at the set time.

---

### Phase 8 — Audio coordinator, tutor chat, oral exam
Implements F-50, F-51 (coordinator part), F-12, F-30, F-45, F-52 optional.

**Tasks**
1. `AudioSessionCoordinator` (F-50); TTS/STT adopt it; spoken "hint" command (F-12) by scanning partial transcripts in study voice mode between cards.
2. `TutorChat` (streaming, context assembly, make-cards action) and `ChatView`; entry points from detail and sessions (session pauses).
3. `OralExamPlayer` + view (F-45): examiner TTS → STT → model decides follow-up → final structured grading; session recorded as `oralExam`.
4. Optional `OpenAISpeechSynthesizer` (F-52) with cache, if time permits.

**Tests**
- `AIQuizTests`: coordinator transitions (playback→record→playAndRecord→end) are idempotent and logged; `TutorChat` streams with a fake client and assembles context under the token cap; `OralExamPlayer` state machine with fake speech + fake client (two turns max per card).
- `AIQuizUITests`: chat sheet streams fake reply and "Make cards" adds cards; oral exam runs on the fixture deck with fake speech (UI-test mode swaps in fake speech that emits scripted transcripts).

**Acceptance**: on the iPad, study voice + "hint" works; oral exam completes 5 cards with Anthropic without audio-session errors in the device log.

---

## 3. Per-PR checklist (copy into every PR description)

- [ ] SPEC IDs implemented: …
- [ ] `scripts/test.sh` green locally (paste the summary line)
- [ ] Zero new compiler warnings
- [ ] New controls have accessibility identifiers listed in SPEC §12 (update SPEC if new)
- [ ] Simulator checklist screenshots attached (iPad Pro 13-inch; iPhone 17 Pro for layout-affecting changes)
- [ ] Device check done for voice/audio changes (`scripts/deploy.sh`), device log clean
- [ ] `PLAN.md` status table updated; decisions recorded
- [ ] `SPEC.md` updated if behaviour differs from what is written
- [ ] `known_issues.md` updated for any non-trivial bug root-caused

---

## 4. Risks and mitigations

| Risk | Mitigation |
|---|---|
| SwiftData migration loses the owner's library | Phase 2 tests against a V1 fixture store; backup before migrate; owner verifies counts on device before merge. |
| OpenAI-compatible servers vary in `response_format` support | Fallback ladder + per-endpoint learning; fixtures for Ollama and LM Studio error shapes. |
| Structured-output schema rejected by Anthropic (unsupported keywords) | `JSONSchema` builder cannot emit unsupported keywords; golden tests. |
| Share extension needs App Group provisioning | Automatic signing with `-allowProvisioningUpdates`; if it fails, fall back to inbox via `UIPasteboard`-free URL scheme and document. |
| Audio session regressions (see `known_issues.md`) | Coordinator is the only writer; keep `@Sendable` closures; device check on every audio PR. |
| Apple on-device model context (4k) too small for sources | Chunking (§7.4) is mandatory for that endpoint; tests cover it. |
| Reader-mode extraction quality | Six HTML fixtures with assertions; "paste instead" fallback always offered. |
