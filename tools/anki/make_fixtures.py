"""Build the Anki interchange fixtures with Anki's own engine (docs/anki-interchange.md).

Run with the official `anki` package (PyPI, by the Anki Team), version pinned below:

    python3 -m venv /tmp/anki-venv && /tmp/anki-venv/bin/pip install anki==26.9.3
    /tmp/anki-venv/bin/python -I tools/anki/make_fixtures.py

Writes to Packages/AIQuizCore/Tests/AIQuizCoreTests/Fixtures/Anki/:
  latest.apkg      current format: collection.anki21b, zstd
  legacy2.apkg     "Support older Anki versions": collection.anki21, schema 11
  legacy1.apkg     Anki 2.0 layout: collection.anki2, schema 11 (legacy2 with the entry renamed)
  collection.colpkg  a whole-collection backup, current format
  fsrs.apkg        current format from a collection with FSRS on
  expected.json    what an importer must produce from each package, written from the notes
                   below and from Anki's own view of each card's schedule

Any implementation of the interchange (the app's, a website's) can test against these files.
"""

import json
import os
import shutil
import sys
import tempfile
import zipfile

from anki.collection import Collection, ExportAnkiPackageOptions

ANKI_VERSION = "26.9.3"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Packages", "AIQuizCore", "Tests", "AIQuizCoreTests", "Fixtures", "Anki")

# A tiny PNG and a few bytes standing in for an MP3: media an importer must count and skip.
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")
MP3 = b"ID3\x03\x00\x00\x00\x00\x00\x00fixture"


def build(path, fsrs=False):
    col = Collection(path)
    if fsrs:
        col.set_config("fsrs", True)
    models = col.models
    basic = models.by_name("Basic")
    reversed_ = models.by_name("Basic (and reversed card)")
    typein = models.by_name("Basic (type in the answer)")
    cloze = models.by_name("Cloze")
    verbs = col.decks.id("Spanish::Verbs")
    geo = col.decks.id("Geography")
    col.media.write_data("perro.png", PNG)
    col.media.write_data("perro.mp3", MP3)

    def add(model, deck, fields, tags=()):
        note = col.new_note(model)
        for name, value in fields.items():
            note[name] = value
        note.tags = list(tags)
        col.add_note(note, deck)
        return note

    n_hablar = add(basic, verbs, {"Front": "<b>hablar</b>", "Back": "to speak<br>Regular -ar verb"}, ["verbs", "ar"])
    n_comer = add(basic, verbs, {"Front": "comer", "Back": "to eat&nbsp;(regular -er)"}, ["verbs"])
    n_vivir = add(reversed_, verbs, {"Front": "vivir", "Back": "to live"})
    add(basic, verbs, {"Front": '¿Qué es esto? <img src="perro.png">', "Back": "el perro [sound:perro.mp3]"})
    add(typein, verbs, {"Front": "ser (yo)", "Back": "soy"})
    add(cloze, geo, {"Text": "The capital of {{c1::France::country}} is {{c2::Paris}}.", "Back Extra": "Paris has been the capital since 987."})
    add(cloze, geo, {"Text": "{{c1::Canberra}} is the capital of Australia, and {{c1::Canberra}} was planned.", "Back Extra": ""})

    # Real review history from Anki's scheduler.
    def answer(note, ease, ord_=0):
        card = [c for c in note.cards() if c.ord == ord_][0]
        card.start_timer()
        col.sched.answerCard(card, ease)

    answer(n_hablar, 4)                       # Easy: straight to review
    answer(n_comer, 3); answer(n_comer, 3)    # Good, Good: learning, then review
    answer(n_vivir, 4)                        # Easy, then a lapse:
    vivir = [c for c in n_vivir.cards() if c.ord == 0][0]
    col.sched.set_due_date([vivir.id], "0")
    answer(n_vivir, 1)                        # Again: relearning, one lapse
    return col


def schedule_of(col, card):
    """Anki's own view of a card's schedule, for expected.json."""
    out = {"type": card.type, "queue": card.queue, "reps": card.reps, "lapses": card.lapses, "ivl": card.ivl}
    if card.type == 2:  # review: due is a day number counted from the collection's creation day
        out["dueDayOffset"] = card.due - col.sched.today
    if card.memory_state:
        out["stability"] = round(card.memory_state.stability, 4)
        out["difficulty"] = round(card.memory_state.difficulty, 4)
    revlog = col.db.list("select ease from revlog where cid = ? order by id", card.id)
    out["revlogEases"] = revlog
    return out


def expected(col):
    """The AIQuiz quizzes an importer must produce (docs/anki-interchange.md §2)."""
    quizzes = {
        "Spanish › Verbs": [
            {"kind": "recall", "prompt": "hablar", "long_answer": "to speak\nRegular -ar verb", "short_answer": None, "hint": None},
            {"kind": "recall", "prompt": "comer", "long_answer": "to eat (regular -er)", "short_answer": None, "hint": None},
            {"kind": "recall", "prompt": "vivir", "long_answer": "to live", "short_answer": None, "hint": None},
            {"kind": "recall", "prompt": "to live", "long_answer": "vivir", "short_answer": None, "hint": None},
            {"kind": "recall", "prompt": "¿Qué es esto?", "long_answer": "el perro", "short_answer": None, "hint": None},
            {"kind": "recall", "prompt": "ser (yo)", "long_answer": "soy", "short_answer": None, "hint": None},
        ],
        "Geography": [
            {"kind": "cloze", "prompt": "The capital of {{blank}} is Paris.", "long_answer": "The capital of France is Paris.\nParis has been the capital since 987.", "short_answer": "France", "hint": "country"},
            {"kind": "cloze", "prompt": "The capital of France is {{blank}}.", "long_answer": "The capital of France is Paris.\nParis has been the capital since 987.", "short_answer": "Paris", "hint": None},
            {"kind": "cloze", "prompt": "{{blank}} is the capital of Australia, and {{blank}} was planned.", "long_answer": "Canberra is the capital of Australia, and Canberra was planned.", "short_answer": "Canberra|Canberra", "hint": None},
        ],
    }
    schedules = {}
    for cid in col.find_cards(""):
        card = col.get_card(cid)
        note = card.note()
        key = note.fields[0] if card.ord == 0 else f"{note.fields[0]} #{card.ord}"
        schedules[key] = schedule_of(col, card)
    return {"quizzes": quizzes, "media": {"images": 1, "sounds": 1}, "schedules": schedules}


def main():
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp()
    col = build(os.path.join(work, "plain.anki2"))
    whole = None  # the whole collection
    options = lambda legacy: ExportAnkiPackageOptions(with_scheduling=True, with_deck_configs=False, with_media=True, legacy=legacy)
    col.export_anki_package(out_path=os.path.join(OUT, "latest.apkg"), options=options(False), limit=whole)
    col.export_anki_package(out_path=os.path.join(OUT, "legacy2.apkg"), options=options(True), limit=whole)
    plain = expected(col)
    col.export_collection_package(os.path.join(OUT, "collection.colpkg"), include_media=True, legacy=False)
    col.close()

    # Anki 2.0's layout: the same schema 11 database under its old name, no meta file.
    with zipfile.ZipFile(os.path.join(OUT, "legacy2.apkg")) as src, zipfile.ZipFile(os.path.join(OUT, "legacy1.apkg"), "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            if item.filename in ("collection.anki2", "meta"):
                continue
            name = "collection.anki2" if item.filename == "collection.anki21" else item.filename
            dst.writestr(name, src.read(item.filename))

    fcol = build(os.path.join(work, "fsrs.anki2"), fsrs=True)
    fcol.export_anki_package(out_path=os.path.join(OUT, "fsrs.apkg"), options=options(False), limit=whole)
    fsrs = expected(fcol)
    fcol.close()

    with open(os.path.join(OUT, "expected.json"), "w") as f:
        json.dump({"anki": ANKI_VERSION, "plain": plain, "fsrs": fsrs}, f, indent=2, ensure_ascii=False)
    shutil.rmtree(work)
    for name in sorted(os.listdir(OUT)):
        with zipfile.ZipFile(os.path.join(OUT, name)) if name.endswith(("apkg", "colpkg")) else open(os.devnull) as z:
            entries = z.namelist() if hasattr(z, "namelist") else []
        print(name, os.path.getsize(os.path.join(OUT, name)), entries)


if __name__ == "__main__":
    sys.exit(main())
