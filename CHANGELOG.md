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

## [0.1.0] — 2026-10-21
State of the app before this effort: library with bundled samples and JSON import, two study modes, voice quiz mode with live transcription and optional AI judging, AI quiz generation from topic / markdown / pasted text / URL via OpenAI, Anthropic or Apple on-device, settings for voice, reading size and appearance. See git history on `main` up to `2e94e8f`.
