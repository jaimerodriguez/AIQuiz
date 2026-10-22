# AIQuiz — Specification (v2)

Status: draft for implementation, 2026-10-22. Supersedes v1. Every requirement has an ID (`F-xx` feature, `D-xx` data, `S-xx` settings, `N-xx` non-functional) so `PLAN.md` tasks and tests can reference it. Anything not listed in §14 Backlog or §15 Out of scope is in scope for v2.

A native iPad and iPhone flashcard app. Quizzes come from JSON files, from AI generation, or from documents the user feeds in. Three study/quiz modes plus AI tutoring. Spaced repetition decides what to study. All AI calls go directly from the device to a provider the user configures (Anthropic, OpenAI, any OpenAI-compatible server including local ones, or Apple on-device).

---

## 1. Platform and constraints

- **N-1** iOS/iPadOS 26.0 minimum. Universal (iPhone + iPad). Portrait and landscape.
- **N-2** Swift 6, strict concurrency `complete`. SwiftUI. SwiftData for persistence.
- **N-3** No backend. All network calls go from the device to the user's chosen AI endpoint. API keys live in the Keychain only.
- **N-4** Works offline for everything that does not need a model: library, all three study/quiz modes, self-grading, scheduling, history.
- **N-5** Third-party dependencies limited to: `SwiftSoup` (HTML parsing). Everything else is Apple frameworks. Adding a dependency requires updating this list.
- **N-6** Every interactive control carries an accessibility identifier of the form `screen.element` (see §12). UI tests and the simulator checklist depend on them.
- **N-7** Nothing the user types or says is logged to disk unless the Debug logging setting (S-14) is on. API keys are never logged.
- **N-8 Scale target.** The app must stay responsive with 200 quizzes, 10 000 cards and 5 000 sessions on one device: cold launch to a scrollable library under 1.5 s, no visible hitch when scrolling the library or a 300-card detail list, Due today computed in under 100 ms. Rule that makes this hold: list rows never traverse relationships; counts and scores are stored on `QuizRecord` (§3) and library-wide counts use `fetchCount` with a predicate.

---

## 2. Quiz file format

Unchanged from v1, with optional additions. A quiz is one JSON file:

```json
{
  "quiz": {
    "name": "Roman Emperors",
    "description": "optional one-paragraph description",
    "tags": ["history", "rome"],
    "language": "en",
    "cards": [
      {
        "prompt": "Who succeeded Augustus?",
        "long_answer": "Tiberius, Augustus's stepson, ruled 14–37 AD.",
        "short_answer": "Tiberius",
        "hint": "He retired to Capri.",
        "kind": "recall",
        "options": ["Tiberius", "Caligula", "Claudius", "Nero"],
        "explanation": "optional, shown after grading",
        "mnemonic": "optional"
      }
    ]
  }
}
```

- **D-1** `prompt` and `long_answer` are required. Everything else is optional. Underscore and hyphen key styles are both accepted on import (`long_answer` / `long-answer`); the app always writes underscore style.
- **D-2** `kind` is one of `recall` (default), `multipleChoice`, `cloze`, `trueFalse`. For `multipleChoice`, `options` lists 2–6 choices and `short_answer` must equal one of them. For `cloze`, `prompt` contains one or more `{{blank}}` markers and `short_answer` holds the blanked text(s) joined by `|`. For `trueFalse`, `short_answer` is `true` or `false`.
- **D-3** Any `score` block is ignored on import. Scores live in the app only. The source file is never modified.
- **D-4** A malformed file produces a friendly error naming the file and the first problem. It never crashes.

---

## 3. Data model (SwiftData)

Versioned schema. v2 is the first versioned schema; a migration plan from the unversioned v1 store is mandatory (**D-10**). All fields listed are stored.

### QuizRecord
`id`, `name`, `descriptionText?`, `tags: [String]`, `tagsSearch: String` (lowercased name + tags joined by spaces, for `contains` predicates), `language?`, `createdAt`, `importedAt`, `lastStudiedAt?`, `isArchived: Bool`, `sourceKind` (`bundled` / `imported` / `topic` / `markdown` / `pastedText` / `url` / `pdf` / `image` / `share`), `sourceURLString?`, `sourceBookmark?`, `bundledSampleId?`, `generatedByEndpointName?`, `generatedByModel?`, `summaryMarkdown?` (`@Attribute(.externalStorage)`, study notes, see F-20), `cards` (cascade), `sessions` (cascade).

Stored counters (**D-11**, never computed in list rows): `cardCount`, `sessionCount` (non-abandoned), `bestScore?`, `averageScore?`, `dueCount` (cards with `dueAt <= now` or never reviewed, as of `countersUpdatedAt`), `countersUpdatedAt`. A single function `QuizStats.refresh(_ quiz:)` recomputes them after import, card add/edit/delete, session record, scheduling update, and on app foreground for quizzes whose `countersUpdatedAt` is older than the last midnight (because `dueCount` drifts as time passes). `#Index` on `CardRecord.dueAt` and `SessionRecord.startedAt`.

### CardRecord
Content: `id`, `prompt`, `longAnswer`, `shortAnswer?`, `hint?`, `kind`, `optionsData?` (JSON `[String]`), `explanation?`, `mnemonic?`, `aiHintsData?` (JSON `[String]`, progressive hints, F-24), `orderIndex`, `aiDifficulty?` (1–5, F-26).

History: `correctCount`, `partialCount`, `wrongCount`, `lastSeenAt?`.

Scheduling (FSRS, F-40): `stability: Double` (0 = new), `difficulty: Double`, `dueAt: Date?`, `reps: Int`, `lapses: Int`, `lastRating: Int?`, `lastReviewedAt: Date?`.

### SessionRecord
`id`, `mode` (`studyVoice` / `studyRead` / `quizVoice` / `quizChoice` / `review` / `oralExam`), `startedAt`, `endedAt?`, `durationSeconds`, `scorePercent?`, `abandoned`, `outcomesData` (JSON `[CardOutcome]` where `CardOutcome = {cardId, verdict, aiVerdict?, aiReason?, userOverrode: Bool}`), `endpointName?`, `recapText?` (F-44).

### Not in SwiftData
- `LLMEndpoint` list and routing map: JSON in UserDefaults (keys in Keychain). See §8.
- Tutor chat transcripts: in memory only (§9.1).

---

## 4. Library

- **F-1** Home screen lists every non-archived quiz with name, card count, **best**, **average**, and a **due** badge when `dueCount > 0`, all read from the stored counters (D-11). Sort menu: *Recently studied* (default), *Name*, *Most due*, *Newest*. Search field filters on `tagsSearch`. An *Archived* section at the bottom (collapsed) lists archived quizzes; archiving hides a quiz from Due today and from the main list without deleting history. Tags appear as filter chips above the list when the library has more than 10 quizzes.
- **F-2** A **Due today** row at the top (hidden when zero) starts a cross-quiz review session (F-41) of all due cards in non-archived quizzes. The count comes from one `fetchCount` over `CardRecord` with a `dueAt <= now OR dueAt == nil` predicate, not from iterating quizzes.
- **F-3** Add menu: *Generate with AI*, *Import JSON*, *From document* (PDF / markdown / text file), *From URL*, *From photo* (scan), *Paste*. All but the first two land on the Generate screen (§6) with the source pre-filled.
- **F-4** Swipe to delete a quiz (confirmation alert). Context menu: *Rename*, *Edit tags*, *Archive* / *Unarchive*, *Export JSON*, *Regenerate from source* (when a source bookmark or URL exists), *Delete*. Multi-select (Edit button) allows bulk tag, archive, export and delete.
- **F-5** Imported quizzes whose bookmark no longer resolves show a "source missing" badge. Context menu gains *Re-link file*, which opens the file picker and replaces the bookmark. Cached cards remain playable throughout.
- **F-6** Three bundled sample quizzes are seeded on first launch (unchanged).
- **F-7** An **Insights** toolbar button opens the progress report (F-43).

### Quiz detail
- **F-8** Shows modes (§5), stats (cards, sessions, best, average, due), study notes tab when `summaryMarkdown` exists (F-20), recent sessions (last 10, tappable to see per-card outcomes), and the card list.
- **F-9** Card list rows show prompt, short answer, kind badge, history badges, and due date. Tapping a card opens a card sheet with: full content, *Explain* (F-23), *Mnemonic* (F-25), *Expand* (F-27), *Rewrite* (F-28), *Edit* (manual edit of all fields), *Delete card*.
- **F-10** Detail toolbar: *Lint cards* (F-29), *Tutor chat* (F-30), *Export JSON*.

---

## 5. Study and quiz modes

All modes share: a progress header ("Card n of N"), the card face, a Hint button, an End button with "End session?" confirmation (abandon discards the session), swipe right = next / skip, swipe left = back. Card order comes from the scheduler (§10).

### 5.1 Study — Voice auto-read (F-11)
Unchanged from v1: reads prompt, short answer, long answer; repeats each card N times (S-8); pause between cards (S-9); Repeat / Skip / Back / Pause / Play controls; Hint button reveals the hint and speaks "Hint." Spoken "hint" command is **F-12** (new): while the app is between cards, saying "hint" reveals and reads the hint. Requires the audio coordinator (§11).

### 5.2 Study — User-paced read (F-13)
Unchanged from v1: flip-card or all-at-once (S-10, per-session override in toolbar), Next / Back, Hint.

### 5.3 Quiz — Voice answer (F-14)
1. Prompt shown. *Tap to answer* starts live transcription; transcript appears as it is recognised.
2. *Stop & reveal* (or automatic stop after 2 s of silence once a final transcript exists) shows the transcript beside the reference answers.
3. **Auto-grade (F-15):** when S-3 is on and a grading endpoint is configured, the app sends the transcript to the grading endpoint as soon as the transcript is final and shows the AI verdict chip (Correct / Partial / Wrong) with its one-sentence reason inline. The three self-grade buttons remain; the AI verdict pre-selects one, and tapping a different one overrides it. Both verdicts are saved in the outcome (`aiVerdict`, `userOverrode`).
4. When S-3 is off, the *Ask AI to judge* button behaves as in v1.
5. *Show answer* skips the voice step. Leaving a revealed card without grading records Wrong.
6. **Why was I wrong? (F-16):** after a Partial or Wrong verdict, a button requests a 2–4 sentence contrast between the transcript and the reference answer, shown inline and cached on the outcome for the session summary.
7. Hint button as in study modes.

### 5.4 Quiz — Choice (F-17)
For decks containing `multipleChoice`, `cloze`, or `trueFalse` cards. `recall` cards in a mixed deck are shown as flip cards with self-grade. Multiple choice shows 2–6 option buttons; wrong choice highlights red and the right one green, then *Next*. Cloze shows the prompt with blanks and a text field per blank; case- and whitespace-insensitive comparison; the user can override the auto-verdict. True/false shows two buttons. Verdicts map: right → Correct, wrong → Wrong (no Partial in this mode except by override).

### 5.5 Review session (F-41)
Started from *Due today* (F-2). Mixed cards from several quizzes. Each card uses its quiz's default mode choice: `recall` → flip card with self-grade (Again / Hard / Good buttons labelled Wrong / Partial / Correct), others → choice player. Summary groups results by quiz.

### 5.6 Session end (F-18)
Summary screen: % correct (Correct = 1, Partial = 0.5, Wrong = 0, Skipped excluded), counts, list of Wrong/Partial cards with their explanations when available, **Practice missed cards** (starts a mini-session with only those cards; its result is recorded as a normal session), **Session recap** (F-44, when a grading endpoint is configured): two sentences from the AI on what went well and what to revisit, requested in the background and shown when it arrives. Done returns to the quiz.

### 5.7 Scoring
Session score = sum of verdict values / graded cards. Quiz best = max over non-abandoned sessions; average = mean. Per-card history counts update on every graded verdict. Scheduling state updates per §10.

---

## 6. Generate quiz (AI)

The Generate screen (**F-19**) has a source picker and a source-specific form, then a shared options block, then Generate.

Sources:
- **Topic** — free text. Options: card count (5–50, default 20), difficulty (intro / intermediate / advanced), language (default device locale), tone (formal / casual), focus, exclude, card kinds to include (recall always on; multiple choice, cloze, true/false toggles).
- **Document** — PDF (text via PDFKit; if a page has no text layer, OCR it with Vision), `.md` / `.markdown` / `.txt`. Multi-page PDFs over the endpoint's context budget are chunked (§7.4).
- **URL** — fetched and reduced to article text with reader-mode extraction (**F-21**): pick `<article>` / `<main>` or the densest text container, drop nav / aside / footer / script / style / forms, keep headings and paragraphs, send a desktop browser User-Agent. Failure offers "paste the text instead".
- **Photo** — `VisionKit` document scanner → OCR text → same pipeline. If the generation endpoint supports vision, the user can choose to send the image itself.
- **Paste** — text or markdown.
- **Share** — content arriving from the share extension (F-22) opens this screen with the source filled in.

For every non-Topic source the options block is collapsed by default (the model decides count, difficulty, language, tone from the content), with an *Customise* disclosure that reveals the same options as Topic.

- **F-20 Summarise, then quiz.** For Document, URL, Photo, Paste and Share sources the app first asks the model for study notes (markdown, 300–800 words, headings + bullets, in the source language), shows them in a progress sheet as they stream, stores them in `summaryMarkdown`, then generates cards from the notes plus the original text (or from the notes alone when the source exceeds the context budget). A toggle "Skip notes" generates directly from the source.
- Generated quizzes always land in the library. *Also save JSON to Files* exports the file. *Regenerate from source* (F-4) re-runs this pipeline.
- Progress sheet shows phases: Fetching → Extracting → Writing notes → Generating cards → Linting (F-29, automatic) → Saved. Each phase is cancellable.
- **F-61 Generation queue.** Generation runs through a persistent serial queue, not inline in the Generate screen. Tapping Generate enqueues a job and returns to the library immediately; a *Generating (n)* row at the top of the library shows progress per job (phase and percent) and expands to a job list with cancel and retry. Jobs persist as JSON in Application Support (`GenerationJob`: id, source descriptor, options, state, error, createdAt) and resume after relaunch. The share extension, *From URL*, *From document* and *Paste* all enqueue. A *Batch from list* entry on the Add menu accepts one URL per line and enqueues one job each. Completed jobs post a local notification when the app is in the background. This is what makes "add many summaries that turn into quizzes" practical.
- **F-22 Share extension.** A share extension accepts URLs, plain text, PDFs and images from any app. It writes the payload into an App Group inbox and opens the main app on the Generate screen (or, if the app cannot be opened from the extension context, shows "Open AIQuiz to continue" and the app picks the inbox up at next launch).

---

## 7. AI features catalogue

Each feature names its **purpose** (which endpoint route it uses, §8.2) and its **output contract** (the JSON schema the model must return; the app validates it).

| ID | Feature | Purpose | Output contract |
|---|---|---|---|
| F-19 | Generate quiz | generation | `{quiz:{name, description?, tags?, language?, cards:[{prompt,long_answer,short_answer?,hint?,kind,options?,explanation?}]}}` |
| F-20 | Study notes | summary | free text (markdown), streamed |
| F-15 | Auto-grade / judge | grading | `{verdict:"correct"|"partial"|"wrong", reason}` |
| F-16 | Why was I wrong | grading | `{explanation}` |
| F-23 | Explain card | grading | `{explanation}` (3–6 sentences, plain language) |
| F-24 | Progressive hints | grading | `{hint}`; up to 3 stored per card, each stronger than the last |
| F-25 | Mnemonic | grading | `{mnemonic}` |
| F-26 | Difficulty rating | grading | `{ratings:[{index, difficulty:1-5}]}` for a batch of cards |
| F-27 | Expand card | generation | `{cards:[...]}` 3–5 prerequisite or deeper cards |
| F-28 | Rewrite card | generation | `{card:{...}}` with instruction: simplify / harder / shorten / translate(lang) |
| F-29 | Lint cards | grading | `{issues:[{index, severity:"warn"|"error", kind:"ambiguous"|"duplicate"|"leakyHint"|"tooLong"|"answerMismatch", message, suggestedFix?}]}` |
| F-30 | Tutor chat | chat | free text, streamed (§9.1) |
| F-43 | Insights report | summary | `{headline, strengths:[String], confusions:[{description, cardIds:[String]}], recommendations:[String], drillCards:[{prompt,long_answer,short_answer?,hint?,kind}]}` |
| F-44 | Session recap | grading | `{recap}` two sentences |
| F-45 | Oral exam | chat + grading | §9.2 |

### 7.1 Prompts
Prompts live in `AIQuizCore/Prompts/` as Swift string constants, one file per feature, with a version comment. The system prompt for each feature states the output contract in words and the request sets the JSON schema on the wire. No prompt asks the model to wrap output in code fences.

### 7.2 Structured output
Every feature with a JSON contract sends the schema through the endpoint's native structured-output mechanism (§8.4). The app still passes the text through the tolerant parser (fence stripping, first balanced object) and validates with `Decodable`. On decode failure it retries once with the decoder error appended to the user message. A second failure surfaces a friendly error.

### 7.3 Errors
Typed errors: `unauthorized` (bad key), `rateLimited(retryAfter)`, `contextTooLong`, `server(status)`, `network`, `cancelled`, `malformedResponse`, `endpointUnavailable(reason)`. User-facing messages are friendly and never include response bodies. Bodies go to the debug log only.

### 7.4 Context budget
Each endpoint has `contextWindowTokens`. Token estimate = characters / 4. If `system + user` exceeds 80 % of the window, the source is split into chunks of at most 40 % of the window, each chunk is summarised (F-20 contract), and generation runs on the concatenated summaries. The progress sheet says "Long source: summarising n parts".

### 7.5 Usage accounting
Every response carries input / output / cache-read token counts. The router accumulates totals per endpoint and per month; Settings shows them with an estimated cost when the endpoint has a price table (Anthropic prices are bundled; others editable).

---

## 8. AI endpoints and routing

### 8.1 Endpoint (S-1)
`LLMEndpoint`: `id`, `kind` (`anthropic` / `openAICompatible` / `appleOnDevice`), `name`, `baseURL?`, `model`, `keychainAccount?`, `contextWindowTokens`, `supportsJSONSchema`, `supportsVision`, `priceInPerMTok?`, `priceOutPerMTok?`.

Settings → AI endpoints lists endpoints with Add (presets: Anthropic, OpenAI, Ollama, LM Studio, OpenRouter, Custom), Edit, Delete, and a **Test** button that calls `listModels()` and reports success or the typed error. The model field offers the list returned by Test plus free text. Apple on-device appears only on devices where it is available.

Presets (base URLs): Anthropic `https://api.anthropic.com`; OpenAI `https://api.openai.com/v1`; Ollama `http://<host>:11434/v1`; LM Studio `http://<host>:1234/v1`; OpenRouter `https://openrouter.ai/api/v1`. Default Anthropic model `claude-opus-5-5`. Other presets have no default model; the user picks from Test results.

### 8.2 Routing (S-2)
Purposes: `generation`, `grading`, `summary`, `chat`. Each maps to an endpoint id, with an optional fallback endpoint id. Default on first run: all purposes → the first endpoint the user creates. A purpose whose endpoint is missing a key or unavailable prompts the endpoint sheet the first time it is used (lazy setup, as v1).

### 8.3 Client interface
Implemented in the `LLMKit` package (`PLAN.md` Phase 1). `LLMClient` has `complete(request)`, `stream(request)`, `listModels()`. A request has `system`, `messages` (text and image parts), `maxTokens`, `jsonSchema?`, `effort` (`low` / `medium` / `high`). Responses carry text, usage, and stop reason.

### 8.4 Wire formats
- **Anthropic** `POST {baseURL}/v1/messages`, headers `x-api-key`, `anthropic-version: 2026-10-21`. Body: `model`, `max_tokens`, `system`, `messages`, `stream`, and `output_config: { effort, format: { type: "json_schema", schema } }` when a schema is set. **No** `temperature`, **no** assistant prefill. Schemas must set `additionalProperties: false` on every object and avoid numeric/string constraints. Streaming is SSE; text arrives in `content_block_delta` / `text_delta`; usage in `message_start` and `message_delta`. Errors: 401 → unauthorized, 429 → rateLimited, 400 with "context"/"too long" → contextTooLong, 5xx → server.
- **OpenAI-compatible** `POST {baseURL}/chat/completions`, `Authorization: Bearer` only when a key exists. Body: `model`, `messages` (system as first message), `max_tokens`, `stream`, `stream_options: {include_usage: true}` when streaming, and `response_format: { type: "json_schema", json_schema: { name, strict: true, schema } }` when a schema is set. If the server answers 400 mentioning `response_format`, retry with `{type: "json_object"}` and the schema pasted into the system prompt; if that fails too, retry with no `response_format`. The outcome is cached per endpoint as `supportsJSONSchema`. `GET {baseURL}/models` powers Test. Streaming: SSE, `choices[0].delta.content`, ends at `data: [DONE]`.
- **Apple on-device** `FoundationModels.LanguageModelSession`. v2 uses JSON-in-text with the tolerant parser; `DynamicGenerationSchema` is a backlog item. Context window 4 096 tokens; sources are chunked per §7.4.

### 8.5 Network behaviour
Timeouts: 60 s connect, 300 s total for generation/summary, 60 s for grading. Retry on 429 / 5xx / timeout up to 3 times with exponential backoff (1 s, 2 s, 4 s) honouring `Retry-After`. All calls cancel when the initiating view disappears. Local-network endpoints require `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription`.

---

## 9. Conversational features

### 9.1 Tutor chat (F-30)
Opened from quiz detail or from any card during a session (the session pauses). A sheet with a message list and input field. System context: quiz name, description, study notes (truncated to 4 000 tokens), and the current card if opened from a session. Replies stream token by token. Suggested starters: "Explain this card", "Quiz me on this", "Give me an analogy". Transcript lives for the sheet's lifetime only. *Make cards from this chat* sends the transcript through F-27's contract and appends the cards to the quiz.

### 9.2 Oral exam (F-45)
Mode on quiz detail. The examiner (TTS) asks a question drawn from a card, listens (STT), then either accepts and moves on or asks one follow-up aimed at the gap, then moves on. At most two turns per card, 5–10 cards per exam. At the end the model returns `{cards:[{cardId, verdict, reason}], overall: String}` and the session is recorded with those verdicts. Requires the audio coordinator (§11). Shipped last (PLAN Phase 7).

---

## 10. Scheduling (F-40)

FSRS (Free Spaced Repetition Scheduler) with the published default parameters, implemented in `AIQuizCore/Scheduling/FSRS.swift` and covered by unit tests against known reference values.

- Verdict → rating: Wrong → Again (1), Partial → Hard (2), Correct → Good (3). Easy (4) is available only as a long-press on Correct in review sessions.
- After each graded verdict the card's `stability`, `difficulty`, `dueAt`, `reps`, `lapses`, `lastRating`, `lastReviewedAt` update. Skipped cards do not update.
- **Deck order for any session:** due cards (oldest due first), then never-reviewed cards, then the rest ordered by `dueAt` ascending. Within each group a light shuffle (swap neighbours with probability 0.3) avoids identical order every time. Smart weighting from v1 is removed.
- Session size: study modes use the whole deck; Quiz modes default to all due + new cards, capped by S-11 (default 20), with a *Include not-due cards* toggle on the detail screen.
- **F-42 Notifications.** Optional daily local notification at a chosen time (S-12) when `dueCount > 0` across the library: "12 cards due in 3 quizzes". Tapping opens the Due today review.

---

## 11. Audio

- **F-50 AudioSessionCoordinator.** One `@MainActor` object owns `AVAudioSession`. `beginPlayback()`, `beginRecording()`, `beginPlayAndRecord()`, `end()`; idempotent; logs transitions in debug mode. `TTSService` and `STTService` call it and never touch the session directly. The `@Sendable` closure pattern in `STTService` (see `known_issues.md`) is preserved.
- **F-51 Speech protocols.** `SpeechSynthesizing` (`speak`, `pause`, `resume`, `stop`, `lastUsedVoiceIdentifier`) and `SpeechRecognizing` (`authorisation`, `start(locale, onPartial, onFinal, onError)`, `stop`). Apple implementations are the default. Players depend on the protocols, not the classes.
- **F-52 Cloud TTS (optional).** An OpenAI-compatible `/audio/speech` implementation of `SpeechSynthesizing`, selectable in S-6 when an OpenAI-compatible endpoint exists. Audio is cached per (card field, voice) in the app's caches directory. Backlog if Phase 7 runs long.
- STT language is S-5; the recogniser locale follows it.

---

## 12. Settings (S-xx) and accessibility identifiers

| ID | Setting | Default |
|---|---|---|
| S-1 | AI endpoints (list, add, edit, test, delete) | empty; Apple on-device auto-added when available |
| S-2 | Routing per purpose, with optional fallback | first endpoint |
| S-3 | Auto-grade spoken answers with AI | on when a grading endpoint exists |
| S-4 | Skip study notes when generating from sources | off |
| S-5 | STT language | device locale |
| S-6 | TTS voice (grouped by language, quality tier, diagnostic line) and rate | Automatic, 0.5 |
| S-7 | Appearance: System / Light / Dark | System |
| S-8 | Study voice: repeat count 1–5 | 1 |
| S-9 | Study voice: pause 0.5–3 s | 1.0 |
| S-10 | Study read: default style flip / all-at-once | flip |
| S-11 | Quiz session cap 10–100 | 20 |
| S-12 | Daily due reminder: off / time | off |
| S-13 | Reading size: Small … Huge (scope unchanged from v1 §7.1) | Large |
| S-14 | Debug logging to file | off |
| S-15 | Privacy: Clear API keys, Clear session history, Clear quiz library (each with confirmation) | — |
| S-16 | Usage: tokens and estimated cost per endpoint this month, reset button | — |

Accessibility identifier convention `screen.element`. Every interactive control and every text a test asserts on carries one. Current list (keep in sync when adding screens):

- **Library:** `library.addButton`, `library.generate`, `library.import`, `library.settings`, `library.row.<quizId>`, `library.dueToday` (Phase 7).
- **Quiz detail:** `detail.mode.studyVoice`, `detail.mode.studyRead`, `detail.mode.quizVoice`, `detail.mode.quizChoice` (Phase 6).
- **Any session:** `session.progress` (text "Card n of N"), `session.card.prompt`, `session.card.shortAnswer`, `session.card.longAnswer`, `session.hint`, `session.end`.
- **Study read:** `studyRead.style`, `studyRead.reveal`, `studyRead.next`, `studyRead.back`.
- **Study voice:** `studyVoice.state`, `studyVoice.back`, `studyVoice.repeat`, `studyVoice.play`, `studyVoice.pause`, `studyVoice.skip`.
- **Quiz voice:** `quiz.tapToAnswer`, `quiz.stopReveal`, `quiz.showAnswer`, `quiz.grade.wrong`, `quiz.grade.partial`, `quiz.grade.correct`, `quiz.askAI`, `quiz.aiVerdict`, `quiz.aiError`, `quiz.whyWrong` (Phase 4).
- **Summary:** `summary.score`, `summary.count.correct|partial|wrong|skipped`, `summary.practiceMissed`, `summary.done`.
- **Generate:** `generate.source`, `generate.topic`, `generate.run`, `generate.error`, `generate.cancel`, `generate.saveJSON`, `generate.openLibrary`, `generate.progress` (Phase 5).
- **Settings:** `settings.appearance`, `settings.readingSize`, `settings.endpoints`.
- **AI endpoints:** `endpoints.setupIssue`, `endpoints.done`, `endpoints.row.<name>`, `endpoints.add`, `endpoints.preset.<preset>`, `endpoints.route.<purpose>`, `endpoints.fallback.<purpose>`, `endpoints.usage.<name>`, `endpoints.resetUsage`, `endpoints.clearKeys`; editor: `endpoints.name`, `endpoints.baseURL`, `endpoints.key`, `endpoints.model`, `endpoints.modelPicker`, `endpoints.test`, `endpoints.testResult`, `endpoints.contextWindow`, `endpoints.save`, `endpoints.cancel`.
- **Chat (Phase 8):** `chat.input`, `chat.send`.

---

## 13. First run and onboarding (F-60)
Three screens: modes, AI generation, endpoints. Last screen offers *Add an endpoint now* or *Later*. Skippable. Shown once (flag in UserDefaults). Samples are seeded regardless.

---

## 14. Backlog (specified later, not in v2 scope)
Anki import/export, Obsidian/Notion folder sync, YouTube/podcast transcript sources, lecture recording, knowledge graph / embeddings, Siri App Intents and widgets, Live Activities, iCloud sync, fully on-device open models (MLX), podcast mode, pre-test placement, timed exam simulation, study plan, translate deck, challenge mode, DynamicGenerationSchema for Apple on-device, background generation with notification.

## 15. Out of scope
Accounts, servers, sharing between users, Apple Watch, Mac Catalyst.

---

## 16. Change requests

Every change to behaviour after the v2 draft is recorded here before or with the PR that implements it. Format: id, date, who asked, what changed (section IDs), status.

| CR | Date | Requested by | Change | Status |
|---|---|---|---|---|
| CR-001 | 2026-10-22 | Owner (question about 100+ quizzes) | Added N-8 scale target, D-11 stored counters, library sort / archive / tag chips / multi-select (F-1, F-4), `fetchCount`-based Due today (F-2), generation queue with batch input (F-61). See DECISIONS ADR-006. | accepted |
| CR-002 | 2026-10-22 | Owner (CLAUDE.md edit) | Change tracking process: `CHANGELOG.md` per version with date stamps, this Change requests table, `DECISIONS.md` for architecture decisions. | accepted |
| CR-003 | 2026-10-22 | Claude (Phase 0 implementation) | Sessions run on `CardSnapshot` values rather than `CardRecord` objects (ADR-009). `LLMKit` package is created in Phase 1, not Phase 0; Phase 0's fake AI provider implements the v1 `LLMProvider` protocol and is replaced by `FakeLLMClient` in Phase 1. The Phase 0 UI-test fixture deck is named `UITest Deck` and gains card kinds in Phase 6. | accepted |
| CR-004 | 2026-10-22 | Claude (Phase 1 implementation) | §8.3–8.4: the tolerant response parser moved from AIQuizCore to LLMKit. The Apple on-device client lives in the app target (it needs FoundationModels; LLMKit stays testable on macOS). Anthropic requests add `fallbacks: "default"` on supported models (ADR-010). OpenAI requests use `max_completion_tokens` on api.openai.com and `max_tokens` elsewhere. `EndpointKind.fake` exists for tests and UI-test mode only. Optional JSON fields are expressed as required-but-nullable so one schema satisfies both Anthropic and OpenAI strict mode. Context-budget rejection (§7.4) is in place; chunked summarisation remains Phase 5. New UI-test scenario `noEndpoints`. | accepted |
