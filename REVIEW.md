# AIQuiz — Code review, architecture plan, and feature roadmap

Date: 2026-10-22. Scope: every Swift file under `AIQuiz/`, `SPEC.md`, `known_issues.md`, `Project.yml`.

---

## 1. Verdict in brief

The app is a clean, small (~4,100 lines) SwiftUI + SwiftData codebase with strict Swift 6 concurrency turned on and no obvious crashers left. The hard problems (audio-thread isolation, live transcription) are solved and documented. It is a good base.

Three things block the "add lots of AI features" goal:

1. **The Claude provider is broken against today's API.** It sends assistant prefill (`{`) and `temperature`, and targets `claude-opus-4-7`. Current Claude models reject prefill and sampling parameters with HTTP 400. Any Claude call fails right now.
2. **The LLM layer couples transport to use case.** `LLMProvider` has one method per feature (`generateQuiz`, `judgeAnswer`). Every new AI feature means editing three providers and copy-pasting the retry/parse logic a fourth time. That is the opposite of what you need.
3. **There are no tests and no module boundaries.** Everything is one app target. The AI layer, scoring, and parsers are pure logic and should be testable on a Mac without a simulator.

Everything else is polish. The rest of this document is ordered by what to do first.

---

## 2. Map of the code

| Area | Files | Notes |
|---|---|---|
| App shell | `App/AIQuizApp.swift`, `App/RootView.swift` | SwiftData container, seeds samples, applies theme. |
| Models | `Models/Quiz.swift` (JSON payload), `Models/Persistence.swift` (SwiftData `QuizRecord`, `CardRecord`, `SessionRecord`) | Card stats live on `CardRecord`. Session outcomes stored as a JSON blob. |
| Library | `Library/LibraryView`, `QuizDetailView`, `GenerateQuizView`, `SampleQuizzes` | `GenerateQuizView` is 391 lines of form + logic. |
| Modes | `Modes/StudyVoice`, `StudyRead`, `QuizVoice`, `Common/*` | Two modes have an `@Observable` player; `StudyRead` keeps logic in the view. |
| Services | `TTSService`, `STTService`, `VoiceCatalog`, `ScoreStore`, `FileImportService`, `ContentExtractor`, `DebugLog` | All singletons. |
| LLM | `Services/LLM/*` | Protocol + 3 providers + `PromptBuilder` + `LLMResponseParser`. |
| Settings | `AppSettings`, `ProviderRegistry`, `KeychainStore`, two views | UserDefaults-backed `@Observable` classes. |

Build: `xcodegen` from `Project.yml`, iOS 18.1+, Swift 6 strict concurrency, no SPM packages, no test target.

---

## 3. Bugs and SPEC drift found

Ordered by severity.

### 3.1 Claude provider cannot succeed (bug)
`ClaudeProvider.swift:12,23,62,68`. Three problems in one request:
- Prefill (`{"role":"assistant","content":"{"}`) returns 400 on every current Claude model.
- `temperature` returns 400 on Opus 4.7 and later.
- `anthropic-version: 2023-06-01` is stale. Current is `2026-10-21`.

Fix is part of the provider rewrite in §5. Short term, remove prefill and `temperature`, and use `output_config.format` for JSON.

### 3.2 "Practice missed cards" is specified but not wired
`SessionSummaryView` supports `onPracticeMissed`; `QuizVoiceView.swift:155` passes `nil`. `ScoreStore.makeDeck(cards:)` exists for exactly this and has no callers. SPEC §4 promises the button.

### 3.3 Source re-link and "source missing" are not implemented
SPEC §2 and §6. `FileImportService.resolveBookmark` exists and is never called. The library never checks whether a bookmark still resolves. Imported quizzes work from the cached cards only, which is fine, but the UI promised in the spec is absent.

### 3.4 Dead Objective-C bridge
`ExceptionCatcher.h/.m` and the bridging header are referenced nowhere. Delete them and drop `SWIFT_OBJC_BRIDGING_HEADER` from `Project.yml`. It removes an ObjC compile unit and the bridging-header build setting for no loss.

### 3.5 `FileImportService` is an `actor` whose every method is `@MainActor`
The actor isolation buys nothing. Either make it an `enum` of static `@MainActor` functions, or do the file read + JSON decode off the main actor and only insert into the `ModelContext` on main.

### 3.6 Smart ordering only reorders; it does not change frequency
SPEC §4 says hard cards "appear earlier and more often." `ScoreStore.makeDeck` always includes every card exactly once (`cardLimit` is never passed), so only order changes. Either drop "more often" from the spec or implement real scheduling (see §4.6).

### 3.7 Settings promised by SPEC §7 that do not exist
- STT language picker (code always uses `Locale.current`).
- Privacy: "clear quiz library" and "clear session history" (only "clear API keys" exists).
- Onboarding tour (SPEC §8). README already notes this as open.

### 3.8 Smaller issues
- `ProviderRegistry.validate` has a dead `_ = key` line. `isAvailable` on cloud providers is `apiKey != nil`, so an empty string counts as available while `validate` rejects it. Pick one rule.
- HTTP error bodies are shown to the user verbatim (`"Claude HTTP 400: {...}"`). Map to friendly text and keep the body in the log.
- `ContentExtractor.fetchAndExtract` uses `NSAttributedString(html:)`. That is WebKit-backed, main-thread-only, slow on long pages, sends no User-Agent, and is not reader-mode: nav, footers and cookie banners all go to the model.
- `GenerateQuizView.buildRequest` throws a fake `ExtractError.empty(URL(string: "file://")!)` for the "no markdown loaded" case. Add a real error case.
- `TTSService.speak` and `STTService.startListening` each set a different `AVAudioSession` category. It works today only because no screen does both. The first feature that reads a prompt aloud and then listens will fight over the session.
- `DebugLog` does synchronous file I/O with `synchronize()` on every call, on whatever thread calls it. Fine for a debug build, wrong for release. It also logs the audio route and transcripts, which you may not want on disk.
- Bundle id prefix (`com.jaimer.aiquiz`), product bundle id (`com.jaimerodriguez.aiquiz`) and Keychain service (`com.jaimer.aiquiz`) disagree. Harmless, but tidy it before anything ships to TestFlight.
- No `PrivacyInfo.xcprivacy`. Required for App Store submission because the app uses UserDefaults.

---

## 4. Refactoring recommendations

Ordered by payoff. Items 4.1 to 4.3 are prerequisites for the feature list; the rest can be done opportunistically.

### 4.1 Split the app into local Swift packages and add tests
Create `Packages/AIQuizCore` (models, `SessionDeck`, scoring, JSON parsing, prompt builders) and `Packages/LLMKit` (the provider layer from §5). Keep UI, speech, and SwiftData in the app target. XcodeGen supports local packages via `packages:` + `dependencies: [{package: ...}]`.

Why: both packages are pure Swift with no UIKit dependency. `swift test` runs them on the Mac in seconds, which is where all the parser, retry, scheduling, and provider-wire-format tests belong. Today nothing can be tested without a device or simulator.

First tests to write: `LLMResponseParser.extractJSONObject` (fences, nested braces, prose around JSON), `CardPayload` decoding (underscore vs hyphen keys, missing required key), `ScoreStore.weight`, `SessionDeck` transitions, and one golden request/response fixture per provider wire format using a `URLProtocol` stub.

### 4.2 Replace the `LLMProvider` protocol with a transport/use-case split
Detailed in §5. The one-line version: a provider knows how to send a chat request and get text (or schema-constrained JSON) back. It knows nothing about quizzes. Quiz generation, judging, summarising, and tutoring are functions written once against that interface.

### 4.3 Inject dependencies through the SwiftUI environment
`AppSettings.shared` is read directly in 10 places and `ProviderRegistry.shared` in 7, including inside view bodies. `TTSService`/`STTService` are reached through `.shared` from the players. This blocks previews with fake data, blocks unit tests of the players, and hides which views depend on what.

- `AppSettings`, `ProviderRegistry` (renamed `AIRouter`, see §5.4): inject with `.environment(settings)` at the root and read with `@Environment(AppSettings.self)`.
- Put protocols in front of speech: `protocol SpeechSynthesizing { func speak(_:) async; func stop() }` and `protocol SpeechRecognizing { ... }`. The players take the protocol in `init`. Keep the concrete classes as they are; the `@Sendable` closure fix in `STTService` stays untouched.

### 4.4 Extract the shared session UI
`StudyVoiceView`, `StudyReadView`, and `QuizVoiceView` each re-implement: the progress header, the card face (prompt / short / long / hint box), the "End session?" alert, the swipe gesture, and the record-session-once guard. Extract:

- `CardFaceView(card:, reveal: .promptOnly | .all, hintRevealed:)`.
- `SessionProgressHeader(deck:, trailing:)`.
- `.endSessionConfirmation(isPresented:, onEnd:)` view modifier.
- `.swipeToNavigate(onNext:, onBack:)` view modifier.
- `HintButton` already exists; use it in all three modes instead of two inline copies of the yellow box.

Then give `StudyReadView` a `StudyReadPlayer` so all three modes have the same shape: view = dumb, player = state machine. The players become testable and new modes (multiple choice, cloze, timed exam) are a new player plus a thin view.

### 4.5 One `AudioSessionCoordinator`
A single `@MainActor` object owns `AVAudioSession` category changes with two entry points: `beginPlayback()` and `beginRecording()`, each idempotent, plus `end()`. `TTSService` and `STTService` call it instead of touching the session themselves. This is required before any feature that alternates speaking and listening on one screen (oral exam, "read the prompt then listen").

### 4.6 Data model additions and a migration plan
SwiftData has no schema versioning in this project. Before touching any `@Model`, add `VersionedSchema` + `SchemaMigrationPlan` so existing libraries on your iPad survive the change.

Add to `QuizRecord`: `tags: [String]`, `sourceKind` (bundled / imported / topic / markdown / url / pdf …), `sourceURLString`, `language`, `generatedBy` (endpoint name + model), `summaryMarkdown` (for the summarise-then-quiz feature), `createdAt`.

Add to `CardRecord`: `kind` (`recall`, `multipleChoice`, `cloze`, `trueFalse`), `optionsData` (for MCQ distractors), `explanation`, `mnemonic`, and scheduling fields for real spaced repetition: `stability`, `difficulty`, `dueAt`, `reps`, `lapses`, `lastRating`. FSRS is the algorithm to copy; it is open, small, and well documented. `ScoreStore.smartWeightedOrder` then becomes "due cards first, then new, then the rest", which also fixes §3.6.

Add to `SessionRecord`: `durationSeconds`, `aiVerdictsData` (so you can later compare self-grade vs AI grade), `endpointUsed`.

### 4.7 Make `GenerateQuizView` a view over a model
Move `buildRequest`, `generate`, `saveQuiz`, validation, and the export encoding into an `@Observable GenerateQuizModel`. The view becomes a form. Same for `ProviderSettingsView`, which will need to manage a dynamic list of endpoints (§5.4).

### 4.8 Networking hygiene
One `HTTPClient` wrapper used by all providers and `ContentExtractor`: timeouts (generation needs 120–300 s), retry with exponential backoff on 429/5xx and honour `Retry-After`, typed errors (`unauthorized`, `rateLimited`, `contextTooLong`, `server`, `network`, `cancelled`), and no raw bodies in user-facing strings. Make every call cancellable through `Task` cancellation (URLSession's async API already is) and cancel on view disappear.

### 4.9 Content extraction
Replace `NSAttributedString(html:)` with a real reader-mode pass. Two viable options:
- **SwiftSoup** + a small Readability-style scorer (pick the `<article>`/`<main>` or the densest text block, drop `nav/aside/footer/script/style`). Pure Swift, runs off main.
- **Hidden `WKWebView` + Readability.js** (the Firefox reader library). Heavier but handles JavaScript-rendered pages.

Set a browser-like User-Agent either way. Add PDF text via `PDFKit` (`PDFDocument.string`) as a fourth source; it is a few lines.

### 4.10 Logging
Use `os.Logger` with subsystem/category and `privacy: .private` for transcripts and keys. Keep the file logger behind a Settings toggle for field debugging. Never log API keys (currently not logged, keep it that way).

---

## 5. AI provider architecture

### 5.1 Goal and constraints
- Call **Anthropic** and **OpenAI** directly with the user's own keys. No middleman.
- Support **local models**. Almost every local server (Ollama, LM Studio, llama.cpp server, vLLM, MLX server) exposes the OpenAI Chat Completions wire format. So "local" is not a third protocol; it is the OpenAI client with a different base URL and no key.
- Keep **Apple on-device** (FoundationModels) as the free option on supported devices.
- Make adding a new AI feature a matter of writing one function, not three.

### 5.2 Recommendation: hand-rolled, two wire formats, one abstraction
Do not add an aggregator SDK. There are only two wire formats to speak plus the native Apple API, the request shapes are small, and you need streaming and structured output from both. A thin layer of roughly 500 lines gives you full control, no dependency churn, and easy tests. Community Swift SDKs exist for both vendors but add weight for little gain here. Note that OpenRouter is itself an OpenAI-compatible endpoint, so a user who prefers one key for everything can add it as an endpoint preset without any new code.

### 5.3 The abstraction (sketch)

```swift
// Packages/LLMKit — transport level. Knows nothing about quizzes.

public struct LLMEndpoint: Codable, Identifiable, Sendable, Hashable {
    public enum Kind: String, Codable { case openAICompatible, anthropic, appleOnDevice }
    public var id: UUID
    public var kind: Kind
    public var name: String            // "Anthropic", "OpenAI", "Ollama on Mac mini"
    public var baseURL: URL?           // nil for appleOnDevice
    public var model: String           // user-editable; populated from /v1/models where available
    public var keychainAccount: String?
    public var contextWindowTokens: Int
    public var supportsJSONSchema: Bool
    public var supportsVision: Bool
}

public enum ContentPart: Sendable { case text(String); case image(Data, mimeType: String) }
public struct ChatMessage: Sendable { public enum Role { case user, assistant }; var role: Role; var parts: [ContentPart] }

public struct ChatRequest: Sendable {
    public var system: String
    public var messages: [ChatMessage]
    public var maxTokens: Int = 16_000
    public var jsonSchema: JSONSchema? = nil   // nil = free text
    public var effort: Effort = .medium        // maps to output_config.effort / reasoning_effort / ignored
}

public struct TokenUsage: Sendable { var input: Int; var output: Int; var cacheRead: Int }
public struct ChatResponse: Sendable { var text: String; var usage: TokenUsage; var stop: StopReason }
public enum ChatEvent: Sendable { case delta(String); case usage(TokenUsage); case done(ChatResponse) }

public protocol LLMClient: Sendable {
    var endpoint: LLMEndpoint { get }
    func complete(_ request: ChatRequest) async throws -> ChatResponse
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]     // "Test connection" button
}

// Structured-output helper shared by every feature: one retry with the decode error fed back.
public struct StructuredTask<Output: Decodable & Sendable>: Sendable {
    var system: String; var user: String; var schema: JSONSchema; var maxRetries = 1
}
public extension LLMClient {
    func run<T>(_ task: StructuredTask<T>) async throws -> T { /* complete → decode → retry once */ }
}
```

Use cases live next to it and are written once:

```swift
// Packages/AIQuizCore — feature level. Takes any LLMClient.
public enum QuizGenerator   { static func generate(_ req: QuizGenRequest, using: LLMClient) async throws -> QuizPayload }
public enum AnswerJudge     { static func judge(_ req: JudgeRequest, using: LLMClient) async throws -> JudgeVerdict }
public enum Summarizer      { static func summarize(_ text: String, using: LLMClient) async throws -> String }
public enum CardExpander    { static func expand(_ card: CardPayload, using: LLMClient) async throws -> [CardPayload] }
public final class TutorChat { /* holds [ChatMessage], streams replies via client.stream */ }
```

Each is: a prompt, a `Decodable` output type, its JSON schema, and a call to `client.run(...)`. Adding "generate mnemonics" is one new enum, zero provider edits.

### 5.4 Routing and settings
Replace `ProviderRegistry` with an `AIRouter` that owns `[LLMEndpoint]` (persisted as JSON in UserDefaults; keys in Keychain) and a `[Purpose: LLMEndpoint.ID]` map. Purposes: `generation`, `grading`, `chat`, `summary`. Each resolves to a client via `makeClient(endpoint)`. An optional fallback chain per purpose (e.g. "Apple on-device, else Anthropic") is cheap to add here and nowhere else.

Settings UI becomes an endpoint list: built-in presets for Anthropic, OpenAI, Ollama (`http://<host>:11434/v1`), LM Studio (`http://<host>:1234/v1`), OpenRouter, plus "Custom". Each row: name, base URL, key (SecureField), model picker fed by `listModels()`, a "Test" button, and a cost line fed by `TokenUsage` totals.

iOS detail for local endpoints: plain-HTTP LAN calls need `NSAllowsLocalNetworking` under App Transport Security and `NSLocalNetworkUsageDescription` in `Info.plist`, or iOS silently blocks them.

### 5.5 Per-provider specifics

**Anthropic (`/v1/messages`)**
- Headers: `x-api-key`, `anthropic-version: 2026-10-21`, `content-type`.
- Body: `model`, `max_tokens` (16 000 non-streaming, higher when streaming), `system`, `messages`, `stream`. No `temperature`, no prefill.
- JSON: `output_config: { format: { type: "json_schema", schema: {...} } }`. Schemas need `additionalProperties: false` on every object and no numeric/string constraints. Add `effort` under the same `output_config` (`low` is right for grading, `medium` for generation).
- Streaming: SSE. Text arrives in `content_block_delta` events with `delta.type == "text_delta"`; usage in `message_delta`.
- Default model: `claude-opus-5-5`. Expose the model as an editable field; a user may choose `claude-haiku-5-5` for grading to cut cost.
- Later: `cache_control` on the source-document block when generating several decks from the same article.

**OpenAI-compatible (`{baseURL}/chat/completions`)**
- Header `Authorization: Bearer` only when a key is set (local servers have none).
- JSON: `response_format: { type: "json_schema", json_schema: { name, strict: true, schema } }`. On a 400 that mentions `response_format`, degrade to `{ type: "json_object" }`, then to prompt-only. That single fallback ladder makes the one client work for OpenAI, Ollama, LM Studio, llama.cpp, vLLM, and OpenRouter.
- Streaming: SSE, text in `choices[0].delta.content`, terminated by `data: [DONE]`.
- Model: do not hardcode (`gpt-4o` is stale). Populate from `GET {baseURL}/models` and let the user pick.

**Apple on-device (FoundationModels, iOS 26)**
- Keep JSON-in-text with the existing parser for v1. Next step is `DynamicGenerationSchema`, which lets you build the schema at runtime from the same `JSONSchema` value the cloud clients use, so the use-case code stays identical.
- Context is small. Keep the per-endpoint `contextWindowTokens` and estimate tokens as `characters / 4`; chunk-and-merge for long sources (summarise each chunk, then generate from the summaries).

**Fully on-device open models (later)**
If you want a no-network local option on an M-series iPad, `mlx-swift` or `llama.cpp` can back a fourth `LLMClient.Kind`. It is a large dependency and a download-management UI; the LAN route gives you local models today with no app complexity.

### 5.6 Shared infrastructure
- One SSE line parser used by both clients.
- One `HTTPClient` (§4.8) for retry/backoff/timeouts/typed errors.
- A `FakeLLMClient` that returns canned responses or scripted streams, used by unit tests and SwiftUI previews.
- Usage accounting: every `ChatResponse` carries `TokenUsage`; `AIRouter` accumulates per endpoint for a "spend this month" line in Settings.

---

## 6. Feature ideas

Grouped by theme. Each line names what the user gets and what it needs from §5. "Structured" means a `StructuredTask`; "stream" means `client.stream`.

### 6.1 Turn any content into a quiz (ingestion)
1. **Summarise, then quiz.** Paste/URL/file → AI writes a study summary (stored on the quiz as `summaryMarkdown`, shown as a "Notes" tab) → cards are generated from the summary. Structured + stream for the summary.
2. **PDF source.** `PDFKit` text extraction, then the same pipeline. Scanned PDFs via `Vision` OCR.
3. **Photo of a page or whiteboard.** Camera → `VisionKit` document scanner → OCR → quiz. Or send the image directly to a vision-capable endpoint.
4. **YouTube / podcast / lecture.** Record a lecture or pull a YouTube transcript → summarise → quiz. On-device transcription with iOS 26 `SpeechAnalyzer` for long audio.
5. **Share extension.** "Share to AIQuiz" from Safari, Notes, Files, Mail. Highest-leverage ingestion feature; it is UI plumbing on top of the existing URL/text path.
6. **Obsidian / Notion / folder import.** Pick a folder of markdown; generate one quiz per file or one merged deck. Keep bookmarks so "Refresh from source" can regenerate when notes change.
7. **Anki import/export.** Read `.apkg` basics (SQLite inside a zip) and write CSV/`.apkg`. Opens a large existing deck ecosystem.
8. **Clipboard detection.** If the pasteboard holds a URL or a long text when the user opens Generate, offer it.

### 6.2 Better cards
9. **Multiple card types.** Multiple choice with AI-written distractors, cloze deletion, true/false, ordering, "explain in your own words". Needs `CardRecord.kind` + `optionsData` and a player per type.
10. **Difficulty calibration.** AI rates each card 1–5; used for ordering and for "easy / hard" filters.
11. **Card lint.** AI flags ambiguous prompts, leaky hints, duplicates, and answers that are too long to speak. Run on import and on generate.
12. **Expand a card.** From a card you keep missing, generate 3–5 deeper or prerequisite cards.
13. **Rewrite a card.** Simplify, make harder, translate, shorten the long answer for TTS.
14. **Mnemonic and analogy generator.** On demand, stored on the card.
15. **Progressive hints.** For cards without a hint, generate one on demand, then a stronger one. Hints are stored so later sessions do not pay again.
16. **Auto-tag and auto-name.** Tags per card and per quiz; "Roman Emperors" becomes browsable by era.
17. **Translate a deck.** Bilingual cards for language learning, with the TTS voice switched per side.

### 6.3 Smarter sessions
18. **AI grading by default.** Grade in the background after each answer and show the verdict with the reveal; keep self-grade as an override. Record both so you can see where you and the model disagree.
19. **Batch grading at session end.** One request for all answers instead of one per card. Cheaper and faster; works well with Haiku-class models.
20. **Oral exam mode.** Multi-turn: AI asks a question, hears the answer, asks a follow-up aimed at the gap, then scores against a rubric. Needs `AudioSessionCoordinator`, stream, and TTS for the examiner's voice.
21. **Feynman / teach-back mode.** Talk for two minutes about the topic. AI lists what you covered, what you missed, and generates cards for the gaps.
22. **Socratic tutor (SPEC v2 "escape to chat").** A chat sheet pre-loaded with the current card and quiz context. Stream. Return to the exact card afterwards.
23. **"Why was I wrong?"** One-tap explanation that contrasts your transcript with the reference answer.
24. **Pre-test placement.** Five quick questions estimate your level, then the deck generates at that difficulty.
25. **Timed exam simulation.** Mixed card types, no hints, strict time, AI-written exam-style questions for a named certification or course.
26. **Podcast mode.** AI writes a 5-minute spoken lesson from the deck; TTS reads it. For walks and commutes.
27. **Challenge mode.** After a correct answer the AI poses a counterexample or edge case to test depth.

### 6.4 Memory and planning (mostly not AI, but AI makes them shine)
28. **Spaced repetition (FSRS) and a "Due today" queue across all quizzes.** The single biggest retention improvement; notifications when cards are due.
29. **Weekly insight.** AI reads session history and writes one paragraph: patterns, confusions ("you swap Tiberius and Claudius"), what to drill. Generates a targeted deck.
30. **Study plan.** "Exam on X in 12 days" → daily schedule across decks, adjusted by results.
31. **Session recap.** After each session, two sentences from the AI on what went well and what to revisit.
32. **Knowledge graph.** Embeddings (on-device via `NLEmbedding`, or an embeddings endpoint) link related cards across decks; "related cards" on the detail screen; duplicate detection on import.

### 6.5 Voice quality
33. **Cloud TTS option.** OpenAI's speech endpoint or ElevenLabs behind the `SpeechSynthesizing` protocol, cached per card so a deck is synthesised once. Apple voices are the main reason the README calls study mode "not the best".
34. **Better STT.** iOS 26 `SpeechAnalyzer` on-device, or Whisper via the OpenAI audio endpoint, behind `SpeechRecognizing`.
35. **Spoken "hint" command.** The deferred feature from `known_issues.md`; small once the audio coordinator exists.

### 6.6 System integration
36. **Siri / App Intents.** "Quiz me on Roman emperors", "Start my due cards". Shortcuts automation.
37. **Widgets and Live Activity.** Due-card count; a running session on the Lock Screen.
38. **Background generation.** Long sources generate in a background task; a local notification says "Your deck is ready".
39. **Cost meter.** Tokens and estimated cost per endpoint, per session, per month.
40. **iCloud sync** of the SwiftData store (currently out of scope in SPEC §10, but `ModelConfiguration(cloudKitDatabase:)` makes it modest work once the schema is versioned).

---

## 7. Suggested order of work

1. **Foundation PR.** `Packages/LLMKit` + `Packages/AIQuizCore`, the `LLMClient` abstraction, Anthropic and OpenAI-compatible clients with structured output and streaming, `AIRouter` with the endpoint list UI, `FakeLLMClient`, tests, delete the ObjC bridge. This fixes the broken Claude path and unlocks everything below. Expect the app to behave identically to today when done.
2. **Schema versioning + model additions** (§4.6) in their own PR, with a migration tested against a copy of your real store.
3. **Quick wins on the new base:** practice-missed wiring, AI grading by default, "why was I wrong", progressive hints, card lint.
4. **Summarise-then-quiz + PDF + share extension.** The ingestion trio.
5. **Card types** (MCQ, cloze) with their players, after the session-UI extraction in §4.4.
6. **FSRS + due queue + notifications.**
7. **Tutor chat and oral exam** once `AudioSessionCoordinator` exists.

Each step is independently shippable and testable, and none requires revisiting the provider layer again.
