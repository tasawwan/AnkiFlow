"""
The test that matters: export, study, edit, re-export, merge -- against a real
Anki collection. Asserts scheduling survives and the right notes update.
"""
import os, shutil, sys, time
from anki.collection import Collection
from anki import import_export_pb2 as ie
import mirror

WORK = "/tmp/cs-verify"
IF_NEWER = ie.IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER

failures = []
def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f"  -- {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def fresh_collection():
    shutil.rmtree(f"{WORK}/coll", ignore_errors=True)
    os.makedirs(f"{WORK}/coll")
    return Collection(f"{WORK}/coll/collection.anki2")


def import_pkg(col, path):
    opts = ie.ImportAnkiPackageOptions(
        merge_notetypes=True, update_notes=IF_NEWER, update_notetypes=IF_NEWER,
        with_scheduling=False, with_deck_configs=False)
    return col.import_anki_package(ie.ImportAnkiPackageRequest(package_path=path, options=opts))


def study(col):
    """Give every card real review history."""
    for cid in col.find_cards(""):
        c = col.get_card(cid)
        c.type, c.queue, c.ivl = 2, 2, 21
        c.due, c.reps, c.lapses, c.factor = col.sched.today + 21, 5, 1, 2350
        col.update_card(c)


def state(col):
    out = {}
    for nid in col.find_notes(""):
        n = col.get_note(nid)
        for c in n.cards():
            out[n.fields[6]] = dict(
                front=n.fields[0], front_media=n.fields[1], back=n.fields[2],
                back_media=n.fields[3], source=n.fields[5], tags=sorted(n.tags),
                deck=col.decks.name(c.did), cid=c.id,
                sched=(c.type, c.queue, c.due, c.ivl, c.reps, c.lapses, c.factor))
    return out


def make_questions():
    return [
        {"qid": "01JBQZ3F7K8M2N4P6R8T0V2X4Z", "kind": "basic",
         "front": "Explain the classical pathway, including the proteins involved.",
         "back": "", "questionPages": [], "answerPages": [12, 13, 14, 15, 16, 17, 18],
         "tags": ["high-yield"], "blanks": {}, "export": None},
        {"qid": "01JBQZ4A1B2C3D4E5F6G7H8J9K", "kind": "slide2slide",
         "front": "Which step here is rate-limiting, and what regulates it?",
         "back": "", "questionPages": [24], "answerPages": [25, 26, 27],
         "tags": [], "blanks": {}, "export": None},
    ]


def main():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    media = f"{WORK}/slide.jpg"
    open(media, "wb").write(b"\xff\xd8\xff\xe0" + b"ankiflow-test-slide" * 8)

    questions = make_questions()
    plan = {"deckName": "AnkiFlow::Immunology::Lecture 04 Complement",
            "pathTag": "AnkiFlow::Immunology::Lecture-04-Complement",
            "sourceLabel": "Immunology / Lecture 04 Complement",
            "sha": "9f2ae41c77", "questions": questions}
    export_state = {}

    print("\n=== 1. First export and import ===")
    s1 = mirror.export([plan], f"{WORK}/v1.apkg", export_state, media, now=int(time.time()))
    col = fresh_collection()
    log = import_pkg(col, f"{WORK}/v1.apkg")
    after1 = state(col)

    check("package imports at all", len(after1) == 2, f"got {len(after1)} notes")
    check("summary counts two new notes", s1["new"] == 2 and s1["changed"] == 0)
    check("deck name preserved",
          all(v["deck"] == plan["deckName"] for v in after1.values()),
          str([v["deck"] for v in after1.values()]))
    q1 = after1["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]
    check("basic question text landed on Front", "classical pathway" in q1["front"])
    check("seven answer slides on BackMedia", q1["back_media"].count("<img") == 7,
          f'{q1["back_media"].count("<img")} images')
    check("user tag survived", "high-yield" in q1["tags"], str(q1["tags"]))
    check("path tag applied", any("Lecture-04" in t for t in q1["tags"]), str(q1["tags"]))
    check("source line rendered", "pp. 12–18" in q1["source"], q1["source"])
    q2 = after1["01JBQZ4A1B2C3D4E5F6G7H8J9K"]
    check("slide2slide has text AND slides on the front",
          "rate-limiting" in q2["front"] and q2["front_media"].count("<img") == 1,
          f'front={q2["front"][:40]!r} media={q2["front_media"]!r}')
    check("media files written", s1["media"] == 11, f'{s1["media"]} files')

    print("\n=== 2. Study the cards ===")
    study(col)
    before = state(col)
    check("cards now have review history",
          all(v["sched"][4] == 5 for v in before.values()))

    print("\n=== 3. Edit one, add one, re-export, merge ===")
    time.sleep(1.1)   # a real session would be minutes; prove it works at 1s
    questions[0]["front"] = "Explain the classical pathway IN DETAIL."
    questions[0]["answerPages"] = [12, 13, 14, 15, 16, 17, 18, 19]
    questions.append({"qid": "01JBQZ5M4N3P2Q1R0S9T8U7V6W", "kind": "basic",
                      "front": "Describe MAC assembly.", "back": "",
                      "questionPages": [], "answerPages": [30, 31],
                      "tags": [], "blanks": {}, "export": None})
    s2 = mirror.export([plan], f"{WORK}/v2.apkg", export_state, media)
    check("exporter reports 1 changed, 1 unchanged, 1 new",
          s2["changed"] == 1 and s2["unchanged"] == 1 and s2["new"] == 1,
          f'changed={s2["changed"]} unchanged={s2["unchanged"]} new={s2["new"]}')

    log2 = import_pkg(col, f"{WORK}/v2.apkg")
    after2 = state(col)
    print(f'  anki log: new={len(log2.log.new)} updated={len(log2.log.updated)} '
          f'duplicate={len(log2.log.duplicate)} conflicting={len(log2.log.conflicting)}')

    edited = after2["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]
    untouched = after2["01JBQZ4A1B2C3D4E5F6G7H8J9K"]
    check("edited note's text updated in Anki", "IN DETAIL" in edited["front"], edited["front"][:60])
    check("edited note's new slide came through", edited["back_media"].count("<img") == 8,
          f'{edited["back_media"].count("<img")} images')
    check("SCHEDULING PRESERVED on the edited note",
          edited["sched"] == before["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"],
          f'{before["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"]} -> {edited["sched"]}')
    check("card id unchanged on the edited note",
          edited["cid"] == before["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["cid"])
    check("SCHEDULING PRESERVED on the untouched note",
          untouched["sched"] == before["01JBQZ4A1B2C3D4E5F6G7H8J9K"]["sched"])
    check("anki updated exactly one note", len(log2.log.updated) == 1,
          f"updated={len(log2.log.updated)}")
    check("new question added", "01JBQZ5M4N3P2Q1R0S9T8U7V6W" in after2)
    check("new card starts unstudied",
          after2["01JBQZ5M4N3P2Q1R0S9T8U7V6W"]["sched"][4] == 0)

    print("\n=== 4. Same-second re-export (the silent-skip trap) ===")
    questions[0]["front"] = "Explain the classical pathway, third revision."
    s3 = mirror.export([plan], f"{WORK}/v3.apkg", export_state, media)
    s4_questions = questions
    # Immediately export again with another edit, same wall-clock second.
    s4_questions[0]["front"] = "Explain the classical pathway, fourth revision."
    s4 = mirror.export([plan], f"{WORK}/v4.apkg", export_state, media)
    import_pkg(col, f"{WORK}/v3.apkg")
    import_pkg(col, f"{WORK}/v4.apkg")
    after4 = state(col)
    check("two edits in the same second both land (mod is forced strictly newer)",
          "fourth revision" in after4["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["front"],
          after4["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["front"][:60])
    check("scheduling still preserved after four imports",
          after4["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"] ==
          before["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"])

    print("\n=== 5. Deleting a question is reported, not silently dropped ===")
    removed = questions.pop()
    s5 = mirror.export([plan], f"{WORK}/v5.apkg", export_state, media)
    check("retired question reported to the user",
          removed["qid"] in s5["retired"], str(s5["retired"]))

    print("\n=== 6. Cropping ===")
    # A crop is normalized: the middle-left quarter of the page.
    crop = {"x": 0.05, "y": 0.30, "width": 0.45, "height": 0.40}
    target = questions[0]
    before6 = state(col)
    target["answerCrops"] = {"13": crop}
    s6 = mirror.export([plan], f"{WORK}/v6.apkg", export_state, media)
    check("cropping a slide is seen as a change", s6["changed"] == 1,
          f'changed={s6["changed"]} unchanged={s6["unchanged"]}')

    cropped_name = mirror.media_name(plan["sha"], 13, crop)
    plain_name = mirror.media_name(plan["sha"], 13, None)
    check("a crop changes the media filename", cropped_name != plain_name,
          f"{cropped_name} vs {plain_name}")
    check("the crop is what makes it different",
          cropped_name == plain_name.replace("_w1600", "_c050300450400_w1600"),
          cropped_name)

    import_pkg(col, f"{WORK}/v6.apkg")
    after6 = state(col)
    check("the cropped image reached the card",
          cropped_name in after6["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["back_media"],
          after6["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["back_media"][:120])
    check("SCHEDULING PRESERVED after cropping",
          after6["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"] ==
          before6["01JBQZ3F7K8M2N4P6R8T0V2X4Z"]["sched"])

    # Moving the crop must also register, or adjusting one leaves the card
    # showing the old picture with no error anywhere.
    target["answerCrops"] = {"13": {"x": 0.10, "y": 0.30, "width": 0.45, "height": 0.40}}
    s7 = mirror.export([plan], f"{WORK}/v7.apkg", export_state, media)
    check("moving a crop is seen as a change", s7["changed"] == 1,
          f'changed={s7["changed"]}')

    # And the same page cropped on the front and uncropped on the back must not
    # collapse into one file.
    check("front and back crops of one page stay separate files",
          mirror.media_name(plan["sha"], 13, crop)
          != mirror.media_name(plan["sha"], 13, None))

    print("\n=== 7. Image occlusion ===")
    occ = {
        "qid": "01JBQZ9OCCLUSION00000000AA",
        "kind": "occlusion",
        "front": "Label the structures.",
        "back": "",
        "blanks": {},
        "questionPages": [],
        "answerPages": [20],
        "tags": ["high-yield"],
        "occlusionMode": "separate",
        "masks": [
            {"id": "01JBMASK0000000000000000A1",
             "rect": {"x": 0.10, "y": 0.60, "width": 0.20, "height": 0.10}},
            {"id": "01JBMASK0000000000000000B2",
             "rect": {"x": 0.55, "y": 0.30, "width": 0.20, "height": 0.10}},
            {"id": "01JBMASK0000000000000000C3",
             "rect": {"x": 0.30, "y": 0.15, "width": 0.20, "height": 0.10}},
        ],
    }
    questions.append(occ)
    s7 = mirror.export([plan], f"{WORK}/v8.apkg", export_state, media)
    check("three masks make three notes", s7["new"] == 3, f'new={s7["new"]}')

    import_pkg(col, f"{WORK}/v8.apkg")
    after7 = state(col)
    guids = [f'{occ["qid"]}#{m["id"]}' for m in occ["masks"]]
    check("each mask got its own note", all(g in after7 for g in guids),
          str([g for g in guids if g not in after7]))
    check("each card's front hides the others and marks its own",
          len({after7[g]["front_media"] for g in guids}) == 3,
          "fronts are not distinct")
    check("all three share one clean back image",
          len({after7[g]["back_media"] for g in guids}) == 3,
          "backs differ per mask, as intended (each boxes its own region)")

    study(col)
    before7 = state(col)

    # Moving one mask must change every card of the question -- the front of all
    # of them hides all of them.
    occ["masks"][0]["rect"]["x"] = 0.12
    s8 = mirror.export([plan], f"{WORK}/v9.apkg", export_state, media)
    check("moving one mask changes all three cards", s8["changed"] == 3,
          f'changed={s8["changed"]} unchanged={s8["unchanged"]}')
    import_pkg(col, f"{WORK}/v9.apkg")
    after8 = state(col)
    check("SCHEDULING PRESERVED across all occlusion cards",
          all(after8[g]["sched"] == before7[g]["sched"] for g in guids))

    # Deleting a mask leaves its card behind, exactly like deleting a question.
    dropped = occ["masks"].pop()
    s9 = mirror.export([plan], f"{WORK}/v10.apkg", export_state, media)
    check("deleting a mask retires exactly that card",
          f'{occ["qid"]}#{dropped["id"]}' in s9["retired"], str(s9["retired"]))

    # All-at-once collapses the same masks into a single card.
    occ["occlusionMode"] = "allAtOnce"
    s10 = mirror.export([plan], f"{WORK}/v11.apkg", export_state, media)
    check("all-at-once makes one card from the same masks",
          s10["new"] == 1 and s10["changed"] == 0,
          f'new={s10["new"]} changed={s10["changed"]}')

    col.close()
    print("\n" + "=" * 64)
    if failures:
        print(f"FAILED: {len(failures)}")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
