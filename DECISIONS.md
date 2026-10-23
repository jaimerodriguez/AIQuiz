# Architecture decision records

One entry per decision that shapes the codebase. Each records the conversation with the owner, the options weighed, the decision, and its consequences. Newest at the bottom. Reference entries as `ADR-nnn`.

---

## ADR-001 — `claude` integration branch
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Jaime asked that every commit Claude makes goes to a branch named `claude`, with milestone branches merging into it, and `main` left for him to merge into.

**Options.** (a) Commit straight to `main`. (b) One long-lived `claude` branch plus phase branches. (c) Only phase branches, each PR to `main`.

**Decision.** (b). `claude` cut from `main` at `2e94e8f`. Phase branches `phase-N-short-title` cut from `claude`, PRs target `claude`.

**Consequences.** `main` stays exactly what Jaime has reviewed. CI (when added) runs on PRs to `claude`. Merging `claude` to `main` is manual.

---

## ADR-002 — Minimum OS is iOS 26.0
**Date:** 2026-10-22. **Status:** accepted (Jaime did not object when presented).

**Context.** v1 targeted iOS 18.1 with `#available(iOS 26)` guards around Apple's on-device model. All of Jaime's devices run 26.x.

**Options.** Keep 18.1 and guard every new API (FoundationModels, `SpeechAnalyzer`, newer SwiftData features), or raise to 26.0.

**Decision.** Raise to 26.0.

**Consequences.** Simpler code, on-device model always compiled in, iOS 26 speech APIs available for Phase 8. Nobody on iOS 18/19 can run the app; acceptable for a personal tool.

---

## ADR-003 — Hand-rolled LLM layer, no vendor SDKs or aggregators
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Jaime needs direct calls to Anthropic and OpenAI with his own keys, plus local models, and wants to add many AI features quickly.

**Options.** (a) Community Swift SDKs for each vendor. (b) An aggregator service (OpenRouter, a LiteLLM proxy) as the single API. (c) A thin in-repo layer speaking the two wire formats that matter.

**Trade-offs.** (a) adds dependency churn and still needs an abstraction above both. (b) adds a middleman, a third key, and breaks "direct". (c) is ~500 lines, fully testable with fixtures, and OpenAI's wire format is what every local server speaks, so local models cost no extra code.

**Decision.** (c). `LLMKit` package with `LLMClient` (`complete`, `stream`, `listModels`), `AnthropicClient`, `OpenAICompatibleClient`, `AppleOnDeviceClient`, `FakeLLMClient`. OpenRouter remains available as an OpenAI-compatible endpoint preset for users who want it.

**Consequences.** We own wire-format maintenance; mitigated by golden-request tests and opt-in live tests. Transport and use case are separate, so a new AI feature is one function in `AIQuizCore`.

---

## ADR-004 — Non-UI logic lives in local Swift packages
**Date:** 2026-10-22. **Status:** accepted.

**Context.** v1 had one app target and no tests; nothing could be tested without a simulator.

**Decision.** `Packages/AIQuizCore` (models, deck, scoring, prompts, parsers, use cases) and `Packages/LLMKit` (clients). Both pure Swift, tested with `swift test` on macOS. App target keeps SwiftUI, SwiftData models, speech and audio.

**Consequences.** Fast unit tests; clear seams; SwiftData models must be mirrored by value types at the package boundary (see ADR-009).

---

## ADR-005 — Deterministic UI-test mode with a fake AI endpoint
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Jaime wants thorough testing and self-verification, mostly on the simulator. AI calls are non-deterministic and cost money.

**Decision.** Launch argument `-UITestMode` switches the app to an in-memory store, seeded fixtures, a fake AI provider replaying JSON fixtures, a throwaway `UserDefaults` suite, and scenario variants via `-UITestScenario`. XCUITests and the agent's manual simulator runs both use it. Live API tests exist but run only with `AIQUIZ_LIVE_TESTS=1`.

**Consequences.** UI tests are repeatable and free. The fake must be kept in step with the real clients' output contracts (golden fixtures are shared).

---

## ADR-006 — Stored per-quiz counters and a persistent generation queue (scale)
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Jaime asked whether the design supports ~100 quizzes and many summaries-turned-quizzes. The v1 library rows faulted every card and session of every quiz to show counts and scores, and generation ran inline in a sheet.

**Options.** Compute on the fly and hope SwiftData caching suffices; or store counters on `QuizRecord` and refresh them on write paths; for generation, inline vs a queue.

**Decision.** Stored counters (`SPEC.md` D-11) refreshed by one function, `#Index` on `dueAt`/`startedAt`, library-wide due count via `fetchCount`, a test that fails if a library view touches relationships, and a persistent serial generation queue (F-61) with batch input. Scale target N-8: 200 quizzes / 10 000 cards / 5 000 sessions.

**Consequences.** Slight denormalisation; every write path must call `QuizStats.refresh`, enforced by tests on the `largeLibrary` fixture.

---

## ADR-007 — Third-party dependencies: SwiftSoup only
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Reader-mode extraction needs an HTML parser; everything else is covered by Apple frameworks.

**Decision.** Allow `SwiftSoup` (MIT). Any other dependency requires Jaime's approval and an update to `SPEC.md` N-5.

---

## ADR-008 — Model defaults
**Date:** 2026-10-22. **Status:** accepted.

**Decision.** Anthropic endpoints default to `claude-opus-5-5`; `claude-haiku-5-5` is offered as the low-cost option for grading. No OpenAI model id is hardcoded; the endpoint's Test button lists models from `GET /models` and the user picks. Verified against the Claude API docs on 2026-10-22: current Claude models reject `temperature` and assistant prefill, so the v1 Claude provider was non-functional and is replaced in Phase 1.

---

## ADR-009 — Sessions operate on card snapshots, not SwiftData objects
**Date:** 2026-10-22. **Status:** accepted (implementation decision during Phase 0, reported to Jaime in the Phase 0 PR).

**Context.** Moving `SessionDeck` and the players into `AIQuizCore` (ADR-004) requires them not to depend on `CardRecord`, a SwiftData `@Model` class that lives in the app target and is main-actor bound.

**Options.** (a) Make `SessionDeck` generic over any `Identifiable` card type. (b) Have sessions operate on an immutable `CardSnapshot` value type copied from `CardRecord` at session start; map back by id when recording results.

**Decision.** (b). Snapshots are `Sendable`, trivially testable, and stop views from mutating model objects mid-session. `ScoreStore.recordSession` resolves ids to records.

**Consequences.** Edits to a card during a session do not show until the next session (acceptable). A small mapping function `CardSnapshot(record:)` lives in the app target.

---

## ADR-010 — Anthropic refusal fallbacks on by default
**Date:** 2026-10-22. **Status:** accepted (implementation decision in Phase 1; reported to Jaime in the Phase 1 PR).

**Context.** Current Claude models can decline a request through safety classifiers, returning HTTP 200 with `stop_reason: "refusal"`. Anthropic's server-side fallback re-runs a declined request on a recommended model inside the same call. A study app occasionally covers topics (history of warfare, chemistry, security) where a false-positive decline is plausible.

**Options.** (a) Surface every refusal to the user. (b) Send `fallbacks: "default"` with the `server-side-fallback-2026-07-01` beta header on models that support it. (c) Pin a specific fallback model.

**Decision.** (b), only when the endpoint is the Claude API host and the model is one that accepts the default form (`claude-fable-5-1`, `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5-5`). Refusals that survive the fallback still throw `LLMError.refused`, which the router can route to the purpose's own fallback endpoint.

**Consequences.** Fewer dead ends for the user; a rescued request bills at the fallback model's rate. Easy to turn off by removing the model from `AnthropicClient.fallbackModels`.

---

## ADR-011 — Transport protocol instead of URLProtocol stubs
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Swift Testing runs tests in parallel. `URLProtocol` stubs rely on global registration, which makes parallel HTTP tests race.

**Decision.** `HTTPClient` talks to an `HTTPTransport` protocol. Production uses `URLSessionTransport`; tests inject a per-test `ScriptedTransport` that replays replies and records requests. Backoff sleeps are injected too, so retry tests run instantly and assert the exact delays.

**Consequences.** All 69 LLMKit tests run in parallel in milliseconds with no network. The transport is the only code path not covered by unit tests; the opt-in live tests cover it.

---

## ADR-012 — Endpoints are user data; nothing provider-specific is hardcoded in the router
**Date:** 2026-10-22. **Status:** accepted.

**Context.** Jaime wants Anthropic, OpenAI and local models, with the freedom to add more later.

**Decision.** `AIRouter` stores a list of `LLMEndpoint` values (JSON in UserDefaults, keys in the Keychain under per-endpoint accounts) and a purpose → endpoint map with optional fallbacks. Presets only pre-fill the form. When a purpose has no explicit route, the first non-Apple endpoint serves it, else Apple on-device. v1's two Keychain keys and generation/grading choices migrate automatically on first launch of 1.1.0. OpenAI endpoints carry no default model; the user picks one from Test connection.

**Consequences.** Adding a provider that speaks OpenAI's format needs no code. A migrated OpenAI endpoint shows "No model selected" until Jaime runs Test connection once.

---

## ADR-013 — Markdown is the format for reading content in the app, rendered natively
**Date:** 2026-10-22. **Status:** accepted; amended the same day (CR-007).

**Context.** Jaime wants to read the material a quiz came from, and asked whether the app could render it if files were always Markdown, HTML or PDF. A first implementation (CR-006) generated AI study notes; Jaime clarified he wants the original content, not new AI text.

**Options.** (a) HTML in a web view for everything. (b) PDF. (c) Markdown rendered natively, with web pages shown as themselves. (d) A third-party Markdown renderer.

**Trade-offs.** A web view ignores the reading-size setting and suits only real web pages. PDF is right for PDF documents but not for pasted text or Markdown files. A third-party renderer conflicts with the dependency rule (ADR-007).

**Decision.** Show each source in its own form. Web pages open as the page itself in an in-app browser (`SFSafariViewController`), with the extracted text kept as an offline copy. Markdown files and pasted text render natively: `MarkdownParser` (AIQuizCore, unit-tested) splits blocks and `MarkdownView` draws them at the user's reading size, with `AttributedString(markdown:)` for inline formatting. PDF sources, when added in Phase 5, will display with PDFKit.

**Consequences.** No new dependency; text follows reading size and dark mode. Tables, images and footnotes in Markdown files show as plain text.

**Amendment (CR-008, 2026-10-22).** Jaime reported that tables did not render and asked whether a native renderer exists. Apple has no SwiftUI view that renders a whole Markdown document: `Text` renders inline Markdown only. Foundation's `AttributedString(markdown:)` with `interpretedSyntax: .full` does parse the whole document, including GitHub-flavored tables, and labels every run with a `PresentationIntent` (header, list item and ordinal, quote, code block and language, table, row, cell and column alignment). Options considered: keep extending the hand-written parser; adopt a third-party package such as swift-markdown-ui (conflicts with ADR-007); use Foundation's parser and keep drawing blocks ourselves. **Decision:** the last. `MarkdownParser` now only groups Foundation's runs into blocks, keeping inline formatting as `AttributedString`, and `MarkdownView` draws tables with SwiftUI `Grid`. Empty table cells produce no runs, so cells are placed by column index. Images and footnotes still show as text.

## ADR-014 — Versioned schemas with two legacy shapes, backups before every upgrade
**Date:** 2026-10-22. **Status:** accepted (PLAN Phase 2, SPEC D-10, CR-009).

**Context.** Jaime uses the app daily on the iPad, and the library must survive every schema change. Until Phase 2 the store was unversioned, and SwiftData migrated it automatically when optional fields were added. Two unversioned shapes exist in the wild: v0.1 (`main`), which a phone that never ran a newer build still has, and the CR-007 shape, which the iPad has now (8 quizzes, 226 cards on 2026-10-22). A third, the CR-006 build, only ever ran on the iPad and has already moved on. Phase 2 adds many non-optional fields, stored counters and indexes.

**Options.** (a) Keep relying on automatic lightweight migration. This works only while every change is optional, gives no hook to fill derived values such as counters and origin, and fails without a trace. (b) A versioned schema for the CR-007 shape only, as PLAN first said. A phone still on v0.1 would then not match any known version, and its library would be treated as unreadable. (c) Versioned schemas for both legacy shapes, a lightweight V0 → V1 stage and a custom V1 → V2 stage, plus file backups.

**Decision.** (c). `SchemaV0` and `SchemaV1` are frozen copies of the two shapes, and the app uses `SchemaV2` through type aliases. Every attribute added in V2 is optional or has a default, so the database change itself is lightweight. The custom stage's `didMigrate` then fills `createdAt`, `originRaw`, `tagsSearch`, session durations and the stored counters. `StoreLoader` copies the store files to `Backups/<timestamp>-before-v2.0.0/` before any upgrade and keeps the newest three. If the store cannot be opened, it moves the files to `Backups/<timestamp>-unreadable/`, starts an empty library and the app shows a one-time alert. It never deletes a library.

**Verification.** Unit tests build V0 and V1 stores on disk and check every field after migration. Opening twice is idempotent, and an unreadable store is backed up and replaced. Two real copies of the iPad library also migrate in a test with no loss: the v0.1 copy from earlier on 2026-10-22 (7 quizzes, 207 cards) and the CR-007 copy (8 quizzes, 226 cards). The test runs when `AIQUIZ_REAL_STORES` lists the folders.

**Consequences.** Every later schema change adds a `SchemaV3` and a stage; the frozen schemas are never edited. The backup folder lives in the app's data, not in Files. Recovering a backup means copying it back over the store, for example with `devicectl`. The `studyNotes` column stays until Jaime agrees to drop it.

## ADR-015 — Players and speech protocols live in AIQuizCore; UI tests use scripted speech
**Date:** 2026-10-22. **Status:** accepted (PLAN Phase 3, SPEC F-51, CR-010).

**Context.** REVIEW §4.4 asked for every mode to be a dumb view over a player. PLAN put the speech protocols in the app with the players tested in `AIQuizTests`. Two of the three players depended on the concrete `TTSService` and `STTService` singletons, so no test could drive them, and the voice flows could not run in UI tests at all.

**Options.** (a) Protocols and players in the app target, tested on the simulator. (b) Protocols and players in AIQuizCore, with Apple implementations in the app. (c) Keep concrete services and test only through UI tests.

**Decision.** (b). `SpeechSynthesizing` and `SpeechRecognizing` are `@MainActor` protocols in AIQuizCore, next to `ScriptedSynthesizer` and `ScriptedRecognizer`. `TTSService` and `STTService` conform in the app. `STTService`'s audio tap and recognition callbacks are untouched (known_issues §1); only its transcript callback now says whether a result is final. The composition root builds a `SpeechServices` value: Apple's services normally, scripted ones in UI-test mode.

**Consequences.** Player logic runs in `swift test` in under a second (14 player tests). The simulator exercises Study voice and Quiz voice end to end, including a voice answer. Real audio still needs the iPad: hearing TTS and seeing a live transcript are owner checks, since an agent can neither hear nor speak. Phase 8's audio coordinator plugs in behind the same protocols.

## ADR-016 — One accent color and a small Theme
**Date:** 2026-10-22. **Status:** accepted (CR-011, SPEC N-9).

**Context.** Jaime found the app plain and said critical controls didn't stand out. On iOS 26 toolbar buttons are monochrome glass, so the add button, the generate action and the editors' Save looked like everything else. The welcome screens were paragraphs. Jaime asked for a cohesive theme with one accent color, applied from now on.

**Options.** (a) Rely on the system tint. It is blue already, but most actions used bordered or glass styles, so it rarely showed. (b) Several brand colors per feature. This is lively, but it competes with the meaning of red, orange and green for grades. (c) One accent color, used deliberately, plus a few shared building blocks.

**Decision.** (c). `AccentColor` in a new asset catalog is a deeper blue in light mode and a lighter one in dark mode, and it is set as the global accent. `Theme` holds the corner radii and readable width, `primaryActionStyle()` (filled accent, grey while disabled) and `AccentIcon` (a symbol in a soft accent circle). Rules:
- The accent marks one primary action per screen, and feature icons.
- Red, orange and green are kept for meaning only.
- Everything else stays neutral.
- Explanatory screens use tiles and icons rather than paragraphs.
- Each screen is checked on iPad and iPhone.

**Logos.** Provider tiles use official marks, never redrawn ones. On 2026-10-22, with Jaime's approval, I downloaded these:
- `logo-anthropic`: the Anthropic symbol in Slate (light mode) and Ivory (dark mode), from the press kit linked on anthropic.com/news. The kit contains no usage terms.
- `logo-openai`: the OpenAI Blossom in black (light mode) and white (dark mode), from `cdn.openai.com/brand/openai-logos.zip` on openai.com/brand. Jaime accepted OpenAI's Marks usage terms for this. The SVG keeps OpenAI's built-in clear space, so the Blossom looks a little smaller than the other marks; that is intentional.

The files are used unmodified, next to the provider's name and only to identify the provider. If an image set is removed, the tile falls back to a neutral monogram. Apple uses the `apple.logo` SF Symbol, which refers to Apple's own on-device model.

**Consequences.** Later screens follow N-9. Phase 6's choice buttons and Phase 7's due badge will use the accent only for the selected or primary state.

## ADR-017 — AI never blocks a learner; AI results are offers
**Date:** 2026-10-23. **Status:** accepted (PLAN Phase 4, CR-013).

**Context.** Phase 4 puts AI inside the study loop: auto-grading, "why was I wrong", hints, and edits to cards. Model calls take seconds, fail, or return something the learner disagrees with. The plan's acceptance criterion is that errors never block grading.

**Options.** (a) Wait for the AI before letting the learner continue. This is simple, but a slow or failing endpoint stalls the session. (b) Run AI in the background, show it when it arrives, and let the learner act at any time. (c) Apply AI output automatically: grades, lint fixes, rewrites.

**Decision.** (b), and AI output is never applied without a tap.
- **Auto-grade** runs in a child task when the answer is revealed. The grade buttons work throughout. Grading or moving on cancels the task, and a reply that arrives later is checked against the current card and dropped.
- **Overrides:** the AI's grade is shown filled. The learner's tap is what counts, and a different tap is stored as an override next to the AI's verdict and reason.
- **Card-sheet results** (explanation, mnemonic, rewrite, expansion) and **lint fixes** appear as previews with Save, Replace or Add next to Discard.
- **The session recap** loads in the background and is saved when it arrives. A failure just leaves it out.

**Consequences.** Every AI path has a test for errors and late replies, and the core suite drives them with a judge it resolves by hand. Recording keeps both verdicts, so later phases such as FSRS and insights can see where the AI and the learner disagree.

## ADR-018 — A main-actor generation queue with a JSON file; sharing through an App Group inbox
**Date:** 2026-10-23. **Status:** accepted (PLAN Phase 5, SPEC F-61, F-22, CR-014).

**Context.** Jaime wants to turn many summaries and pages into quizzes. Generation takes tens of seconds, and a PDF or a long page takes longer. It must survive leaving the Generate screen, a relaunch, and failures, while Jaime keeps studying. The share extension runs in a separate process that can't open the app.

**Options.** (a) Keep generation inline on the Generate screen. This blocks the UI and loses work on dismiss. (b) A `BGProcessingTask`. iOS decides when it runs, and the work is short-lived and interactive. (c) A serial in-app queue with persisted jobs. (d) A Swift `actor` for the queue, as PLAN first said.

**Decision.** (c), as a `@MainActor @Observable` class rather than an actor. The library observes it directly, and the heavy work runs in nonisolated extractors and network calls.
- **Persistence:** jobs live in `Application Support/Generation/jobs.json`. A job that was running when the app quit returns as queued.
- **Running:** one job at a time, through `GenerationPipeline` (fetch or read, then write cards). Cancel, retry and remove act on single jobs.
- **Finishing:** the quiz is saved and the job leaves the list. A background notification posts when the app isn't active.
- **Sharing:** the extension writes `<id>.json` plus any file into the App Group container's `Inbox`. The app drains it on launch and foreground; shared PDFs are kept in Documents/Shared so the quiz can link to them.

**Consequences.** Reader mode lives in AIQuizCore on SwiftSoup, the dependency SPEC N-5 allows, so it is tested with `swift test` on hand-written pages. The App Group `group.com.jaimerodriguez.aiquiz` is registered by automatic signing (`-allowProvisioningUpdates`) the first time the app is deployed with the extension. UI-test mode uses a fake extractor and a throwaway job file. The `slowGeneration` scenario makes the queue visible.
