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

### 2026-10-24 (app icon)
- **App icon (CR-023), branch `app-icon`:** AIQuiz has its own icon on the Home Screen, in Spotlight, in Settings and in the App Store slot: a friendly coral tutor pointing something out over an open book, with blue sparkles that match the app's accent. Until now the app showed a blank placeholder.

### 2026-10-24 (Phase 11)
- **Phase 11 (Settings and session clean-up), branch `phase-11-settings-ui`, merge after Phase 10:**
  - **Settings is six pages:** AI, Appearance, Voice & speech, Study & quiz, Reviews, and Help & data, each a row with an icon and its current state. Appearance holds Light, Dark or System and the reading size. The tip about Premium voices moved into the voice picker, and the long explanations are one line each.
  - A Premium or Enhanced voice no longer shows its quality twice ("Ava (Premium)").
  - Quiz — Voice answer settings now read **Listen for answer automatically** and **Listen for answer after n seconds**.
  - In Quiz — Voice, the countdown is on the answer button itself: "Listening in 5 seconds, or tap to answer now".
  - Sessions have no separate End (X) button; the back arrow asks *End session?* instead.
  - The tag chip row above the library is gone; search for `#tag` instead (for example `#anki`).
  - **Fixed:** leaving Quiz — Voice while it was listening left the microphone on in the background, which also silenced other speech in the app, including the voice Preview in Settings.

### 2026-10-23 (Phase 10)
- **Phase 10 (hands-free answers), branch `phase-10-hands-free`, merge after Phase 9:**
  - **Auto-listen in voice quiz** (Settings › Quiz — Voice answer, off by default): each card counts down ("Listening in 3"), then the microphone turns on by itself, so you can answer a whole quiz without tapping. *Wait n seconds for answer* sets the countdown, 1 to 30 seconds. Tap the mic to answer sooner.
  - Decks without any hints, such as most Anki decks, no longer show a Hint button that can never be used.

### 2026-10-23 (Phase 9)
- **Phase 9 (Anki import and export), branch `phase-9-anki`, merge after Phase 8:**
  - **Import Anki decks** from the + menu (*Import Anki deck*), from Files (*Open in AIQuiz*), or by sharing a `.apkg` to AIQuiz. Every Anki format works, including whole-collection backups (`.colpkg`).
  - Each deck becomes a quiz named after it ("Spanish › Verbs"), tagged *anki*. Cards keep their Anki history, so what was due in Anki is due here and the rest comes back when Anki would have shown it.
  - Cloze cards become fill-in-the-blank cards, with their hints. Reversed cards come in as their own cards.
  - Images and sounds are left out (cards are text only), and the summary says how many.
  - A file with several nested decks names each quiz from the closest shared level down ("Neri's Spanish Sentences [Part 1] › b. Read Training › 2") instead of the full path.
  - Cards from shared decks no longer carry what Anki hides: search-tool panels, "show more" buttons, hidden fields and scripts.
  - *Import Anki deck* lets you pick any file, so a `.apkg` in a browser's downloads folder isn't greyed out; a file that isn't a deck says so.
  - **Export to Anki** in a quiz's menu saves a `.apkg` that Anki opens. Every field and the review schedule go with it, and a deck sent to Anki and back comes back the same.
  - The format is written down in `docs/anki-interchange.md`, with test decks made by Anki itself, for the companion website. How-to, known issues and the decisions left open are in `docs/anki.md`.

### 2026-10-23 (Phase 8)
- **Phase 8 (audio, tutor chat, oral exam), branch `phase-8-audio-tutor`, merge after Phase 7:**
  - **Oral exam** on every quiz: the examiner reads 5 to 10 questions aloud and listens to your answers. If an answer is vague it asks one follow-up, then moves on. At the end every card is graded with a reason and two sentences overall, and the exam is saved like any session. *Done answering* and *Skip* are at the bottom of the screen.
  - **Tutor chat** (quiz screen toolbar, or the speech-bubble button during any study or quiz session) answers questions about the quiz as it types. It knows the quiz's notes and the card you were on. Starters: *Explain this card*, *Quiz me on this*, *Give me an analogy*. *Make cards* turns the conversation into 3 to 5 new cards to add. Study — Voice pauses while the chat is open.
  - **Say "hint"** in Study — Voice (Settings › Study — Voice auto-read, off by default): after a card that has a hint, the app listens for a moment; saying "hint" shows and reads the hint.
  - Leaving Study — Voice now lets other apps' audio return to full volume.
  - Fixed a flaky Phase 7 test that assumed the review order the light shuffle can swap.

### 2026-10-23 (Phase 7)
- **Phase 7 (spaced repetition, Due today, reminders, insights), branch `phase-7-scheduling`, merge after Phase 6:**
  - **Spaced repetition (FSRS):** every graded card is scheduled. Right answers come back after longer and longer gaps, wrong ones the same day. Quizzes ask the cards that are due or new, up to 20 per session (Settings › Reviews), with *Include cards that aren't due* on the quiz screen.
  - **Due today** at the top of the library starts a review of due cards from all your quizzes; the summary shows how you did per quiz. Long-press *Correct* on a card you found easy.
  - Quiz rows show how many cards are due, and *Most due* is a new sort. On a narrow screen the stats stay on one line and the tags move below them.
  - **Daily reminder** (Settings › Reviews): "12 cards due in 3 quizzes" at the time you choose, only when something is due. Tapping it opens the review.
  - **Insights** (library toolbar): the AI reads your history and names your strengths, what you mix up, and what to do next, with a *Create drill deck* button for cards that target the gaps.

### 2026-10-23 (Phase 6)
- **Phase 6 (card types and Quiz — Choice), branch `phase-6-choice-player`, merge after Phase 5:**
  - **Quiz — Choice**, on any quiz with multiple-choice, fill-in-the-blank or true-or-false cards: tap an option (the right one turns green, a wrong pick red), type the missing words (case and spacing don't matter), or pick true or false. Recall cards in the same deck flip and you grade them. *Mark as…* overrides any verdict, including to Partly right. Ends with the summary, recap and *Practice missed cards*.
  - **Generate from a topic** can include multiple-choice, fill-in-the-blank and true-or-false cards (toggles under *Card types*).
  - **Rewrite** on a card can turn it into multiple choice, fill in the blank, true or false, or back to recall.

### 2026-10-23 (Phase 5)
- **Phase 5 (ingestion and the generation queue), branch `phase-5-ingestion`, merge after Phase 4:**
  - **Make quizzes from more sources:** the + menu has *From a web page*, *From a document* (PDF, Markdown or text), *From photos* (scan pages or pick photos), *From pasted text* and *Batch from a list of links*. Web pages are reduced to the article (menus, ads and comments dropped). PDFs are read page by page, with text recognition for scanned pages. Photos are read on the device.
  - **Generation runs in the background:** Generate closes the sheet straight away; a *Generating (n)* section at the top of the library shows each job's progress, with cancel, retry and remove. Jobs survive quitting the app, and a notification says when a quiz is ready if you're elsewhere.
  - **Batch from a list:** paste one link per line to make one quiz each, in order, while you keep studying.
  - **Long sources** are split into parts and the cards merged, so a long PDF or page no longer fails as "too long".
  - **Share to AIQuiz** from Safari, Files, Photos or any app: the page, text, PDF or image becomes a quiz the next time you open AIQuiz.
  - **Regenerate from source** in a quiz's menu makes a fresh quiz from the same page, file or text, next to the original.
  - Read Source Materials shows PDFs as PDFs, and the recognised text for photos.

### 2026-10-23
- **Phase 4 (AI grading, explanations, hints, lint), branch `phase-4-ai-features`, merge after Phase 3:**
  - **Auto-grade (on by default, Settings › AI):** when you finish speaking, the app stops listening after two seconds of silence, asks the AI for a verdict and highlights its grade with a one-line reason. Tap any grade to decide; a different tap is saved as your override. If the AI is slow or fails, grading still works.
  - **Why was I wrong?** after a Partial or Wrong verdict: a short comparison of your answer with the reference, also shown under the card in the summary.
  - **Session recap:** two sentences from the AI on what went well and what to revisit, at the end of a voice quiz and saved with the session. Tap a recent session on the quiz screen to see each card's grade, the AI's verdict, overrides and explanations.
  - **Card AI (tap a card):** Explain, Mnemonic, Expand (3–5 new cards after this one) and Rewrite (simplify, harder, shorter, or translate). Each result opens as a preview you can save or discard. *Add an AI hint* stores up to three hints, each stronger than the last; in any mode the Hint button shows the card's hint, then the AI hints, one per tap.
  - **Lint cards** (toolbar on the quiz screen) lists ambiguous, duplicate, leaky-hint, too-long and mismatched cards, with *Apply fix* where the AI has one. **Rate difficulty with AI** (More menu) scores every card from 1 to 5.
  - Every feature is checked live against Anthropic (claude-sonnet-5-5) and OpenAI (gpt-6-luna) by `scripts/live-test.sh`.

## [0.1.0] — 2026-10-21
State of the app before this effort: library with bundled samples and JSON import, two study modes, voice quiz mode with live transcription and optional AI judging, AI quiz generation from topic / markdown / pasted text / URL via OpenAI, Anthropic or Apple on-device, settings for voice, reading size and appearance. See git history on `main` up to `2e94e8f`.
