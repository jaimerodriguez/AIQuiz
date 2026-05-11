# AIQuiz

A SwiftUI flashcard app for iPad and iPhone that I use to study. Quizzes are
JSON files; the app can also generate them from a topic, a markdown file, or a
URL using OpenAI, Anthropic Claude, or Apple's on-device foundation models. In
quiz mode you answer out loud and either grade yourself or have the LLM judge
your answer.

**This entire repo was generated with AI — zero lines of code written by hand.**
I drove [Claude Code](https://claude.com/claude-code) interactively across a
few sessions; every Swift file, the Xcode project (via xcodegen), the spec,
even this README and `known_issues.md`. It's published as a public sample of
what that workflow can produce end-to-end on a non-trivial native app.

## What's here

- [`SPEC.md`](SPEC.md) — what the app does and how it behaves.
- [`known_issues.md`](known_issues.md) — the one nasty Swift 6 + AVAudioEngine
  crash this took to root-cause, kept as a record for future refactors.
- `AIQuiz/` — Swift source.
- `Project.yml` + `scripts/deploy.sh` — generate the Xcode project and build
  to a connected iPad.

## Build

```sh
brew install xcodegen
xcodegen
open AIQuiz.xcodeproj
```

iOS 18.1+ (iOS 26+ to use Apple on-device foundation models). For on-device
deploy, see `scripts/deploy.sh`.

## Status

Phases 1–7 from the plan are in (library, two study modes, quiz mode with
live voice transcription, scoring with smart card ordering, three LLM
providers, AI quiz generation from four source types). Onboarding polish is
the open phase.
