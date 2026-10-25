<p align="center">
  <img src="AIQuiz/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" alt="The AIQuiz icon: a coral tutor pointing something out over an open book">
</p>

# AIQuiz

A flashcard app for iPad and iPhone that uses AI as your teacher, grader and study companion. It's built around **active recall**: you answer from memory, out loud or by tapping, and the app grades you, explains what you missed, and brings each card back when you're about to forget it.

<!-- Media: a 30–60 second overview video goes here (docs/media/overview.mp4, or a GitHub user-attachments link). -->

## What it does

### Make quizzes from anything
- **From a topic:** describe what you want to learn; the AI writes the cards. Choose recall, multiple-choice, fill-in-the-blank and true-or-false cards.
- **From a web page, a document or photos:** pages are reduced to the article, PDFs are read page by page (with text recognition for scans), and photos of notes or textbook pages are read on the device. Long sources are split and the cards merged.
- **From pasted text**, or **a batch of links**, one quiz per link.
- **Share to AIQuiz** from Safari, Files, Photos or any app.
- Generation runs in the background: keep studying while the library shows each job's progress, and get a notification when a quiz is ready.
- **Read Source Materials** keeps the original page, file or text with the quiz, so you can go back to it.
- **Import** JSON quizzes (from your favourite chatbot, say) and **Anki decks** (`.apkg`, `.colpkg`), with their review history.

<!-- Media: the + menu, and the library showing a quiz generating. -->

### Study and quiz modes

| Mode | How it works |
|---|---|
| **Study — Voice** | The app reads each card to you, hands-free. Say "hint" to hear the hint. |
| **Study — Read** | Flip cards at your own pace. |
| **Quiz — Voice** | Answer out loud. The AI grades your answer (Correct, Partial or Wrong) with a one-line reason. Turn on auto-listen and the microphone opens by itself after a short countdown, for a quiz with no tapping at all. |
| **Quiz — Choice** | Multiple choice, fill in the blank and true or false, with instant feedback. |
| **Oral exam** | An examiner asks 5 to 10 questions aloud, asks a follow-up when an answer is vague, then grades every card and sums up. |

Every session ends with a summary and a short recap from the AI, and **Practice missed cards** starts a session with only the cards you got wrong.

<!-- Media: Quiz — Voice with an AI verdict, and the session summary. -->

### An AI companion, not just a grader
- **Why was I wrong?** compares your answer with the right one.
- **Hints** that get stronger with each tap.
- **On any card:** Explain, Mnemonic, Expand (3 to 5 new cards) and Rewrite (simpler, harder, shorter, translated, or another card type).
- **Tutor chat** during any session or on any quiz: ask about the card you're on, get an analogy, or have it quiz you, then turn the conversation into new cards.
- **Lint cards** finds ambiguous, duplicate and leaky cards, with fixes.
- **Insights** reads your history, names your strengths and what you mix up, and builds a drill deck for the gaps.

<!-- Media: tutor chat, and Insights. -->

### Remember it for good
- **Spaced repetition (FSRS):** every graded card is scheduled. Right answers come back after longer gaps, wrong ones the same day.
- **Due today** at the top of the library reviews what's due across every quiz.
- An optional **daily reminder** says how many cards are due.

### Keep a big library tidy
- **Folders**, nested as deep as you like. Each folder shows how many quizzes it holds and how many cards are due.
- **Search** names and `#tags` across the whole library, with each result's folder.
- Sort, tag, archive, rename, move and edit any card.
- **Export** a quiz as JSON or as an Anki deck. Folders travel with it, so a round trip keeps the structure.

<!-- Media: the library with folders, on iPad and iPhone. -->

### Your choice of AI
- **Anthropic** (Claude), **OpenAI**, and any OpenAI-compatible server, including local ones such as Ollama and LM Studio.
- **Apple's on-device model**, on devices with Apple Intelligence.
- Route each task (generation, grading, chat) to the endpoint you choose, with fallbacks. Settings shows each month's token use and estimated cost.
- **Your keys stay in the Keychain** on your device. The app never logs your answers, your sources or your keys, unless you turn on the debug log yourself.

## Screenshots

<!-- Media: a table of iPad and iPhone screenshots (docs/media/). -->

## Requirements

- iPad or iPhone running iOS / iPadOS 26 or later.
- An API key for Anthropic or OpenAI, a local OpenAI-compatible server, or a device with Apple Intelligence. Without one, the study modes and the Anki/JSON import still work.

## Build and run

```bash
brew install xcodegen
```

```bash
xcodegen
```

```bash
open AIQuiz.xcodeproj
```

The Xcode project is generated from `Project.yml`; don't edit it by hand. To build and install on a connected iPad, run `scripts/deploy.sh`.

Run every test (Swift packages, then app and UI tests on the iPad simulator):

```bash
scripts/test.sh
```

The live AI tests spend a few cents and are opt-in: `scripts/live-test.sh` reads test keys from your macOS Keychain.

## How the code is organised

- `AIQuiz/`: the SwiftUI app (SwiftData library, players for each mode, screens).
- `AIQuizShare/`: the share extension.
- `Packages/AIQuizCore/`: everything that isn't UI (quiz format, scheduling, prompts, ingestion, Anki interchange, folders), tested with `swift test`.
- `Packages/LLMKit/`: one client interface for Anthropic, OpenAI-compatible servers and Apple's on-device model.
- `Tests/`: app and UI tests.

## Project documents

- [`SPEC.md`](SPEC.md): what the app does, requirement by requirement, and every change request.
- [`PLAN.md`](PLAN.md): the phased plan and the test bar for each phase.
- [`DECISIONS.md`](DECISIONS.md): architecture decisions, with the trade-offs.
- [`CHANGELOG.md`](CHANGELOG.md): what changed, by date.
- [`docs/anki.md`](docs/anki.md) and [`docs/anki-interchange.md`](docs/anki-interchange.md): Anki import and export, and the exchange format.
- [`known_issues.md`](known_issues.md): traps found along the way, such as a Swift 6 and AVAudioEngine crash.
- [`CLAUDE.md`](CLAUDE.md): the operating guide for AI agents working on the code.

## How it was built

AIQuiz started from the need for a quiz tool and curiosity about how good Claude Code is at SwiftUI. The first version was generated with AI in about two hours. It had its rough spots, crashes from Swift concurrency among them, and Claude fixed them from the crash logs.

Version 1.1 was built the same way, phase by phase, with Claude Code: a written spec and plan, tests at every layer, simulator and on-device checks, and the owner's library backed up and migrated at every schema change.
