# Changelog

All notable changes to AIQuiz. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow `MARKETING_VERSION` in `Project.yml`. Entries are date-stamped so the history of a version in development stays readable.

## [1.1.0] — in development

### 2026-10-22
- **Docs:** added `REVIEW.md` (code review and rationale), rewrote `SPEC.md` as v2 with requirement IDs and a Change requests section, added `PLAN.md` (phased implementation plan with the test bar per phase), `CLAUDE.md` (operating guide for implementing agents), `DECISIONS.md` (architecture decision records) and this changelog.
- **Process:** `claude` is the integration branch; phase branches merge into it (DECISIONS ADR-001).
- **Phase 0 (test scaffolding), branch `phase-0-test-scaffolding`:**
  - Minimum OS raised to iOS 26.0 (ADR-002).
  - New local package `Packages/AIQuizCore` holding the quiz JSON model, `SessionDeck`, `CardSnapshot` (ADR-009), smart ordering, prompts, the response parser and the request/verdict types; 32 unit tests run with `swift test`.
  - New test targets `AIQuizTests` (XCTest: ScoreStore, ProviderRegistry, FakeProvider, AppEnvironment) and `AIQuizUITests` (XCUITest: library, study read, quiz voice, session end, summary, generate with fake endpoint, error scenario).
  - UI-test mode: `-UITestMode` and `-UITestScenario` launch arguments give an in-memory store, seeded `UITest Deck`, a throwaway defaults suite and a fixture-replaying `FakeProvider` (ADR-005).
  - `AppSettings` and `ProviderRegistry` are injected through the SwiftUI environment; views no longer read singletons.
  - Accessibility identifiers on every control (SPEC §12).
  - `DebugLog` replaced by `os.Logger` wrappers (`Log.app/audio/ai/data`).
  - Removed the unused Objective-C exception bridge and bridging header.
  - Response parser now ignores braces inside JSON strings.
  - Generate screen: the error message now appears directly under the Generate button instead of in a section below the fold, where it was easy to miss on iPad.
  - `scripts/test.sh` (all layers) and `scripts/build-sim.sh` (build with zero-warning gate).

- **Phase 1 (LLMKit foundation), branch `phase-1-llmkit`, stacked on Phase 0:**
  - **Fixed:** Anthropic generation and grading. v1 sent an assistant prefill and `temperature`, which current Claude models reject with HTTP 400.
  - New local package `Packages/LLMKit`: one `LLMClient` interface with `AnthropicClient` (API version `2026-10-21`, structured output via `output_config.format`, effort, refusal fallbacks), `OpenAICompatibleClient` (OpenAI, Ollama, LM Studio, OpenRouter, any compatible server; strict `json_schema` with automatic fallback to `json_object` then prompt-only), `FakeLLMClient`, metering and fallback wrappers, SSE streaming, retry with backoff and `Retry-After`, typed errors with user-safe messages.
  - Apple on-device model wrapped as an `LLMClient`.
  - `QuizGenerator` and `AnswerJudge` rewritten against `LLMClient` with strict JSON schemas, one decode retry, and a context-window check.
  - New Settings → AI endpoints: add from presets, test connection and pick a model, per-task routing with fallbacks, monthly token usage and estimated cost, clear keys. Lazy setup sheet when a task has no usable endpoint.
  - First launch migrates v1 API keys and provider choices into endpoints automatically. A migrated OpenAI endpoint asks you to pick a model once.
  - Local-network endpoints allowed (`NSAllowsLocalNetworking`, local network usage description).
  - Removed the v1 provider layer (`LLMProvider`, `ProviderRegistry`, three providers, provider settings screen).
  - API keys are visible while you enter them, with a hide toggle, so paste mistakes are easy to spot; saved keys show their first and last characters. Pasted whitespace and quotes are trimmed, and a key with the wrong prefix or an inner space is flagged (CR-005).
  - Test connection sends the model a one-word hello and shows its reply and response time. Saving a new key runs the same check first, with a Save anyway option if it fails (CR-005).
  - The model picker hides models that cannot answer chat requests: embedding, speech, image, video (`sora`), realtime and moderation models, completions-only `-instruct` models, and Responses-API-only `-codex` / `-pro` models. Checked against a real OpenAI account's list.
  - **Live-verified 2026-10-22:** `claude-sonnet-5-5` and `gpt-6-luna` both pass plain, streamed and structured requests and model listing. OpenAI accepted strict `json_schema` with nullable fields without falling back.
  - `scripts/live-test.sh` runs the opt-in live API tests with keys read from the macOS login Keychain (`AIQuiz_Ant_test_key`, `AIQuiz_Oai_test_key`). The test variables use these names instead of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` so no other tool picks up the test keys.

## [0.1.0] — 2026-10-21
State of the app before this effort: library with bundled samples and JSON import, two study modes, voice quiz mode with live transcription and optional AI judging, AI quiz generation from topic / markdown / pasted text / URL via OpenAI, Anthropic or Apple on-device, settings for voice, reading size and appearance. See git history on `main` up to `2e94e8f`.
