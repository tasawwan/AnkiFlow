"""
A line-for-line mirror of Sources/AnkiFlow/Export/AnkiExporter.swift.

The Swift cannot be compiled in this environment, so the *logic and byte format*
are reproduced here and tested against the real Anki library. Any bug this
catches is a bug in the Swift too; anything that passes here leaves only syntax
risk in the port.
"""
import hashlib, json, sqlite3, struct, time, zlib, os, shutil

NOTETYPE_NAME = "AnkiFlow Note v1"
NOTETYPE_ID   = 2094605586
FIELDS        = ["Front", "FrontMedia", "Back", "BackMedia", "Extra", "Source", "QID"]
DECK_ROOT     = "AnkiFlow"

CARD_CSS = ".card { font-family: -apple-system, sans-serif; }"

FRONT_TMPL = '<div class="q">{{Front}}</div>\n{{FrontMedia}}'
BACK_TMPL  = ('{{FrontSide}}\n<hr id="answer">\n<div class="a">{{Back}}</div>\n'
              '{{BackMedia}}\n<div class="src">{{Source}}</div>')


# ---------------------------------------------------------------- ZipWriter
class ZipWriter:
    """Stored (uncompressed) entries only -- mirrors ZipWriter.swift."""
    def __init__(self):
        self.out = bytearray()
        self.entries = []

    def add(self, name, data):
        offset = len(self.out)
        crc = zlib.crc32(data) & 0xFFFFFFFF
        size = len(data)
        nb = name.encode()
        self.out += struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, 0, 0, 0x21,
                                crc, size, size, len(nb), 0)
        self.out += nb + data
        self.entries.append((name, crc, size, offset))

    def finish(self):
        cd_offset = len(self.out)
        for name, crc, size, offset in self.entries:
            nb = name.encode()
            self.out += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, 0, 0, 0,
                                    0x21, crc, size, size, len(nb), 0, 0, 0, 0, 0, offset)
            self.out += nb
        cd_size = len(self.out) - cd_offset
        n = len(self.entries)
        self.out += struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, n, n, cd_size, cd_offset, 0)
        return bytes(self.out)


# ---------------------------------------------------------------- identifiers
def deck_id(name):
    d = hashlib.sha256(name.encode()).digest()[:8]
    v = int.from_bytes(d, "big")
    return v % 2_000_000_000 + 100_000


def checksum(sort_field):
    return int(hashlib.sha1(sort_field.encode()).hexdigest()[:8], 16)


def crop_fingerprint(crop):
    """Mirrors CropRect.fingerprint."""
    def mil(v):
        return int(round(v * 1000))
    return "%03d%03d%03d%03d" % (mil(crop["x"]), mil(crop["y"]),
                                 mil(crop["width"]), mil(crop["height"]))


def is_full_page(crop):
    return (crop["x"] <= 0.001 and crop["y"] <= 0.001
            and crop["width"] >= 0.999 and crop["height"] >= 0.999)


def crops_fingerprint(crops):
    """Mirrors Question.cropsFingerprint. Page keys are strings in JSON but
    Swift sorts them as Ints, so 2 comes before 10."""
    return ";".join(f"{p}:{crop_fingerprint(crops[p])}"
                    for p in sorted(crops, key=int))


def media_name(sha, page, crop=None):
    """Mirrors PageRenderer.mediaFileName. The crop MUST be in the name or a
    cropped and an uncropped render of one slide collide."""
    part = ""
    if crop is not None and not is_full_page(crop):
        part = "_c" + crop_fingerprint(crop)
    return f"af_{sha[:8]}_p{page:04d}{part}_w1600.jpg"


def masks_fingerprint(masks):
    return ";".join(f'{m["id"]}:{crop_fingerprint(m["rect"])}' for m in masks)


def note_variants(q):
    """Mirrors Question.noteVariants. One note, unless a separate-mode occlusion
    question, which makes one per mask."""
    masks = q.get("masks", [])
    if q["kind"] != "occlusion" or q.get("occlusionMode", "separate") != "separate" or not masks:
        return [("", None)]
    return [(m["id"], m) for m in masks]


def guid_for(q, variant):
    return q["qid"] if not variant else f'{q["qid"]}#{variant}'


def mask_paint_fingerprint(hidden, target, outlined):
    """Mirrors PageRenderer.MaskPaint.fingerprint."""
    parts = [crop_fingerprint(c) for c in hidden]
    parts.append("t" + (crop_fingerprint(target) if target else "-"))
    parts.append("o" + (crop_fingerprint(outlined) if outlined else "-"))
    return hashlib.sha256(",".join(parts).encode()).hexdigest()[:10]


def occlusion_media_name(sha, page, crop, hidden, target, outlined):
    part = ""
    if crop is not None and not is_full_page(crop):
        part = "_c" + crop_fingerprint(crop)
    part += "_m" + mask_paint_fingerprint(hidden, target, outlined)
    return f"af_{sha[:8]}_p{page:04d}{part}_w1600.jpg"


def content_hash(q, render_version=1, template_fingerprint=None, pdf_fingerprint="",
                 variant=""):
    parts = [
        f"v{render_version}", pdf_fingerprint, q["kind"], q.get("templateId") or "",
        q.get("front", ""), q.get("back", ""),
        ",".join(str(p) for p in q.get("questionPages", [])),
        ",".join(str(p) for p in q.get("answerPages", [])),
        crops_fingerprint(q.get("questionCrops", {})),
        crops_fingerprint(q.get("answerCrops", {})),
        masks_fingerprint(q.get("masks", [])),
        q.get("occlusionMode", "separate"),
        variant,
        ",".join(sorted(q.get("tags", []))),
    ]
    for k in sorted(q.get("blanks", {})):
        parts.append(f"{k}={q['blanks'][k]}")
    if template_fingerprint:
        parts.append(template_fingerprint)
    return hashlib.sha256("\x1f".join(parts).encode()).hexdigest()


def pages_label(q):
    def describe(pages):
        pages = sorted(set(pages))
        if not pages:
            return ""
        out, start, prev = [], pages[0], pages[0]
        for p in pages[1:]:
            if p == prev + 1:
                prev = p
                continue
            out.append(str(start) if start == prev else f"{start}\u2013{prev}")
            start = prev = p
        out.append(str(start) if start == prev else f"{start}\u2013{prev}")
        return ", ".join(out)
    f, b = describe(q.get("questionPages", [])), describe(q.get("answerPages", []))
    if not f:
        return f"pp. {b}"
    if not b:
        return f"pp. {f}"
    return f"pp. {f} \u2192 {b}"


def escape(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def paragraphs(t):
    t = t.strip()
    return escape(t).replace("\n", "<br>") if t else ""


def strip_html(t):
    import re
    return re.sub(r"<[^>]+>", "", t).replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")


# ---------------------------------------------------------------- schema
SCHEMA = """
CREATE TABLE col (
    id integer primary key, crt integer not null, mod integer not null,
    scm integer not null, ver integer not null, dty integer not null,
    usn integer not null, ls integer not null, conf text not null,
    models text not null, decks text not null, dconf text not null, tags text not null
);
CREATE TABLE notes (
    id integer primary key, guid text not null, mid integer not null,
    mod integer not null, usn integer not null, tags text not null,
    flds text not null, sfld integer not null, csum integer not null,
    flags integer not null, data text not null
);
CREATE TABLE cards (
    id integer primary key, nid integer not null, did integer not null,
    ord integer not null, mod integer not null, usn integer not null,
    type integer not null, queue integer not null, due integer not null,
    ivl integer not null, factor integer not null, reps integer not null,
    lapses integer not null, left integer not null, odue integer not null,
    odid integer not null, flags integer not null, data text not null
);
CREATE TABLE revlog (
    id integer primary key, cid integer not null, usn integer not null,
    ease integer not null, ivl integer not null, lastIvl integer not null,
    factor integer not null, time integer not null, type integer not null
);
CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
CREATE INDEX ix_notes_usn on notes (usn);
CREATE INDEX ix_cards_usn on cards (usn);
CREATE INDEX ix_revlog_usn on revlog (usn);
CREATE INDEX ix_cards_nid on cards (nid);
CREATE INDEX ix_cards_sched on cards (did, queue, due);
CREATE INDEX ix_revlog_cid on revlog (cid);
CREATE INDEX ix_notes_csum on notes (csum);
"""


def note_type_json():
    flds = [{"name": n, "ord": i, "sticky": False, "rtl": False,
             "font": "Helvetica", "size": 20, "media": []} for i, n in enumerate(FIELDS)]
    return {
        "id": str(NOTETYPE_ID), "name": NOTETYPE_NAME, "type": 0,
        "mod": int(time.time()), "usn": -1, "sortf": 0, "did": 1,
        "tmpls": [{"name": "Card 1", "ord": 0, "qfmt": FRONT_TMPL, "afmt": BACK_TMPL,
                   "bqfmt": "", "bafmt": "", "did": None, "bfont": "", "bsize": 0}],
        "flds": flds, "css": CARD_CSS,
        "latexPre": "\\documentclass[12pt]{article}\n\\begin{document}\n",
        "latexPost": "\\end{document}", "latexsvg": False,
        "req": [[0, "any", [0, 1]]], "tags": [], "vers": [],
    }


def deck_json(did, name):
    return {"id": did, "name": name, "mod": int(time.time()), "usn": -1,
            "collapsed": False, "desc": "", "dyn": 0, "conf": 1,
            "extendNew": 10, "extendRev": 50, "lrnToday": [0, 0],
            "newToday": [0, 0], "revToday": [0, 0], "timeToday": [0, 0]}


def deck_config():
    return {"1": {"id": 1, "name": "Default", "mod": 0, "usn": 0, "maxTaken": 60,
                  "timer": 0, "autoplay": True, "replayq": True,
                  "new": {"bury": True, "delays": [1, 10], "initialFactor": 2500,
                          "ints": [1, 4, 7], "order": 1, "perDay": 20, "separate": True},
                  "rev": {"bury": True, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1,
                          "maxIvl": 36500, "minSpace": 1, "perDay": 200},
                  "lapse": {"delays": [10], "leechAction": 0, "leechFails": 8,
                            "minInt": 1, "mult": 0}}}


# ---------------------------------------------------------------- exporter
def export(plans, destination, export_state, media_source, now=None):
    """plans: [{deckName, pathTag, sourceLabel, questions:[...]}] -- questions are
    mutated in place with their new export records, exactly as the Swift does."""
    now = now or int(time.time())
    workdir = destination + ".work"
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)
    dbpath = os.path.join(workdir, "collection.anki2")
    db = sqlite3.connect(dbpath)
    db.executescript(SCHEMA)

    decks = {"1": deck_json(1, "Default")}
    media_files = {}
    note_counter = int(time.time() * 1000)
    card_position = 0
    summary = dict(new=0, changed=0, unchanged=0, moved=[], retired=[])
    seen = set()

    for plan in plans:
        did = deck_id(plan["deckName"])
        decks[str(did)] = deck_json(did, plan["deckName"])

        for q in plan["questions"]:
          for variant, mask in note_variants(q):
            guid = guid_for(q, variant)
            seen.add(guid)
            h = content_hash(q, variant=variant)
            prev = q.get("export") if not variant else q.get("childExports", {}).get(variant)

            # ---- the merge discipline ----
            if prev and prev["contentHash"] == h:
                mod = prev["mod"]
                summary["unchanged"] += 1
            else:
                mod = max(now, (prev["mod"] if prev else 0) + 1)
                if prev is None:
                    summary["new"] += 1
                else:
                    summary["changed"] += 1
            if variant:
                q.setdefault("childExports", {})[variant] = {"contentHash": h, "mod": mod}
            else:
                q["export"] = {"contentHash": h, "mod": mod}
            # ------------------------------

            front_imgs, back_imgs = [], []
            if q["kind"] == "occlusion":
                page = (q.get("answerPages") or q.get("questionPages") or [None])[0]
                crop = q.get("answerCrops", {}).get(str(page))
                others = [m["rect"] for m in q.get("masks", [])
                          if mask is None or m["id"] != mask["id"]]
                target = mask["rect"] if mask else None
                n = occlusion_media_name(plan["sha"], page, crop, others, target, None)
                media_files[n] = media_source
                front_imgs.append(n)
                n = occlusion_media_name(plan["sha"], page, crop, [], None, target)
                media_files[n] = media_source
                back_imgs.append(n)
            else:
                for p in q.get("questionPages", []):
                    n = media_name(plan["sha"], p, q.get("questionCrops", {}).get(str(p)))
                    media_files[n] = media_source
                    front_imgs.append(n)
                for p in q.get("answerPages", []):
                    n = media_name(plan["sha"], p, q.get("answerCrops", {}).get(str(p)))
                    media_files[n] = media_source
                    back_imgs.append(n)

            def stack(names):
                return "\n".join(f'<img src="{n}">' for n in names)

            source_text = f"{plan['sourceLabel']} \u00b7 {pages_label(q)}"
            flds = [paragraphs(q.get("front", "")), stack(front_imgs),
                    paragraphs(q.get("back", "")), stack(back_imgs),
                    "", escape(source_text), guid]

            tags = list(q.get("tags", [])) + [plan["pathTag"]]
            tag_str = " " + " ".join(t.replace(" ", "-") for t in tags) + " " if tags else ""
            sort_field = strip_html(flds[0])

            note_counter += 1
            nid = note_counter
            db.execute(
                "INSERT INTO notes (id,guid,mid,mod,usn,tags,flds,sfld,csum,flags,data) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (nid, guid, NOTETYPE_ID, mod, -1, tag_str,
                 "\x1f".join(flds), sort_field, checksum(sort_field), 0, ""))
            card_position += 1
            db.execute(
                "INSERT INTO cards (id,nid,did,ord,mod,usn,type,queue,due,ivl,factor,"
                "reps,lapses,left,odue,odid,flags,data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (nid + 1, nid, did, 0, mod, -1, 0, 0, card_position,
                 0, 0, 0, 0, 0, 0, 0, 0, ""))

            if guid in export_state and export_state[guid] != plan["deckName"]:
                summary["moved"].append((guid, export_state[guid], plan["deckName"]))
            export_state[guid] = plan["deckName"]

    summary["retired"] = sorted(k for k in export_state if k not in seen)

    conf = {"activeDecks": [1], "addToCur": True, "collapseTime": 1200, "curDeck": 1,
            "curModel": str(NOTETYPE_ID), "dueCounts": True, "estTimes": True,
            "newBury": True, "newSpread": 0, "nextPos": 1, "sortBackwards": False,
            "sortType": "noteFld", "timeLim": 0}
    t = int(time.time())
    db.execute("INSERT INTO col (id,crt,mod,scm,ver,dty,usn,ls,conf,models,decks,dconf,tags) "
               "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
               (1, t, t * 1000, t * 1000 - 100, 11, 0, 0, 0,
                json.dumps(conf, sort_keys=True),
                json.dumps({str(NOTETYPE_ID): note_type_json()}, sort_keys=True),
                json.dumps(decks, sort_keys=True),
                json.dumps(deck_config(), sort_keys=True), "{}"))
    db.commit()
    db.close()

    z = ZipWriter()
    z.add("collection.anki2", open(dbpath, "rb").read())
    media_map = {}
    for i, name in enumerate(sorted(media_files)):
        media_map[str(i)] = name
        z.add(str(i), open(media_files[name], "rb").read())
    z.add("media", json.dumps(media_map, sort_keys=True).encode())
    open(destination, "wb").write(z.finish())
    shutil.rmtree(workdir, ignore_errors=True)
    summary["media"] = len(media_map)
    return summary
