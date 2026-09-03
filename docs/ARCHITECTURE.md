<img src="images/logo.png" width="96" align="left" alt="" hspace="14">

# AnkiFlow internals

For anyone reading, forking or extending the code. The README covers using the app; this covers how it works and what you can safely change.

---

## Contents

- [Building and running](#building-and-running)
- [Layout](#layout)
- [Invariants you must not break](#invariants-you-must-not-break)
- [If you fork this](#if-you-fork-this)
- [File formats](#file-formats)
- [Model](#model)
- [Export](#export)
- [PDF](#pdf)
- [UI conventions](#ui-conventions)
- [Adding a card type](#adding-a-card-type)
- [Testing](#testing)

---

## Building and running

Swift 5.9, macOS 14 target, SwiftPM, **no third-party dependencies**. Xcode or the Command Line Tools is all you need.

```bash
cd App
swift build                 # compile
swift run AnkiFlow          # debug build, fastest edit-and-run loop
./make-app.sh               # release .app bundle, left in App/
./make-app.sh --install     # …and moved to /Applications
```

`swift run` produces a bare executable — no bundle, so no icon, no `Info.plist`, and `Bundle.main` reads come back empty. Anything that depends on bundle identity (the version in About, the update check, the source path used by Update from Source) is inert there by design.

`make-app.sh` derives the version from `git describe`, writes it into `Info.plist`, and records the checkout path as `AFSourcePath`. Tag a release and the version follows; there is no version constant to bump.

CI (`.github/workflows/ci.yml`) compiles on macOS and runs the round-trip test on every push.

---

## Layout

```
App/
├── Package.swift
├── make-app.sh                Bundle, icon, plist, ad-hoc signature, version from git
└── Sources/AnkiFlow/
    ├── AnkiFlowApp.swift      Entry point, menu bar, keyboard shortcuts, window scenes
    ├── Model/                 Data and rules. No SwiftUI.
    ├── PDF/                   PDFKit viewing and slide rendering
    ├── Export/                Everything that writes a deck
    └── UI/                    Views
```

`Model/` and `Export/` import no SwiftUI and know nothing about views. That separation is what makes the round-trip test possible, and what would make a port to another UI framework tractable.

---

## Invariants you must not break

Three things are load-bearing. Everything else in the app is a convenience; these are why re-exporting updates your cards instead of duplicating them, and all three are covered by the test suite.

**Frozen identifiers** (`Model/Identifiers.swift`). The note type name and id, the seven field names and their order, and the sidecar extension are permanent. Each question's ULID becomes its Anki note GUID verbatim, and Anki matches notes by GUID *within a note type*. Change either after a user's first export and every studied card orphans — new cards appear, the old ones stay behind with their review history and no way to reconcile them.

**The `mod` discipline** (`Export/AnkiExporter.swift`). Anki only updates a note whose `mod` timestamp is *strictly* newer than the copy in the collection. Equal timestamps are silently treated as duplicates and skipped — **along with the note's media**, which surfaces as a card with a missing image and no error anywhere. The exporter therefore stamps `max(now, previousMod + 1)` for changed notes, and re-stamps the *unchanged* previous value for notes whose content hash matches, so Anki correctly skips them.

**`Question.contentHash`** decides what counts as changed. It hashes text, blanks, page lists, crops, masks, occlusion mode, tags, the template's fingerprint, the library's render version, and the PDF's own hash. That last one is easy to overlook and important: media filenames derive from the PDF hash, so an annotated PDF produces new image files — without the hash in the content hash, the exporter would call the note unchanged and Anki would keep showing images that no longer exist.

If you add anything that changes how a card renders, it must go into `contentHash` **and** into the media filename if it changes the image. Missing either produces a silent wrong-picture bug rather than a visible failure.

---

## If you fork this

**Decide immediately whether your fork shares a card lineage with AnkiFlow.**

- **Sharing** (a patch you intend to upstream, or a build for your own existing decks): leave `AnkiIdentity` alone. Your exports will merge with cards AnkiFlow already made.
- **Diverging** (a differently-named app, a different card design): change `appName`, `noteTypeName`, `noteTypeID`, `deckRoot`, `sidecarExtension` and `repository` in `Identifiers.swift` **before anyone exports anything**. Pick a fresh random 64-bit `noteTypeID`. Two apps sharing a note type id but disagreeing about its fields will corrupt each other's notes.

There is no migration path between the two once cards exist. Choose before you ship.

`repository` is the `owner/repo` the update checker queries; point it at your fork or the check will offer your users someone else's releases.

---

## File formats

### The question file

One per lecture, named after the PDF, sitting beside it: `Lecture 04.ankiflow.json`. Carries Finder's hidden flag. Plain sorted JSON, so it diffs cleanly under git.

```jsonc
{
  "schemaVersion": 1,
  "pdf": {
    "fileName": "Lecture 04.pdf",
    "pageCount": 51,
    "sha256": "…",            // detects an edited or replaced PDF
    "pageSketches": ["…"]     // per-page word sketch; see PageSketch
  },
  "deckNameOverride": null,   // usually null; folder path decides the deck
  "questions": [ … ],
  "lastExportedDeckName": "AnkiFlow::Immunology::Lecture 04",
  "retiredQIDs": ["…"]        // exported questions since deleted
}
```

A question carries `qid` (ULID), `type`, `front`, `back`, `blanks`, `questionPages`, `answerPages`, optional `questionCrops`/`answerCrops` keyed by page number, optional `masks` and `occlusionMode`, `tags`, timestamps, and `export`/`childExports` records. Optional fields are omitted when empty, so a lecture with no crops writes exactly what earlier versions wrote.

**A lecture with no questions gets no file**, and empty files are swept away on every library scan. An empty question file next to a PDF looks exactly like questions someone has lost.

### Per-library state — `.ankiflow/` at the library root

| | |
|---|---|
| `library.json` | Deck root, tag definitions, render settings, `renderVersion` |
| `cache/` | Rendered slide images. Safe to delete; regenerated on demand. |
| `history/` | Save snapshots, last 20 per lecture |
| `undo.json` | Library-wide undo and redo stacks |

Templates are **not** per library — they live in Application Support, so they follow you between courses.

### The Anki note type

Seven fields, in this order, one card template:

| Field | Holds |
|---|---|
| `Front` | Question text, HTML-escaped |
| `FrontMedia` | `<img>` stack for front slides |
| `Back` | Written answer |
| `BackMedia` | `<img>` stack for answer slides |
| `Extra` | The cited slides' text layer — not rendered, but Anki searches it |
| `Source` | Lecture name and page range |
| `QID` | The GUID, so cards can be found by id from outside |

```
Front:  <div class="q">{{Front}}</div>
        {{FrontMedia}}

Back:   {{FrontSide}}
        <hr id="answer">
        <div class="a">{{Back}}</div>
        {{BackMedia}}
```

`Extra` being searchable-but-invisible is deliberate: Anki's browser searches every field whether the template renders it or not, so cards can be found by what a slide said.

---

## Model

**`Question.swift`** — the core type, plus `CropRect`, `Mask`, `OcclusionMode` and `PageSet`.

Crops are stored **normalized** — fractions of the page box, not points — so a stored crop stays correct at any render width and survives a PDF replaced by an annotated version whose page box differs slightly. `questionCrops` and `answerCrops` are separate maps because Slide2Slide can cite the same page on both sides, and one map keyed by page number cannot distinguish them.

A mask's id is a ULID, not its array position, because it becomes part of the GUID of the card that mask produces. Index-based ids would look identical and silently reshuffle review history the first time a mask was deleted from the middle.

`encode(to:)` is hand-written so Int-keyed maps serialize as string keys; Swift's synthesized encoding emits them as a flat `[key, value, key, value]` array, which is unreadable in a file users are expected to be able to open.

**`LectureDocument.swift`** — one PDF and its questions. Autosaves 1.5 s after the last keystroke, forced on commit, lecture switch, resign-active and quit. Writes are atomic (temp file then rename), so a crash cannot truncate a lecture. A file modified underneath the app is copied aside as `.conflict.ankiflow.json` rather than overwritten.

**`PageSketch.swift`** — detects that slides moved. Each page's words are hashed and the lowest 24 kept as a bottom-k sketch; pages are compared by Jaccard overlap rather than equality, because annotating a slide changes its words and an exact hash makes every annotated slide look like a different slide. Alignment is Needleman–Wunsch and **order-preserving** — slides get inserted and deleted, not shuffled — which is what allows a loose match threshold without slide 4 ever pairing with slide 30. Pages with no readable text fall out of the alignment entirely and have their offset inferred from the nearest anchored pages either side; those are always surfaced for confirmation rather than applied.

**`OrphanRecovery.swift`** — question files whose PDF has gone. Evidence is tiered: identical file hash, then slide-text overlap, then words shared with the old filename. It proposes and never applies, because a wrong pairing attaches a semester of questions to the wrong slides.

**`UndoLog.swift`** — library-wide undo/redo in `.ankiflow/undo.json`, 40 steps, surviving quit. Each step stores the questions before and after, and the lecture relative to the library root so the log survives the library being moved. A step that trashed files stores where each one went instead, so undo can put them back. Deliberately not in the sidecars: that would rewrite every question file on every small action.

**`Library.swift`** — scans the folder tree, maps folders to deck names, owns `LibrarySettings`, performs renames, drag-moves and trashing so the question file travels with its PDF, and sweeps away empty question files. `contentsSignature()` hashes folder modification dates; `AppState` polls it every two seconds so changes made in Finder appear without a refresh.

**`AppState.swift`** — the single `ObservableObject` views read. It also owns every attachment gesture (`extendToCurrentPage`, `toggleCurrentPage`, `setAnchorToCurrentPage`, crops, masks), because those are logic rather than UI and the menu bar needs to call them.

It forwards `objectWillChange` from `LectureDocument`, `Library`, `TemplateStore`, `UpdateChecker` and `SourceUpdater`. **Anything observable you add must be forwarded too** — without it, a change publishes on that object while every view is observing `AppState`, and nothing redraws. That failure looks like "the checkbox registers but doesn't tick."

---

## Export

**`CardComposition.swift`** — which images belong on each side of a card. Shared by the exporter and the preview, so a preview cannot disagree with the deck. Anything that changes card layout belongs here, not in either caller.

**`AnkiExporter.swift`** — writes `collection.anki2` (legacy schema 11) plus media into a stored ZIP. One question is normally one note; a `separate`-mode occlusion question is one note per mask, GUID `qid#maskId`, each with its own record in `childExports`.

**`AnkiConnect.swift`** — talks to a running Anki on `127.0.0.1:8765`. It does **not** create notes field by field: it builds the same `.apkg` and asks Anki to import it, so the merge discipline stays on a single code path and cannot drift between the two routes. It also does the two things package import cannot — `deleteNotes` and `changeDeck` — scoped by the `QID` field so it can only touch notes this app made. Import paths are tried in order (the file where it is, staged in the media folder by absolute path, then by bare name) because add-on builds differ in how they resolve that argument.

**`ZipWriter.swift`** — stored (uncompressed) entries; Anki accepts these and it avoids a compression dependency. **`SQLiteDB.swift`** — thin wrapper over the system SQLite.

---

## PDF

**`PageRenderer.swift`** — renders pages to card images with deterministic filenames:

```
af_<pdfSha8>_p0012_c<crop>_m<masks>_w1600v1.webp
```

Every component earns its place. The PDF hash means an edited PDF produces new files; the crop and mask hashes mean two different renders of one slide cannot collide; width and render version mean a settings change actually produces new images instead of serving the cache. Deterministic names also give free deduplication when six questions cite one slide, and make re-export idempotent.

**`PDFPane.swift`** — the viewer, two-way bound to the current page so ⌘↓/⌘↑ work while the cursor sits in a text field. `CropOverlayView` sits above it as a sibling and is invisible to the mouse unless ⌥ is held, which is why cropping needs no mode. It **never touches the `PDFDocument`** — PDFKit would happily draw the rectangle as an annotation, but the renderer reads the same document and the box would be baked into the exported image. It tracks drags in an event loop rather than relying on `mouseDragged`, which PDFKit swallows, and redraws on the scroll view's bounds notifications so overlays follow the page.

---

## UI conventions

**Views hold question ids, never `Question` structs.** A captured struct goes stale the moment the model changes, and a control bound to a stale copy silently discards edits. `QuestionCard` takes a `qid` and reads through the document; `bind(_:default:)` builds live bindings from it.

**Menu commands, not view-local key handlers.** Every shortcut is a `CommandGroup` item so it fires while the cursor is in a text field. That is the app's central interaction claim; a key handler attached to a view would break it.

**Two palettes, one structure.** `Palette.editorial` (light) and `Palette.studio` (dark) differ only in colour — no layout changes between them. Read colours from `@Environment(\.palette)`, never from `Theme` directly except for the semantic export colours.

---

## Adding a card type

The likeliest fork. Five places, in order:

1. `QuestionKind` in `Question.swift` — add the case. The compiler will then walk you through every switch that needs it.
2. `PanelType` in `AppState.swift` — add the matching case, `kind`, and `matches(_:)`.
3. `AppState.counts()` — add it to the tab row.
4. `QuestionPanel.editor(_:)` — the editing UI for it.
5. `CardComposition.images(for:mask:)` and `AnkiExporter.renderText` — what it becomes on a card.

If it stores new per-question data, add it to `Question`, to `encode(to:)`, and to `contentHash`. If it changes the rendered image, add it to the media filename too.

---

## Testing

`Tests/AnkiRoundTrip/` holds a Python mirror of the exporter and a test that exercises it against the **real `anki` library** — export, study, edit, re-export, merge, and confirm scheduling survived.

```bash
pip install anki genanki
python3 Tests/AnkiRoundTrip/test_roundtrip.py
```

Thirty-nine checks, covering crops, occlusion (including per-mask scheduling and deletion), same-second re-exports, moved lectures and retired questions.

**If you touch `Export/`, run it.** The behaviours it pins down — the `mod` rule, duplicate skipping, and the media consequence of a skipped note — are not documented by Anki and were established by experiment. They are easy to break by reasoning and hard to notice by hand: the symptom is a card that quietly stops updating, or an image that quietly stops existing.

`mirror.py` must be kept in step with `AnkiExporter.swift`. It is a second implementation of the same rules, and it is only useful while both agree.
