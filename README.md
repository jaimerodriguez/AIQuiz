# AIQuiz
A flash card study app for iPadOS. 

## User Experience & features 
- Quizzes are a collection of flash cards, stored in JSON files.  
- You can generate these manually or from your favorite AI Chat bot and import them into the app.  
- Within the app, you an use your OpenAI or Anthropic API key to generate the quizzes from a topic, a markdown file, or a
URL. 


The app has a study mode and a quiz mode: 
- In study mode, the app can read you the questions. It uses Apple's TTS models, so this is not the best. 
- In quiz mode, you can play a standard flash card game, or you can answer via voice and have an LLM judge your knowledge.  

Here is a quick video of these features. This is a utility, so it is minimalistic and not polished. 

https://github.com/user-attachments/assets/e2a43154-0d77-4b82-b561-4aebee12669e



## Details
The entire repo was generated with AI and took only 2 hours
- [`SPEC.md`](SPEC.md) — what the app does and how it behaves.
- [`known_issues.md`](known_issues.md) — the one nasty Swift 6 + AVAudioEngine
  crash this took to root-cause, kept as a record for future refactors.
- `AIQuiz/` — Swift source.
- `Project.yml` + `scripts/deploy.sh` — generate the Xcode project and build
  to a connected iPad.

This started both from the need for a quiz tool and curiosity to see how good Claude Code was for Swift UI. 
With Swift UI, the code generated had issues at first -crashes due to concurrency - but I gave Claude the crash logs and it fixed them promptly.   

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
