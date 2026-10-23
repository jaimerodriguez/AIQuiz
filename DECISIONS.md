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
