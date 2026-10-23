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

- **Original content (CR-007), branch `feature-study-notes`, stacked on Phase 1:**
  - A quiz generated from a web page, a Markdown file or pasted text keeps that content. An **Original content** section at the top of the quiz screen shows it: the original page in an in-app browser plus a saved copy for offline reading; the original file from Files, with its current contents, falling back to the saved copy if it moved; or the pasted text. Text renders at your reading size.
  - Topic quizzes have no original content, so they show no section.
  - A first version (CR-006) generated AI study notes instead; it was withdrawn the same day at the owner's request. One quiz on the owner's iPad has notes from that build; they are kept in the database, unused.
  - New optional quiz fields are added to existing libraries automatically. Verified on the owner's iPad: 7 quizzes and 207 cards before and after.
  - The Generate form scrolls to the result or error when generation finishes; on iPad the outcome was below the fold.
  - **Changed (CR-008):** the original content is now the fourth entry under **Modes**, called **Read Source Materials**, instead of a separate section. It appears only on quizzes that have a source.
  - **Fixed (CR-008):** Markdown tables render as tables, with a header row, borders, column alignment and sideways scrolling when wide. Nested and numbered lists, block quotes, code blocks and underlined (setext) headings render properly too. The app now uses Apple's built-in Markdown parser instead of its own.

- **Phase 2 (schema v2 and migration), branch `phase-2-schema-v2`, stacked on the original-content branch:**
  - **Library safety:** the library now has a versioned schema with a migration plan (ADR-014). Before any upgrade the app copies the library files to a backup folder in its data and keeps the last three. If a library can't be opened, it is set aside rather than deleted, an empty one starts, and the app says so once.
  - Libraries from v0.1 and from the original-content build both migrate. Checked against two real copies of the iPad library: 7 quizzes / 207 cards and 8 quizzes / 226 cards, nothing lost.
  - **Library:** sort by Recently studied, Name or Newest; search by name or `#tag`; tag chips above the list once you have more than 10 quizzes; an Archived section at the bottom; swipe to archive or delete. Delete now asks first.
  - **Quiz actions:** Rename, Edit tags (with an optional description), Archive and Export JSON from the library's context menu and the quiz screen's More menu.
  - **Cards:** tap a card to see everything on it and its history, edit any field including its kind (recall, multiple choice, fill in the blank, true or false), or delete it. Invalid cards explain what is wrong and can't be saved.
  - **Quiz file format:** JSON files may carry `description`, `tags`, `language`, and per card `kind`, `options`, `explanation` and `mnemonic` (SPEC §2). Export writes them back. A bad file names itself, the card and the problem.
  - **Speed:** counts and scores are stored on each quiz, so the library never loads cards or sessions. With 200 quizzes, 10 000 cards and 5 000 sessions on the simulator, the library fetch takes 8 ms, the due count 1.5 ms, search 4 ms, and a cold launch reaches the first row in about 1.2 s.
  - Generated quizzes record the endpoint and model that made them, shown under About on the quiz screen.

- **Phase 3 (session UI and v1 drift fixes), branch `phase-3-session-ui`:**
  - **Practice missed cards** now works: after a voice quiz, it starts a session with only the cards you got wrong or partly right, and that session is recorded like any other.
  - **Welcome screens** on first launch explain the modes, AI generation and endpoints, and offer to add an endpoint. Skippable, shown once; *Show the introduction again* is in Settings.
  - **Source missing:** an imported quiz or Markdown-file quiz whose file was moved or deleted shows a *Source missing* badge, and its menu offers *Re-link file*. The cards keep working either way.
  - **Settings:** choose the language voice answers are recognised in; turn on *Debug logging* and share or delete the log; *Clear API keys*, *Clear session history* and *Clear quiz library*, each confirmed first.
  - **Fixed:** in Study — User-paced read, a revealed hint stayed open on the next card. Every mode now resets the hint per card.
  - **Fixed:** deleted sample quizzes came back on every launch. Samples are now added on first launch only.
  - **New look (CR-011):** one blue accent color marks the main action on every screen: the round + button, Generate, Save in editors, Play / Pause, Next and Tap to answer. Red, orange and green are kept for grades and destructive actions.
  - **Welcome screens redesigned:** illustrations and tiles for the three study modes, the four kinds of source, and the AI providers, with the official Anthropic and OpenAI marks in light and dark versions. They fit on iPhone, lay out side by side on iPad, and end with *Let's get started*.
  - **Library:** sort sits above the list next to the quiz count instead of in the toolbar, so the + button stands on its own. On iPad the search field moved into that row too.
  - **Generate quiz:** *Cancel* is top left and *Generate* top right. Generate stays grey until there's something to generate from, then turns blue. The bottom of the form only says "We keep a link to the original file (or page) so you can review it later", or "We keep the original text…" for pasted text, and which endpoint is used. The Markdown picker reads *Pick a markdown file*.
  - The three study and quiz screens share one card face, progress header, Hint button, End confirmation and swipe gesture, and each runs on a player that is unit-tested with scripted speech (ADR-015). The three screens went from 960 to 429 lines.

## [0.1.0] — 2026-10-21
State of the app before this effort: library with bundled samples and JSON import, two study modes, voice quiz mode with live transcription and optional AI judging, AI quiz generation from topic / markdown / pasted text / URL via OpenAI, Anthropic or Apple on-device, settings for voice, reading size and appearance. See git history on `main` up to `2e94e8f`.
