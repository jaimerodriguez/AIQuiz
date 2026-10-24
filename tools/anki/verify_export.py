"""Check that Anki accepts an AIQuiz export (docs/anki-interchange.md §3).

    AIQUIZ_ANKI_EXPORT=/tmp/aiquiz.apkg swift test --package-path Packages/AIQuizCore --filter writeForAnki
    /tmp/anki-venv/bin/python -I tools/anki/verify_export.py /tmp/aiquiz.apkg [reexport.apkg]

Imports the package into a new collection with Anki's own engine, then checks the decks,
note types, fields, rendered cards and the carried-over schedule. Exits non-zero on failure.
With a second path, Anki exports the deck again in its current format there: the fixture
`aiquiz-via-anki.apkg`, which an importer must read back as the cards it started from.
"""

import os
import sys
import tempfile

from anki.collection import Collection, DeckIdLimit, ExportAnkiPackageOptions, ImportAnkiPackageRequest, ImportAnkiPackageOptions

failures = []


def check(condition, message):
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        failures.append(message)


def main(path, reexport=None):
    col = Collection(os.path.join(tempfile.mkdtemp(), "verify.anki2"))
    log = col.import_anki_package(ImportAnkiPackageRequest(
        package_path=path,
        options=ImportAnkiPackageOptions(with_scheduling=True, with_deck_configs=False, merge_notetypes=False)))
    check(len(log.log.new) == 4, f"4 notes imported (got {len(log.log.new)}, {len(log.log.conflicting)} conflicting, {len(log.log.first_field_match)} duplicates)")

    deck = col.decks.by_name("Biology::Cells")
    check(deck is not None, "deck Biology::Cells exists (and its parent Biology)")
    check(col.decks.by_name("Biology") is not None, "parent deck Biology exists")

    basic = col.models.by_name("AIQuiz")
    cloze = col.models.by_name("AIQuiz Cloze")
    check(basic is not None and [f["name"] for f in basic["flds"]] == ["Front", "Back", "Short Answer", "Hint", "Options", "Explanation", "Mnemonic", "Kind"], "AIQuiz note type and its fields")
    check(cloze is not None and cloze["type"] == 1, "AIQuiz Cloze is a cloze note type")

    cards = [col.get_card(cid) for cid in col.find_cards("deck:Biology::Cells")]
    check(len(cards) == 4, f"4 cards in the deck (got {len(cards)})")
    by_front = {c.note().fields[0]: c for c in cards}

    atp = by_front.get("What is ATP?")
    check(atp is not None and atp.type == 0, "the recall card is new")
    if atp:
        question, answer = atp.question(), atp.answer()
        check("What is ATP?" in question and "Think power" not in question.split("hint")[0], "question shows the prompt; the hint sits behind Anki's hint link")
        check("Energy &lt;currency&gt; &amp; more" in answer and "mitochondria" in answer and "phosphate" in answer, "answer shows short answer, long answer and explanation")

    mc = by_front.get("Which is a mammal?")
    check(mc is not None and "Shark<br>Whale<br>Trout" in mc.question(), "multiple choice shows its options")

    cl = next((c for c in cards if c.note().note_type()["name"] == "AIQuiz Cloze"), None)
    check(cl is not None, "the cloze card exists")
    if cl:
        check(cl.question().count("[...]") == 2 or cl.question().count("cloze") >= 2, "both blanks hidden on one card")
        check("Canberra" in cl.answer() and "Australia" in cl.answer(), "the answer fills both blanks")
        check(cl.type == 2 and cl.queue == 2, f"the reviewed card is a review card (type {cl.type}, queue {cl.queue})")
        check(cl.reps == 3 and cl.lapses == 1, f"reps 3, lapses 1 (got {cl.reps}, {cl.lapses})")
        check(cl.ivl == 12, f"interval 12 days (got {cl.ivl})")
        state = cl.memory_state
        check(state is not None and abs(state.stability - 12.5) < 0.01 and abs(state.difficulty - 4.2) < 0.01,
              f"FSRS memory kept (got {state.stability if state else None}, {state.difficulty if state else None})")
        due_day = col.crt + cl.due * 86400
        check(abs(due_day - 1_800_000_000) < 2 * 86400, f"due near 2027-01-15 (got {due_day})")

    check(not col.db.scalar("select count() from cards where nid not in (select id from notes)"), "no orphan cards")
    problems = col.fix_integrity()
    print("check database:", problems[0].replace("\n", " | ")[:300])
    if reexport and deck is not None:
        col.export_anki_package(out_path=reexport, limit=DeckIdLimit(deck["id"]), options=ExportAnkiPackageOptions(
            with_scheduling=True, with_deck_configs=False, with_media=True, legacy=False))
        print("re-exported by Anki to", reexport)
    col.close()
    print("PASS" if not failures else f"{len(failures)} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
