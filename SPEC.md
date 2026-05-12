# AIQuiz — Specification (v1)

A native iPad and iPhone flashcard app that loads quizzes from JSON, supports two study modes and one quiz mode, and uses LLMs to generate quizzes from a topic and (optionally) judge spoken answers.

---

## 1. Quiz file format

A quiz is a single JSON file. The app accepts both underscore (`long_answer`) and hyphen (`long-answer`) styles for the answer/hint keys.

```json
{
  "quiz": {
    "name": "Roman Emperors",
    "cards": [
      {
        "prompt": "Who succeeded Augustus?",
        "long_answer": "Tiberius, Augustus's stepson, ruled 14–37 AD.",
        "short_answer": "Tiberius",
        "hint": "He retired to Capri."
      }
    ]
  }
}
```

- `prompt` is required (one or two short lines, ~20–200 chars).
- `long_answer` is required (multi-line, ~20–400 chars).
- `short_answer` is optional (a sharp, one-line summary).
- `hint` is optional (multi-line).
- Any `score` block in the file is **ignored on import**. Scores are managed by the app, not written back to the source.

A malformed file produces a friendly error on import, not a crash.

---

## 2. Quiz library

The library is the home screen. It shows every quiz the user has imported or generated, with the quiz name and two numbers per quiz: **best** session score and **average** session score.

A quiz can come from three sources:

- **Bundled sample** — 2–3 sample quizzes ship with the app.
- **Imported** — JSON file the user picked from Files (iCloud, Dropbox, OneDrive, On My iPad, etc.).
- **AI-generated** — built in-app from a topic.

For each quiz the user can: start a session in any of the three modes, see session history, delete the quiz from the library, or (for imported quizzes whose source file moved or was deleted) re-link the source file.

The library also surfaces a "source missing" indicator on imported quizzes whose bookmark no longer resolves; the cached cards remain playable.

---

## 3. Modes

All three modes use the **smart card ordering** described in §4: cards the user has gotten wrong appear earlier and more often than cards they've mastered.

### 3.1 Study format #1 — Voice auto-read

Hands-free. The app reads each card aloud and advances on its own.

- Reads the prompt, then the short answer (if present), then the long answer.
- Each card is repeated *N* times before advancing, where *N* is configurable in Settings (default 1).
- "Repeat current card" button re-reads the current card from the top.
- "Hint" button reveals the hint inline (disabled when the card has no hint). The spoken "hint" voice command described in earlier drafts is deferred — see `known_issues.md`.
- Skip, Back, Pause, and Abandon controls are available throughout.
- **Swipe navigation:** one-finger swipe right on the card acts as Skip (advances to the next card and restarts playback); swipe left acts as Back. Swipes are ignored at the start/end of the deck.

### 3.2 Study format #2 — User-paced read

Self-paced reading. The user controls advancement with explicit taps.

- Display style is configurable in Settings, with a per-session override:
  - **Flip-card** — prompt only on the front; tap or swipe reveals short + long answer.
  - **All-at-once** — prompt + short + long answer all visible immediately.
- "Next" and "Back" buttons; no auto-advance.
- "Hint" button reveals the hint inline (no voice command needed in this mode).
- **Swipe navigation:** one-finger swipe right on the card moves to the next card (or finishes the session on the last card); swipe left moves back. The tap-to-reveal affordance in flip-card mode still works — short taps do not trigger a swipe.

### 3.3 Quiz format #1 — Voice answer + grade

Active recall. The user answers each prompt out loud and grades themselves.

1. The prompt appears on screen.
2. The user taps the mic and speaks an answer; the transcript appears live.
3. After they stop, a reveal panel shows their transcript next to the correct short and long answers, with three self-grade buttons: **Correct**, **Partial**, **Wrong**.
4. An **Ask AI to judge** button is also available — it sends the transcript and correct answer to the configured LLM and returns a verdict (correct / partial / wrong) plus a one-sentence reason. The user can override the AI verdict.
5. A "Show answer" button skips the voice step and reveals the answer; if the user doesn't grade themselves, the card is treated as Wrong.
6. The Hint button works as in study modes (button-only — the voice "hint" command is deferred; see `known_issues.md`).

Skip, Back, Pause, and Abandon are available throughout.

---

## 4. Card mechanics

### Smart ordering

Card selection during a session is weighted by per-card history:

- Cards the user has gotten wrong more often appear earlier and more frequently.
- Cards the user has mastered appear less often.
- Cards not seen in over 24 hours get a small recency boost.
- New cards (no history yet) sit in the middle of the distribution.

The user does not configure this; it's the only ordering mode.

### Mid-session controls

Every mode supports:

- **Repeat current card** — re-read or re-show the current card.
- **Skip** — move to the next card without recording an answer; card weight is unchanged.
- **Back** — return to the previous card.
- **Pause** — non-destructive; resume keeps the same card.
- **Abandon** — ends the session early and **discards** the partial result. No score is recorded so the user's average isn't penalized for stopping mid-session.

### Session end

- Summary screen with: % correct (Correct = 1, Partial = 0.5, Wrong = 0), counts of each verdict, and a list of the cards the user got wrong or partial.
- Result is saved as a `SessionRecord` and updates the quiz's best and average.
- "Practice missed cards" button starts a new mini-session containing only the wrong/partial cards.

### Score model

- A session's score is `% correct = (sum of verdicts) / (cards graded)`.
- A quiz's **best** = max session % across non-abandoned sessions.
- A quiz's **average** = mean session % across non-abandoned sessions.
- Per-card history (correct/partial/wrong counts and last-seen date) is the basis for smart ordering.

All scores live app-locally; the source JSON is never modified.

---

## 5. AI features

### Provider choice

The user picks among three LLM providers; **OpenAI** and **Claude** require the user to bring their own API key (BYOK), and **Apple Foundation Models** runs on-device with no key (only on devices that support Apple Intelligence).

Generation provider and grading provider can be set independently — for example, on-device for grading and Claude for generation.

The provider picker and key entry sheet appears the first time the user taps an AI feature, not at app launch. Users can change providers and keys later in Settings.

### AI quiz generation

The user can generate a quiz from one of four sources, picked at the top of the generation screen:

1. **Topic** — free-text topic only, no source material.
2. **Markdown file** — a `.md` (or `.markdown`/`.txt`) file picked from Files. The app reads it and passes the content to the LLM.
3. **Pasted text** — a block of markdown or plain text the user types or pastes into the form.
4. **Web URL** — a link to an article or page. The app fetches the page, extracts the main article content (reader-mode style — stripping navigation, ads, scripts, sidebars), and passes the clean text to the LLM. Network or extraction failures show a friendly error and let the user paste the article text instead.

**Form inputs depend on the source:**

- **Topic mode** asks for: topic (required), card count (5–50, default 20), difficulty (intro / intermediate / advanced), output language (defaults to device locale), tone (formal / casual), focus areas (optional), exclude areas (optional).
- **Markdown file, pasted text, and URL modes** ask only for the source itself. The LLM decides card count, difficulty, language, tone, and focus based on the source content — the form deliberately stays minimal in these modes. (If the user wants tight control over those parameters, they can use topic mode instead.)

**Behavior in all modes:**

- Progress indicator while fetching (URL only) and generating.
- Generated quiz always lands in the user's app library.
- The user is offered the option to **also save the JSON to Files** (any storage provider the picker exposes).
- If the model returns malformed JSON, the app retries once. A second failure shows a friendly error.
- If the source content is too large for the chosen provider's context window, the app shows a friendly error and suggests switching provider or shortening the source. (Apple Foundation Models has a smaller window than the cloud providers.)

### AI answer judging

Available in Quiz format #1 as **Ask AI to judge**. Sends the user's transcript and the correct answer to the configured grading provider and displays the verdict (correct / partial / wrong) plus a one-sentence reason. The user can override.

### v2 stretch — Escape to chat

Out of scope for v1, but the design accommodates it: the user can step out of a session into an LLM chat about the current quiz's topic, then return to where they left off.

---

## 6. File import and re-access

- Import via the iOS Files picker — every storage provider exposed by Files (iCloud Drive, Dropbox, OneDrive, Google Drive, On My iPad, etc.) works automatically. Multi-file selection is supported.
- After import, the quiz appears in the library and is playable even when offline (the cards are cached locally).
- The app remembers the source location so the user can re-open the file in subsequent sessions. If the source is moved or deleted, the library shows "source missing" but the cached cards remain playable, and a **Re-link file** action lets the user point at the new location.

---

## 7. Settings

- **AI provider** for generation and grading (selectable independently).
- **API keys** for OpenAI and Claude (stored in Keychain).
- **Appearance** — segmented picker with three options: **System** (default, follows the device's Light/Dark setting), **Light**, **Dark**. The choice applies app-wide, including modal sheets, and is persisted across launches.
- **Reading size** for quiz and study content (see §7.1 below).
- **TTS voice**, rate, and language. The voice picker groups installed voices by language and labels each with its **quality tier** (Default / Enhanced / Premium). When the user selects a voice that iOS hasn't fully downloaded, the picker shows a diagnostic line ("Asked for X but iOS played Y") after the preview so silent fallbacks are visible.
- **STT language** (defaults to device locale).
- **Study #1**: card repeat count (1–5, default 1) and pause between cards.
- **Study #2**: default display style (flip-card or all-at-once).
- **Privacy**: clear API keys, clear quiz library, clear session history.

### 7.1 Reading size

A single, centralised **Reading size** setting controls how large card text is rendered. It has five levels:

1. **Small**
2. **Medium**
3. **Large** (default)
4. **Extra Large**
5. **Huge**

The setting affects three categories of text in study and quiz screens — the **prompt** (largest), the **short-answer emphasis**, and the **long-answer body / hint** — with each level scaling all three together.

**Scope:** the setting deliberately applies only to the screens where the user is actively reading or answering content:

- Study format #1 (Voice auto-read) — prompt, short answer, long answer, hint.
- Study format #2 (User-paced read) — prompt, "tap to reveal" affordance, short answer, long answer, hint.
- Quiz format #1 (Voice answer) — prompt, transcript, short answer, long answer, hint, AI verdict.
- Session summary — the "Cards to review" list.

**Out of scope:** library, quiz detail (mode picker, stats, recent sessions, card list), settings, onboarding, and the Generate-quiz form all use the system Dynamic Type size. This keeps chrome/navigation compact even when the user wants very large study text.

The setting is persistent (UserDefaults) and changes apply immediately to any screen that re-renders.

---

## 8. First-run experience

1. A short onboarding tour (3 screens) introduces the study modes, the quiz mode, and AI generation.
2. The library is pre-populated with 2–3 bundled sample quizzes so the app is usable immediately.
3. LLM provider setup is **lazy** — the user is only prompted to pick a provider and enter a key the first time they use an AI feature.

---

## 9. Permissions

The app requests two iOS permissions, each at the moment it's first needed (not at launch):

- **Microphone** — for Quiz format #1 voice capture and the "hint" voice command.
- **Speech Recognition** — for transcribing voice into text.

---

## 10. Out of scope for v1

- Manual card editing or quiz creation by hand (only AI-generated and imported).
- Escape-to-chat LLM mode.
- iCloud sync of the app's own state (sessions, scores, history) across devices.
- Sharing or exporting score reports.
- Apple Watch companion, widgets, Live Activities.
