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
- **N-9 Visual design (CR-011, ADR-016).** One accent color, `AccentColor` (blue), marks the primary action on each screen and the app's feature icons, and nothing else. Red, orange and green appear only when they carry meaning: destructive actions, recording, and Wrong / Partial / Correct. Everything else is neutral. A primary action uses the filled accent style (`primaryActionStyle()`) and stays disabled, grey, until it can run. Screens use icons and tiles rather than paragraphs where they explain something. Every screen is checked on iPad Pro 13-inch and iPhone 17 Pro.

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

Versioned schema (**D-10**, ADR-014). `SchemaV0` is v0.1's unversioned store, `SchemaV1` is the CR-007 store (v0.1 plus the original-content fields), `SchemaV2` is current. `AIQuizMigrationPlan` runs V0 → V1 (lightweight) → V2 (lightweight, then a step that fills derived values and counters). Before an upgrade the store files are copied to `Application Support/Backups/<timestamp>-before-v2.0.0/` (newest three kept). A store that cannot be opened is moved to `Backups/<timestamp>-unreadable/`, an empty library starts, and the app says so once. All fields listed are stored.

### QuizRecord
`id`, `name`, `descriptionText?`, `tags: [String]` (single words; spaces become hyphens), `tagsSearch: String` (` name #tag1 #tag2 `, lowercased, for `contains` predicates; a tag filter matches ` #tag `), `language?`, `createdAt`, `importedAt`, `lastStudiedAt?`, `isArchived: Bool`, `originRaw` (how the quiz arrived: `bundled` / `imported` / `topic` / `markdown` / `pastedText` / `url` / `pdf` / `image` / `share` / `unknown`; called `sourceKind` in earlier drafts, renamed because CR-007 uses that name for the original content's kind; pre-v2 quizzes get `bundled` from `bundledSampleId`, `url` / `markdown` / `pastedText` from `sourceKindRaw`, `imported` from a bookmark, otherwise `unknown`), `sourceBookmark?`, `bundledSampleId?`, `generatedByEndpointName?`, `generatedByModel?`, `sourceKindRaw?` (`webPage` / `markdownFile` / `pastedText`, CR-007), `sourceTitle?`, `sourceTextData?` (`@Attribute(.externalStorage)`, copy of the original text), `sourceURLString?`, `summaryMarkdownData?` (external storage; AI study notes, F-20, on hold), `studyNotes?` (unused, see CR-007; kept until the owner agrees to drop it), `cards` (cascade), `sessions` (cascade). `#Index` on `lastStudiedAt`, `createdAt`, `isArchived`.

Stored counters (**D-11**, never computed in list rows): `cardCount`, `sessionCount` (non-abandoned), `bestScore?`, `averageScore?`, `dueCount` (cards with `dueAt <= now` or never reviewed, as of `countersUpdatedAt`), `countersUpdatedAt`. A single function `QuizStats.refresh(_ quiz:)` recomputes them (and moves `lastStudiedAt` forward) after import, generation, card edit/delete, session record, scheduling update, and on launch and app foreground for quizzes whose `countersUpdatedAt` is older than the last midnight (because `dueCount` drifts as time passes). The arithmetic is `QuizCounters.compute` in AIQuizCore. `#Index` on `CardRecord.dueAt` and `SessionRecord.startedAt`.

### CardRecord
Content: `id`, `prompt`, `longAnswer`, `shortAnswer?`, `hint?`, `kind` (`CardKind` raw value, default `recall`), `optionsData?` (JSON `[String]`), `explanation?`, `mnemonic?`, `aiHintsData?` (JSON `[String]`, progressive hints, F-24), `orderIndex`, `aiDifficulty?` (1–5, F-26).

History: `correctCount`, `partialCount`, `wrongCount`, `lastSeenAt?`.

Scheduling (FSRS, F-40): `stability: Double` (0 = new), `difficulty: Double`, `dueAt: Date?`, `reps: Int`, `lapses: Int`, `lastRating: Int?`, `lastReviewedAt: Date?`.

### SessionRecord
`id`, `mode` (`studyVoice` / `studyRead` / `quizVoice` / `quizChoice` / `review` / `oralExam`), `startedAt`, `endedAt?`, `durationSeconds`, `scorePercent?`, `abandoned`, `outcomesData` (JSON `[CardOutcome]` where `CardOutcome = {cardId, verdict, aiVerdict?, aiReason?, userOverrode: Bool}`), `endpointName?`, `recapText?` (F-44).

### Not in SwiftData
- `LLMEndpoint` list and routing map: JSON in UserDefaults (keys in Keychain). See §8.
- Tutor chat transcripts: in memory only (§9.1).

---

## 4. Library

- **F-1** Home screen lists every non-archived quiz with name, card count, **best**, **average**, tags, and a **due** badge when `dueCount > 0`, all read from the stored counters (D-11). Sort menu: *Recently studied* (default), *Name*, *Most due*, *Newest*; it sits in a header row above the list with the quiz count, not in the toolbar, so the add button stands alone (CR-011). On iPad the search field sits in that row too; on iPhone it is the system search bar at the bottom (CR-012). The due badge and *Most due* ship with scheduling in Phase 7 (CR-009); until then every card counts as due, so both would be noise. Search field filters on `tagsSearch`. An *Archived* section at the bottom (collapsed) lists archived quizzes; archiving hides a quiz from Due today and from the main list without deleting history. Tags appear as filter chips above the list when the library has more than 10 quizzes.
- **F-2** A **Due today** row at the top (hidden when zero) starts a cross-quiz review session (F-41) of all due cards in non-archived quizzes. The count comes from one `fetchCount` over `CardRecord` with a `dueAt <= now OR dueAt == nil` predicate, not from iterating quizzes.
- **F-3** Add menu: *Generate with AI*, *Import JSON*, *From document* (PDF / markdown / text file), *From URL*, *From photo* (scan), *Paste*. All but the first two land on the Generate screen (§6) with the source pre-filled.
- **F-4** Swipe to delete a quiz (confirmation alert) or archive it. Context menu: *Rename*, *Edit tags*, *Archive* / *Unarchive*, *Export JSON*, *Regenerate from source* (when a source bookmark or URL exists; Phase 5), *Delete*. Rename and Edit tags open one sheet (name, tags, description). Multi-select (Edit button) allows bulk tag, archive, export and delete (deferred, CR-009).
- **F-5** Imported quizzes whose bookmark no longer resolves show a "source missing" badge. Context menu gains *Re-link file*, which opens the file picker and replaces the bookmark. Cached cards remain playable throughout.
- **F-6** Three bundled sample quizzes are seeded on first launch (unchanged).
- **F-7** An **Insights** toolbar button opens the progress report (F-43).

### Quiz detail
- **F-8** Shows modes (§5, plus **Read Source Materials** when the quiz has a source, CR-008), stats (cards, sessions, best, average, due), study notes tab when `summaryMarkdown` exists (F-20), recent sessions (last 10, tappable to see per-card outcomes), and the card list.
- **F-9** Card list rows show prompt, short answer, kind badge, history badges, and due date. Tapping a card opens a card sheet with: full content, *Explain* (F-23), *Mnemonic* (F-25), *Expand* (F-27), *Rewrite* (F-28), *Edit* (manual edit of all fields), *Delete card*.
- **F-10** Detail toolbar: *Lint cards* (F-29), *Tutor chat* (F-30), and a *More* menu with *Rename*, *Edit tags*, *Archive* and *Export JSON*. An *About* section shows the description, tags and the model that generated the quiz.

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

- **Library:** `library.addButton`, `library.generate`, `library.import`, `library.settings`, `library.row.<quizId>`, `library.sort`, `library.sort.<recent|name|newest>`, `library.tag.<tag>`, `library.archived`, `library.noMatches`, `library.swipeDelete`, `library.search` and `library.search.clear` (iPad only, in the header row), `library.sourceMissing`, `library.launchMetric` (UI-test mode only), context menu `library.relink|rename|editTags|archive|export|delete`, `quiz.confirmDelete`, `library.dueToday` (Phase 7).
- **Quiz details editor:** `quizEdit.name`, `quizEdit.tags`, `quizEdit.description`, `quizEdit.save`, `quizEdit.cancel`.
- **Quiz detail:** `detail.mode.studyVoice`, `detail.mode.studyRead`, `detail.mode.quizVoice`, `detail.mode.source` (Read Source Materials, CR-008), `detail.mode.quizChoice` (Phase 6), `detail.description`, `detail.tags`, `detail.stat.cards`, `detail.stat.sessions`, `detail.card.<index>`, `detail.card.difficulty`, `detail.session.<index>`, `detail.lint`, `detail.rateDifficulty`, `detail.rating`, `detail.more`, `detail.rename|editTags|archive|export`.
- **Card AI (card sheet):** `card.ai.explain`, `card.ai.mnemonic`, `card.ai.expand`, `card.ai.rewrite`, `card.ai.rewrite.<Simplify|Make harder|Shorten>`, `card.ai.language`, `card.ai.hint`, `card.ai.hintText.<n>`, `card.difficulty`; result sheet `card.ai.result`, `card.ai.save`, `card.ai.discard`.
- **Lint:** `lint.progress`, `lint.issue.<cardIndex>`, `lint.apply.<cardIndex>`, `lint.dismiss.<cardIndex>`, `lint.clean`, `lint.error`, `lint.done`.
- **Session outcomes:** `sessionOutcomes.card.<n>`, `sessionOutcomes.recap`. Summary: `summary.recap`, `summary.recapLoading`.
- **Card sheet:** `card.prompt`, `card.shortAnswer`, `card.longAnswer`, `card.hint`, `card.explanation`, `card.mnemonic`, `card.edit`, `card.delete`, `card.confirmDelete`, `card.done`; editor `cardEdit.prompt|shortAnswer|longAnswer|hint|kind|options|explanation|mnemonic|problem|save`.
- **Source reader:** `reader.content`, `reader.notice`, `reader.table`, `reader.originalPage`, `reader.share`.
- **Any session:** `session.progress` (text "Card n of N"), `session.card.prompt`, `session.card.shortAnswer`, `session.card.longAnswer`, `session.card.hint` (the revealed hint), `session.hint`, `session.end`.
- **Onboarding:** `onboarding.title.<page>`, `onboarding.next`, `onboarding.skip`, `onboarding.start`.
- **Study read:** `studyRead.style`, `studyRead.reveal`, `studyRead.next`, `studyRead.back`.
- **Study voice:** `studyVoice.state`, `studyVoice.back`, `studyVoice.repeat`, `studyVoice.play`, `studyVoice.pause`, `studyVoice.skip`.
- **Quiz choice (F-17):** `choice.kind`, `choice.option.<n>`, `choice.blank.<n>`, `choice.check`, `choice.reveal`, `choice.verdict`, `choice.override`, `choice.next`, `choice.grade.<correct|partial|wrong>`; generate toggles `generate.kind.<multipleChoice|cloze|trueFalse>`; card sheet `card.ai.convert.<kind>`.
- **Quiz voice:** `quiz.transcript`, `quiz.aiJudging`, `quiz.whyWrongText`, `quiz.tapToAnswer`, `quiz.stopReveal`, `quiz.showAnswer`, `quiz.grade.wrong`, `quiz.grade.partial`, `quiz.grade.correct`, `quiz.askAI`, `quiz.aiVerdict`, `quiz.aiError`, `quiz.whyWrong` (Phase 4).
- **Summary:** `summary.score`, `summary.count.correct|partial|wrong|skipped`, `summary.practiceMissed`, `summary.done`.
- **Generate:** `generate.source`, `generate.topic`, `generate.url`, `generate.document`, `generate.photo.scan`, `generate.photo.pick`, `generate.photo.count`, `generate.paste`, `generate.run` (top right, disabled until the source is ready; queues the job and closes), `generate.error`, `generate.cancel`.
- **Generation queue and batch (F-61):** `library.generating`, `library.job.<n>`, `library.job.<n>.status`, `library.job.<n>.cancel`, `library.job.<n>.retry`, `library.job.<n>.remove`; Add menu `library.fromURL`, `library.fromDocument`, `library.fromPhoto`, `library.fromPaste`, `library.batch`; batch sheet `batch.text`, `batch.count`, `batch.add`, `batch.cancel`; context menus `library.regenerate`, `detail.regenerate`; source reader `reader.pdf`.
- **Settings:** `settings.appearance`, `settings.readingSize`, `settings.endpoints`, `settings.autoGrade`, `settings.sttLanguage`, `settings.debugLogging`, `settings.shareLog`, `settings.deleteLog`, `settings.clearKeys`, `settings.clearHistory`, `settings.clearLibrary`, `settings.confirmClear`, `settings.showIntro`.
- **AI endpoints:** `endpoints.setupIssue`, `endpoints.done`, `endpoints.row.<name>`, `endpoints.add`, `endpoints.preset.<preset>`, `endpoints.route.<purpose>`, `endpoints.fallback.<purpose>`, `endpoints.usage.<name>`, `endpoints.resetUsage`, `endpoints.clearKeys`; editor: `endpoints.name`, `endpoints.baseURL`, `endpoints.key`, `endpoints.keyVisibility`, `endpoints.keyWarning`, `endpoints.savedKey`, `endpoints.model`, `endpoints.modelPicker`, `endpoints.test`, `endpoints.testResult`, `endpoints.contextWindow`, `endpoints.save`, `endpoints.cancel`.
- **Chat (Phase 8):** `chat.input`, `chat.send`.

---

## 13. First run and onboarding (F-60)
Three illustrated screens (CR-011): *Three ways to study* (a tile per mode), *Make quizzes from anything* (the four source types), *Bring your own AI* (Anthropic, OpenAI, Apple on-device and your own server, plus a one-line note that keys stay on the device). Page 1's card shows a checkmark; pages 2 and 3 share the sparkles "intelligence" badge (CR-012). Tiles sit side by side on iPad and stack on iPhone. The last screen ends with *Let's get started*; endpoints are added later from Settings. Skippable. Shown once (flag in UserDefaults). Samples are seeded regardless. Provider tiles show the official Anthropic symbol and OpenAI Blossom (asset catalog `logo-anthropic`, `logo-openai`, light and dark variants, unmodified; provenance in ADR-016), Apple's `apple.logo` symbol, and a server symbol.

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
| CR-005 | 2026-10-22 | Owner (trying Phase 1 on the iPad) | §8.1 S-1: the API key field is visible by default, wraps so long keys show in full, and has a hide toggle; a saved key shows as `sk-ant-api…wxyz` with a reveal toggle. Pasted keys are trimmed of whitespace, quotes and zero-width characters; a space inside the key or the wrong provider prefix (`sk-ant-` for Anthropic, `sk-` for api.openai.com) shows a warning. Test connection now lists chat-capable models only (embedding, speech, image and moderation models are filtered) and sends the selected model a one-word hello (`AIRouter.helloRequest`, low effort, not counted in usage), showing the reply and latency. Saving a newly entered key runs the same check first; if it fails the user can keep editing or save anyway. No model is guessed for OpenAI or OpenRouter, whose catalogues are long. | accepted |
| CR-006 | 2026-10-22 | Claude, misreading the owner | AI-written study notes before card generation, plus a notes reader. **Withdrawn the same day:** the owner wanted the original content kept, not new AI notes. Replaced by CR-007. | withdrawn |
| CR-007 | 2026-10-22 | Owner ("save a link to the original content and display it") | Quizzes generated from a source keep it and show it in an **Original content** section at the top of quiz detail: web page → the link, opened in an in-app browser, plus the extracted text as an offline copy; Markdown file → a security-scoped bookmark to the file in Files, displayed with its current contents and falling back to the copy saved at generation time if the file moved or was deleted; pasted text → the text. Text renders as Markdown at the reading size (ADR-013). Topic quizzes have no original content and show no section. No AI writes notes: F-20 (AI study notes) is on hold until the owner asks for it. QuizRecord gains `sourceKindRaw`, `sourceTitle`, `sourceTextData` (external storage) and `sourceURLString`; `sourceBookmark` is reused for the Markdown file. An unused `studyNotes` column from the withdrawn CR-006 build stays so notes on the owner's iPad are not deleted; drop it in Phase 2 with the owner's agreement. | accepted; display amended by CR-008 |
| CR-008 | 2026-10-22 | Owner ("move original file to Modes … call it Read Source Materials"; "tables are not rendered properly") | The original content moves out of its own section into **Modes**, as the fourth row **Read Source Materials** (`detail.mode.source`), shown only for quizzes with a source; its subtitle names the source. It opens one screen per source kind: Markdown file → current file contents with the saved-copy fallback; web page → the saved text, with a Safari toolbar button for the live page; pasted text → the text. Markdown is now parsed by Foundation's built-in CommonMark + GitHub-flavored parser (`AttributedString(markdown:)`, full syntax) instead of a hand-written parser, so tables (header row, per-column alignment, borders, horizontal scroll), nested and numbered lists, quotes, code blocks and setext headings render properly (ADR-013 amended). Apple ships no full Markdown view for SwiftUI, so the app still draws the blocks itself. | accepted |
| CR-009 | 2026-10-22 | Claude (Phase 2 implementation) | §3: the quiz's origin is stored as `originRaw` (not `sourceKind`, which CR-007 already uses); `summaryMarkdown` is stored as `summaryMarkdownData` because external storage applies to binary data; `tagsSearch` is ` name #tag1 #tag2 ` so a tag filter can match a whole tag. The migration plan recognises two pre-v2 shapes (v0.1 and the CR-007 store), not one, so a phone that never ran the CR-007 build also migrates. F-1: the due badge and *Most due* sort move to Phase 7, when FSRS makes `dueCount` meaningful. F-4: multi-select bulk actions are deferred to a later phase; *Regenerate from source* and *Re-link file* (F-5) stay in Phase 5. `studyNotes` is kept in v2. | accepted |
| CR-010 | 2026-10-22 | Claude (Phase 3 implementation) | §5: the players (`StudyVoicePlayer`, `StudyReadPlayer`, `QuizVoicePlayer`) and the speech protocols (F-51) live in AIQuizCore, so they are tested with `swift test`; UI-test mode uses scripted speech so every mode runs end to end on the simulator (ADR-015). The hint now resets on every card in every mode (in Study read it used to stay open on the next card), and the Hint button sits with the controls in voice modes and on the card in Study read, as before. *Practice missed cards* (F-18) is offered wherever a session ends on a summary with grades; the two study modes have no grades or summary, so they have nothing to practise. F-6: samples are seeded on first launch only (v1 re-added deleted samples on every launch). S-14's log lives in the app's caches, is capped at 1 MB and can be shared or deleted from Settings. F-60 adds *Show the introduction again* in Settings; UI-test mode skips onboarding unless `-UITestOnboarding` is passed. F-1 search shipped in Phase 2. | accepted |
| CR-011 | 2026-10-22 | Owner (UI feedback) | Visual theme (new N-9): one blue accent for primary actions and icons; the add button is an accent circle; the primary Save in each editor and Play / Pause in Study voice carry the accent; the archive swipe is neutral grey. Onboarding (§13) is redesigned with illustrations and tiles, adapts to iPhone, and ends with *Let's get started* instead of *Add an endpoint now* / *Later*. The library's sort moves from the toolbar to a header row above the list (F-1). The Generate sheet puts *Cancel* top left and *Generate* top right, disabled until the source is ready and accent when it is, with a line saying what is missing. | accepted |
| CR-012 | 2026-10-22 | Owner (UI tweaks) | Onboarding: the hero card shows a checkmark; page 2 shows only the four source types; page 3's hero is the sparkles badge from page 2; the keys note is one line. Library on iPad: search moves from the toolbar to the header row beside sort, and the add button stays top right. Generate sheet: the bottom section has no header and no readiness line; its footer still says the original is kept and names the endpoint. The Markdown picker reads *Pick a markdown file*. | accepted |
| CR-013 | 2026-10-23 | Claude (Phase 4 implementation) | §5.3: listening stops 2 s after the transcript stops changing (Apple's recogniser only marks a result final after it stops); auto-grade then starts on reveal, in the background, and is cancelled when the user grades or moves on, so a late verdict never lands on the next card. *Ask AI to judge* shows only when auto-grade is off or failed. The AI's grade is shown filled; the user's tap is recorded, and a different tap is an override. F-24: AI hints are added from the card sheet (up to three) and the session Hint button reveals the author's hint, then the AI hints, one per tap. F-9: card-sheet AI results open in their own sheet with Discard and Save / Replace / Add. F-26 runs from the quiz's More menu; F-29 is a toolbar button on the quiz. Recent sessions open their per-card outcomes with AI verdicts, overrides, explanations and the recap. | accepted |
| CR-014 | 2026-10-23 | Claude (Phase 5 implementation) | F-20 stays on hold (CR-007), so no study notes, notes phase, *Skip notes* toggle or notes tab. A source too long for the context is split into parts (§7.4); each part gets its share of the cards and the decks are merged, dropping repeated prompts. Non-Topic sources have no *Customise* options yet (the model decides). Generation no longer lints automatically, because AI changes need a tap (ADR-017); *Lint cards* stays on demand. Photos are read on the device with OCR; sending the image to a vision model is not built. Generate queues the job and closes; *Also save JSON* is replaced by the quiz's *Export JSON*. *Regenerate from source* makes a new quiz next to the old one, so history is kept. The share extension cannot open the app; it saves to the App Group inbox and says "Open AIQuiz", and the app drains the inbox on launch and foreground. The clipboard offer is a system Paste button (no permission prompt). New original-content kinds: PDF file (shown with PDFKit, saved text as fallback) and scanned pages (text only). | accepted |
| CR-015 | 2026-10-23 | Claude (Phase 6 implementation) | F-17: `ChoicePlayer` lives in AIQuizCore with the other players (ADR-015). Multiple-choice options are shuffled once per card; a right pick is Correct and a wrong one Wrong, and *Mark as…* overrides to any verdict, shown as "(your call)". Fill-in-the-blank compares each blank ignoring case and spacing; when the short answer has fewer parts than blanks, the last part fills the rest. True/false also accepts yes/no and the Spanish, French and German words. The Choice mode appears on quiz detail when the deck has at least one non-recall card. F-19 card-kind toggles are on Topic generation; other sources stay recall unless cards are converted with *Rewrite › Make multiple choice / fill in the blank / true or false*. The generation schema now carries `kind` and `options` on every card, and a card that breaks D-2 or has an unrequested kind is retried. | accepted |
