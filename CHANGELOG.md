# Changelog

All notable changes to AIQuiz. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow `MARKETING_VERSION` in `Project.yml`. Entries are date-stamped so the history of a version in development stays readable.

## [1.1.0] — in development

### 2026-10-22
- **Docs:** added `REVIEW.md` (code review and rationale), rewrote `SPEC.md` as v2 with requirement IDs and a Change requests section, added `PLAN.md` (phased implementation plan with the test bar per phase), `CLAUDE.md` (operating guide for implementing agents), `DECISIONS.md` (architecture decision records) and this changelog.
- **Process:** `claude` is the integration branch; phase branches merge into it (DECISIONS ADR-001).
- **Phase 0 (test scaffolding):** in progress. See PLAN.md §2 Phase 0.

## [0.1.0] — 2026-10-21
State of the app before this effort: library with bundled samples and JSON import, two study modes, voice quiz mode with live transcription and optional AI judging, AI quiz generation from topic / markdown / pasted text / URL via OpenAI, Anthropic or Apple on-device, settings for voice, reading size and appearance. See git history on `main` up to `2e94e8f`.
