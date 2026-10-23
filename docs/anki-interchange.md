# Anki interchange

How AIQuiz reads and writes Anki packages. This is the contract: the app's Swift code
(`Packages/AIQuizCore/Sources/AIQuizCore/Interchange/Anki/`) implements it, and any other
implementation, such as the AIQuiz website, should produce the same quizzes from the same
files. SPEC F-62, DECISIONS ADR-021. How to use it and its known limits: [`anki.md`](anki.md).

**Golden files:** `Packages/AIQuizCore/Tests/AIQuizCoreTests/Fixtures/Anki/`, made by Anki
26.9.3 itself with `tools/anki/make_fixtures.py`. `expected.json` lists, for each package,
the quizzes an importer must produce and Anki's own view of every card's schedule. An
implementation passes when it imports every package to exactly those quizzes.

| File | What it is |
|---|---|
| `latest.apkg` | Current format: `collection.anki21b`, zstd, schema 18 |
| `legacy2.apkg` | "Support older Anki versions": `collection.anki21`, schema 11 |
| `legacy1.apkg` | Anki 2.0 layout: `collection.anki2`, schema 11, deflated entries |
| `collection.colpkg` | A whole-collection backup, current format |
| `fsrs.apkg` | Current format from a collection with FSRS on |
| `aiquiz-via-anki.apkg` | An AIQuiz export, imported into Anki and exported again by Anki |

`tools/anki/verify_export.py` checks an AIQuiz export with Anki's engine.

---

## 1. Reading a package

1. The package is a ZIP (Zip64 for large media). Entries are stored or deflated.
2. Take the newest collection present: `collection.anki21b`, else `collection.anki21`, else
   `collection.anki2`. Current packages also contain a stub `collection.anki2` whose one note
   says "Please update to the latest Anki version"; never read it when `anki21b` exists.
3. `collection.anki21b` is a Zstandard stream (frames may lack a content size). The others
   are plain SQLite.
4. **Schema 11** (`col.ver` 11): note types and decks are JSON in `col.models` and
   `col.decks`. A note type has `type` (1 = cloze), `flds[].name` by `ord`, and
   `tmpls[]` with `ord`, `name`, `qfmt`, `afmt`. Deck names use `::`.
5. **Schema 18**: tables `notetypes`, `fields`, `templates`, `decks`.
   - `notetypes.config` is protobuf `Notetype.Config`; field 1 is the kind (1 = cloze).
   - `templates.config` is protobuf; field 1 is the question format, field 2 the answer.
   - Deck names use `\x1f` between levels.
   - Names are declared `COLLATE unicase`; register a case-insensitive collation of that
     name or SQLite refuses the queries.
6. Both schemas: `notes` (`id`, `mid`, `flds` split on `\x1f`, `tags` space-separated),
   `cards` (`nid`, `did`, `odid`, `ord`, `type`, `queue`, `due`, `ivl`, `factor`, `reps`,
   `lapses`, `data`), `revlog` (`id` in ms, `cid`, `ease`), `col.crt` (seconds).

## 2. Anki → AIQuiz

### 2.1 Quizzes
- One quiz per deck that has cards. A card in a filtered deck belongs to its `odid`.
- Quiz name: the deck path joined with `" › "` (`Spanish::Verbs` → `Spanish › Verbs`).
- Tag `anki`; origin `imported`.
- Cards in order of note id, then template `ord`. One AIQuiz card per Anki card, so a
  "Basic (and reversed card)" note gives two.

### 2.2 Card content
Render the card's template as Anki does, then convert HTML to text.
- Template syntax:
  - `{{Field}}` and `{{#Field}}…{{/Field}}` (shown when the field has text after HTML is
    removed) and `{{^Field}}…{{/Field}}`.
  - Special fields: `{{FrontSide}}`, `{{Tags}}`, `{{Deck}}`, `{{Subdeck}}`, `{{Card}}`,
    `{{Type}}`.
  - Filters apply right to left:
    - `text:` removes HTML.
    - `cloze:` is described below.
    - `type:` is empty on the question side and the field on the answer side.
    - `hint:` is empty.
    - `kanji:` / `furigana:` keep the base text; `kana:` keeps the reading.
    - Unknown filters leave the field unchanged.
- **Prompt:** the rendered question.
- **Long answer:** the rendered answer after `<hr id=answer>`; if the template has no such
  rule, the answer rendered with an empty `{{FrontSide}}`.
- **HTML to text:**
  - `<br>` is a line break (each counts).
  - Block elements (`div`, `p`, `li`, `h1`–`h6`, `tr`, `table`, `blockquote`, `pre`, `hr`)
    make one line break however many meet.
  - A raw newline in HTML is a space. Field text with no markup keeps its own lines.
  - Entities are decoded and `&nbsp;` becomes a space.
  - `<style>` and `<script>` are dropped, as are `[sound:…]` tokens.
  - Every line is trimmed, and blank lines at the ends are removed.
- **Cloze note types** (card `ord` n is deletion c(n+1)):
  - On the question side the active deletion `{{cN::answer::hint}}` becomes `{{blank}}`,
    and the other deletions show their answer text. On the answer side all of them show
    their text.
  - Kind `cloze`.
  - Short answer: the active deletion's answers in order, joined with `|`.
  - Hint: its first non-empty hint.
  - A card whose prompt has no blank is skipped.
- **Other note types:** kind `recall`, no short answer, no hint.
- **Image Occlusion** note types are skipped, as is any card whose prompt or long answer
  renders empty, or which fails AIQuiz's card rules (SPEC D-2). Each is counted as skipped.
- **Media:** `<img>` tags and `[sound:…]` tokens in imported notes are counted (images,
  sounds) and left out; AIQuiz cards are text only.
- **AIQuiz note types** ("AIQuiz", "AIQuiz Cloze" with the fields in §3) are read field by
  field instead, so an AIQuiz export comes back unchanged.

### 2.3 Schedule
- New cards (`type` 0) are new in AIQuiz.
- Otherwise:
  - **Due:** `due` > 10⁹ is seconds since 1970 (learning cards due today); else it is days
    after `col.crt`.
  - **Stability:** `data.s` when present (Anki's FSRS memory), else `ivl` days, else
    FSRS's initial stability for the last rating.
  - **Difficulty:** `data.d` when present, else `5 + (2500 − factor) / 240`, clamped to
    1–10.
  - **Last review:** `data.lrt` (seconds) when present, else the last graded review.
  - **Last rating:** the last graded review's ease, else 3.
  - `reps` and `lapses` carry over.
- **Answer counts from `revlog`:** ease 1 is wrong, 2 partial, 3 and 4 correct. Ease 0 is a
  manual reschedule and is not counted.

## 3. AIQuiz → Anki

- A schema 11 collection named `collection.anki2`, plus a `media` entry `{}`. This is the
  form every Anki version and AnkiDroid imports.
- One deck per quiz: `" › "` becomes `::`, and parent decks are created.
- `col.crt` is the local start of the earliest due day, or of today, so every due day is ≥ 0.
- **Note type "AIQuiz"** for recall, multiple-choice and true-or-false cards.
  - Fields: Front, Back, Short Answer, Hint, Options, Explanation, Mnemonic, Kind.
  - Options are joined with `<br>`. Kind holds the AIQuiz kind.
  - Question: the prompt, the options, and the hint behind Anki's hint link.
  - Answer: `<hr id=answer>`, then the short answer in bold, the long answer, the
    explanation and the mnemonic.
- **Note type "AIQuiz Cloze"** (cloze).
  - Fields: Text, Back Extra, Hint, Explanation, Mnemonic.
  - Every `{{blank}}` becomes `{{c1::answer}}`. AIQuiz asks a card's blanks together, which
    is what one cloze number does.
  - Back Extra holds the long answer.
- Text becomes field HTML by escaping `&`, `<` and `>` and writing line breaks as `<br>`.
- Notes are tagged `AIQuiz`. The checksum is Anki's: the first 8 hex digits of the SHA-1 of
  the sort field's text.
- **Schedule:**
  - New cards are new, in deck order.
  - Reviewed cards are review cards:
    - `due`: days from `crt`.
    - `ivl`: days from the last review to the due date, at least 1.
    - `factor`: `2500 − (difficulty − 5) × 240`, clamped to 1300–3500.
    - `reps` and `lapses` carry over.
    - `data` = `{"s": stability, "d": difficulty, "lrt": last review}`, so Anki with FSRS on
      keeps the memory state.
  - No review log is written.
