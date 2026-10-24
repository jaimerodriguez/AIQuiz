# Anki in AIQuiz

How to move decks between Anki and AIQuiz, how to maintain the code, and what doesn't carry
over yet. Added in Phase 9 (SPEC F-62, CR-018). The decision and its trade-offs are
DECISIONS ADR-021; the exact format rules are [`anki-interchange.md`](anki-interchange.md).

Status: built 2026-10-23, waiting on the owner's check with a real deck.

---

## 1. Using it

### Bring a deck from Anki to AIQuiz
1. **Export it from Anki.** Any format works.
   - **Anki on a Mac or PC:** File › Export, format *Anki Deck Package (.apkg)*. Pick a deck
     or *All Decks*. Keep *Include scheduling information* on to bring your review history.
     Leave *Support older Anki versions* either way.
   - **AnkiMobile or AnkiDroid:** export the deck as a `.apkg` (see each app's manual for the
     menu), then save it to Files or share it straight to AIQuiz. These steps haven't been
     tried yet.
   - **A full backup** (`.colpkg`, *Collection package*) imports every deck in it.
2. **Open it in AIQuiz**, whichever is handiest:
   - + › *Import Anki deck*, then pick the file.
   - In Files, tap the file and choose AIQuiz (or Share › AIQuiz).
   - From another app's share sheet, choose AIQuiz; the import starts when AIQuiz opens.
3. **Read the summary:** how many quizzes and cards arrived, how many reviews are due now,
   and what was left out (images, sounds, cards with nothing to show as text).

What you get:
- One quiz per Anki deck, named after its path ("Spanish › Verbs"), tagged *anki*.
- **Cards:**
  - Basic and reversed cards become recall cards; each Anki card is its own card.
  - Cloze cards become fill-in-the-blank cards, with their hints.
  - "Type in the answer" cards become recall cards.
- **History:** cards that were due in Anki are due in AIQuiz, the rest come back when Anki
  would have shown them, and your right and wrong counts come along.

### Send a quiz from AIQuiz to Anki
1. On a quiz, open the **⋯** menu (or long-press it in the library) › *Export to Anki*.
2. Save the `.apkg` to Files, AirDrop it, or open it in AnkiMobile.
3. In Anki, File › Import (desktop) or tap the file (mobile).

The deck arrives with two note types, "AIQuiz" and "AIQuiz Cloze":
- They carry the short answer, hint, options, explanation and mnemonic. Anki shows the
  hint behind its usual hint link.
- Cards you've studied keep their schedule.
- Importing the file back into AIQuiz gives the same cards.

---

## 2. Maintaining it

- **Code:** `Packages/AIQuizCore/Sources/AIQuizCore/Interchange/Anki/` (reader, renderer,
  mapping, writer); the app side is `AIQuiz/Library/AnkiImportView.swift` and the quiz menu.
- **Tests:** `Packages/AIQuizCore/Tests/AIQuizCoreTests/AnkiTests.swift` against golden files
  in `Fixtures/Anki/`, all made by Anki itself. `expected.json` is the answer key.
- **Rebuild the golden files, or check an export with real Anki.** This needs Python 3.10 or
  later; the scripts pin the official `anki` package (26.9.3).
  ```bash
  python3 -m venv /tmp/anki-venv && /tmp/anki-venv/bin/pip install anki==26.9.3
  ```
  ```bash
  /tmp/anki-venv/bin/python -I tools/anki/make_fixtures.py
  ```
  ```bash
  AIQUIZ_ANKI_EXPORT=/tmp/aiquiz.apkg swift test --package-path Packages/AIQuizCore --filter writeForAnki
  ```
  ```bash
  /tmp/anki-venv/bin/python -I tools/anki/verify_export.py /tmp/aiquiz.apkg Packages/AIQuizCore/Tests/AIQuizCoreTests/Fixtures/Anki/aiquiz-via-anki.apkg
  ```
- **Changing the mapping:** change `anki-interchange.md` and `expected.json` in the same
  commit. The website will test against them too.
- **Dependency:** Meta's [zstd](https://github.com/facebook/zstd), pinned to exactly 1.5.7.
  - It's the only way to read current-format packages on iOS; Apple's Compression framework
    has no Zstandard.
  - Before raising the pin, check its release notes and rerun the tests.
- **Gotcha:** current Anki tables use a `unicase` collation. `SQLiteDatabase` registers one;
  without it every query on those tables fails.

---

## 3. Known issues and limits

Things that work differently from Anki today, roughly in order of how likely they are to be
noticed. Each is a candidate for later work (§4).

| # | Issue | Why | Workaround |
|---|---|---|---|
| A-1 | **Images and audio are dropped.** A card whose only content is an image is skipped. | AIQuiz cards are text only. | The import summary counts what was left out. |
| A-2 | **Image Occlusion cards are skipped.** | They are a picture with boxes over it. | None. |
| A-3 | **Importing the same deck twice makes a second copy.** No merge, no update. | Anki note IDs aren't stored on AIQuiz cards (would need a schema change). | Delete the older quiz. |
| A-4 | **Note tags are dropped.** Quizzes get one tag, *anki*. | AIQuiz tags belong to quizzes, not cards. | Re-tag the quiz. |
| A-5 | **Templates that build text with JavaScript, or use add-on filters, may read oddly.** | AIQuiz renders field references, `#`/`^` sections and the standard filters, and leaves out what Anki hides (anki-interchange §2.2). Text a script would write is missing; an unknown filter shows the raw field. | Edit the card in AIQuiz. |
| A-15 | **Content Anki shows only after a click or hover is left out**, such as a "show more" panel or a hidden extra note. | It starts hidden, and AIQuiz has no scripts to reveal it. This keeps search-tool panels out of answers. | If that content matters, move it into a visible field in Anki before exporting. |
| A-16 | **Nested decks still give one quiz per subdeck, and names can be long.** Shared levels are now dropped except the closest: "Neri's Spanish Sentences [Part 1] › b. Read Training › 2". | The quiz name is the deck path (anki-interchange §2.1). | Rename the quizzes; see §4 item 7. |
| A-6 | **The schedule is close to Anki's, not identical.** Anki scheduler (SM-2 or FSRS-5/6) vs AIQuiz (FSRS-4.5). | Due dates and FSRS memory carry over exactly. Without FSRS, difficulty is estimated from ease. | None needed; it settles after a review or two. |
| A-7 | **Due dates can shift by part of a day.** | Anki counts days from a rollover hour (4 am by default); AIQuiz from midnight. | None needed. |
| A-8 | **Suspended and buried cards come in as normal cards.** | AIQuiz has no suspend. | Delete the cards you don't want. |
| A-9 | **Cards in filtered decks go to their home deck.** | Filtered decks are temporary in Anki. | None needed. |
| A-10 | **Exports carry no review log.** | Only each card's current state is written. | None; Anki's schedule is right, only its history graphs start fresh. |
| A-11 | **A cloze card's blanks export as one Anki card (all `c1`).** | AIQuiz asks a card's blanks together. Anki can't tell which blanks were meant as separate cards. | Renumber in Anki if you want one card per blank. |
| A-12 | **Very large packages:** the collection inside must be under 1 GB compressed and 2 GB uncompressed. Media files are never read, so they don't count. | Safety limits against damaged files. | Export a single deck instead of the whole collection. |
| A-13 | **"Open in AIQuiz" may not be offered for `.apkg` files on some devices.** | AIQuiz declares the type as `net.ankiweb.apkg`. iOS may label the file with another app's type (AnkiMobile's), or a file provider may give it a generic one. | Use Share › AIQuiz or the + menu. |

**Fixed 2026-10-23 (owner report, "Spanish Sentences" shared deck):** long answers carried
everything the note type hides: a language field, "show more", Wiktionary, Google Translate,
DeepL and Reverso search tools, and a note about translations. AIQuiz removed scripts but kept
hidden elements' text. It now leaves out what Anki keeps out of sight (A-15). The fixtures
include a "Sentences (with tools)" note type like that deck's (deck "Phrases").

**Fixed 2026-10-23 (owner report):** *Import Anki deck* greyed out a `.apkg` in Edge's downloads folder. The picker accepted only AIQuiz's declared types, and that file had some other type; which one wasn't confirmed, for the reasons in A-13. The picker now accepts any file and checks the content, and a file that isn't a package gets "This isn't an Anki deck." |
| A-14 | **zstd's compressor is compiled into the app but never used.** | The official package builds the whole library. | None; it only adds to the app's size. |

Seen once while testing, not caused by this feature: in one full live API run, a model
returned an empty card list when generating a mixed-kind quiz (PR #12). It hasn't recurred.

---

## 4. Open decisions for later

These were chosen for the first version and should be revisited (ADR-021):

1. **Media (A-1, A-2).** Store images and audio with cards. Needs a schema change (SchemaV3),
   storage limits and UI. The biggest gap for language and medical decks.
2. **Re-import as update (A-3).** Keep each card's Anki note GUID so importing again updates
   cards and their schedules instead of duplicating. Also a schema change; pairs well with
   (1).
3. **Review log on export (A-10).** Write AIQuiz session outcomes as Anki `revlog` rows so
   Anki's statistics include AIQuiz study.
4. **Multi-quiz export.** Export several quizzes, or the whole library, as one `.apkg`. The
   writer already takes one deck; making it take many is small.
5. **The companion website.** Implement `anki-interchange.md` there and test against the same
   golden files. Decide whether the site writes schema 11 like the app (simplest, imports
   everywhere) or the current format.
6. **Revisit the zstd dependency** if Apple's Compression framework adds Zstandard; it would
   then come out (N-5).
7. **Names for nested decks (A-16).** Decided 2026-10-23 ("our reasonable best, nothing
   risky"): drop the shared levels except the closest, and keep a single deck's whole path.
   Still open: one quiz per top-level deck with subdecks as tags, if one quiz per subdeck
   turns out to be too many.
