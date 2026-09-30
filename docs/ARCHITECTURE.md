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

Three things are load-bearing. Everything else in the app is a convenience; these are why re-exporting updates your cards instead of duplicating them. The exporter round-trip tests cover the identifier, timestamp, and content-hash invariants; PDF editing, flags, and UI navigation are not currently covered by automated tests.

**Frozen identifiers** (`Model/Identifiers.swift`). *Both* note type names and ids, the seven field names and their order, and the sidecar extension are permanent. Each question's ULID becomes its Anki note GUID verbatim, and Anki matches notes by GUID *within a note type*. Change either after a user's first export and every studied card orphans — new cards appear, the old ones stay behind with their review history and no way to reconcile them.

There are two models: the standard one and a cloze one, sharing the same seven fields in the same order so the exporter builds one field array for every kind of question. Anything that hands Anki a *search* must scope to both — `AnkiIdentity.noteTypeScope` exists for that, and a search naming only one model silently misses every cloze card.

**The `mod` discipline** (`Export/AnkiExporter.swift`). Anki only updates a note whose `mod` timestamp is *strictly* newer than the copy in the collection. Equal timestamps are silently treated as duplicates and skipped — **along with the note's media**, which surfaces as a card with a missing image and no error anywhere. The exporter therefore stamps `max(now, previousMod + 1)` for changed notes, and re-stamps the *unchanged* previous value for notes whose content hash matches, so Anki correctly skips them.

**`Question.contentHash`** decides what counts as changed. It hashes text, blanks, page lists, crops, masks, occlusion mode, tags, the template's fingerprint, the library's render version, and the PDF's own hash. That last one is easy to overlook and important: media filenames derive from the PDF hash, so an annotated PDF produces new image files — without the hash in the content hash, the exporter would call the note unchanged and Anki would keep showing images that no longer exist.

If you add anything that changes how a card renders, it must go into `contentHash` **and** into the media filename if it changes the image. Missing either produces a silent wrong-picture bug rather than a visible failure.

When a *drawing* changes rather than a card's content, the library-wide `renderVersion` is the general tool — but it re-renders and re-exports everything. For a change that affects one kind of card, add a scoped revision token to `contentHash` under a condition instead, and spell the media fingerprint so the unaffected cases produce byte-identical filenames. `allAtOnce-r2` in `Question.contentHash` and the `"o"` component of `MaskPaint.fingerprint` are the worked example: only all-at-once occlusion answers changed, and only those re-exported.

---

## If you fork this

**Decide immediately whether your fork shares a card lineage with AnkiFlow.**

- **Sharing** (a patch you intend to upstream, or a build for your own existing decks): leave `AnkiIdentity` alone. Your exports will merge with cards AnkiFlow already made.
- **Diverging** (a differently-named app, a different card design): change `appName`, `noteTypeName`, `noteTypeID`, `clozeNoteTypeName`, `clozeNoteTypeID`, `deckRoot`, `sidecarExtension` and `repository` in `Identifiers.swift` **before anyone exports anything**. Pick a fresh random 64-bit id for each note type. Two apps sharing a note type id but disagreeing about its fields will corrupt each other's notes.

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

### The notes file

One per lecture, named after the PDF and sitting beside it: `Innate Immunity.pdf` gets `Innate Immunity Notes.md`. Not hidden — you are meant to open it in other things, and in a folder of them the name has to say what it is.

Deliberately kept away from the question file. Questions have a merge contract with Anki to honour; a note is prose. Keeping them apart means a malformed note can never make a lecture's questions unreadable, and the note can be edited, synced or deleted by anything else without this app caring.

`RichTextMarkdown` is the whole of the format decision, and the rule is: **if the format cannot say it, the editor does not offer it.** Headings, `**bold**`, `*italic*`, `~~strike~~`, `- ` lists and `[links](…)` are written as Markdown; underline is the one `<u>` tag every renderer honours.

An earlier version also wrote colour, point size and typeface as inline `<span style="…">`. It round-tripped and it was wrong: the file filled with HTML only this app would have produced, and the reason notes live next to the PDFs as plain `.md` is that they should read well in Obsidian, on a phone, in TextEdit, in ten years. Making text bigger has a Markdown answer already — it is a heading. The toolbar was cut to match, because a button that silently loses formatting on save is worse than no button.

Storing the whole note as HTML would round-trip perfectly for free, and was rejected for the same reason.

Reading is hand-written rather than `NSAttributedString(markdown:)`, which discards the `<u>` tags — underline would be silently lost on every open.

`LectureNotes` polls the file every two seconds, the same way `Library` watches its folder. The folder is the truth: an external edit is reloaded, and a file deleted in Finder empties the pane rather than being silently rewritten by the next autosave. The reload is signalled by a `reloadToken` rather than by the editor watching `text`, which changes on every keystroke — reloading the view from that would reset the caret with each character typed.

The file holds three things, in this order: the topics block, the lecture-questions block, then the prose. Both blocks are fenced by HTML comments (`<!-- ankiflow:topics -->`, `<!-- ankiflow:questions -->`) — invisible in every rendered view of the Markdown, and unambiguous to find. They compose rather than nest: `TopicBlock.split` takes its block off the front and hands the rest to `QuestionBlock.split`, and `join` runs the other way round, so a file with neither block is exactly the prose.

**The blocks never reach the editor.** `LectureNotes.text` is the prose alone; the blocks are split off on load and re-emitted on save. The panels are the editing surface for them, and the notes editor shows what you wrote and nothing else.

A lecture question is a **draft card**: `text`, `answer`, `questionSlides`, `answerSlides`, `tags`, `answered`. Everything a `Question` has, held here rather than in the sidecar because it is not finished. Promotion maps it across whole and adds `AppState.promotedTag`, registering that tag in the library's list so it is filterable like any other.

In the block, `Slides:` unqualified means the answer's — that is what it has always meant, so a notes file written before questions had a front row still reads correctly. The front row is `Question slides:`, and tags are `Tags:`.

**Both are read forgivingly and written canonically.** A topic line with no rating parses as `low`; a bare line under a question is taken as that question's answer even without the `>` marker; slide lists accept `12, 14` or `12–14` in any case. `blockIsCanonical(in:)` then asks whether what is on disk is already exactly what this app would write, and if not schedules a tidy save — so a topic added by hand in VS Code is rated and sorted into place about a second later.

That comparison is deliberately **block-only, never the prose.** `RichTextMarkdown` is not guaranteed byte-identical round-trip, and rewriting somebody's notes because a space moved would be exactly the silent edit that keeping notes as a plain file is meant to prevent.

Topics are written sorted — weakest first, then alphabetically — because being readable in the Markdown is the whole reason they live there. Lecture questions are **not** auto-sorted: the order you asked them in is information. Neither list reorders when you rate or tick a row, because a row that moves out from under the cursor mid-click makes the panel unusable; both panels sort on demand from a button in their header.

`LectureQuestion.slides` attaches to the *answer*, which is what makes promotion a straight mapping: question → front, answer → back, slides → answer stack, the shape a Basic card already has. `AppState.promoteLectureQuestions` moves rather than copies — the same question in two lists is two places to keep an answer in step. It builds the cards before recording anything so the undo step can carry their qids, which is what makes the move one action: a single ⌘Z removes the cards *and* puts the questions back, rather than the two halves coming back on separate presses from two different ledgers.

### `AnkiIdentity.Companion`

The list of what belongs to a lecture besides the PDF. Rename, move, trash and orphan recovery all iterate it. Adding a companion file anywhere else means finding all four of those call sites again and missing one.

Note the shape of the iteration: each case builds **both** ends of a rename from the PDF's name, because the two companions are named by different rules — the question file appends an extension, the note file appends a word *and* an extension. Deriving a destination from the source URL instead is the bug this shape exists to prevent: `URL.pathExtension` on `Lecture 04.ankiflow.json` is `json`, so a destination rebuilt from it renames the question file to `New Name.json` and orphans every question in it.

### Where state lives

| | |
|---|---|
| `Application Support/AnkiFlow/Settings.json` | Deck root, tag definitions, render settings, `renderVersion` |
| `Application Support/AnkiFlow/Templates.json` | Every template, built-ins included |
| `~/Library/Caches/AnkiFlow/slides` | Rendered slide images. Safe to delete; regenerated on demand. |
| `<lecture>.ankiflow.json` | That lecture's questions, beside its PDF |
| `<lecture> Notes.md` | That lecture's notes, topics and lecture questions |

**Nothing is written inside a library any more.** Settings moved to `Application Support/AnkiFlow/Settings.json` (`SettingsStore`, a `@MainActor` singleton; `Library.settings` is a passthrough to it so `library.settings.x` still reads the same, and `Library` forwards its `objectWillChange` or nothing redraws). Rendered slide images moved to `~/Library/Caches/AnkiFlow/slides` — `AppPaths.cacheDirectory`, one cache for every library, which is safe because the media filenames already carry the PDF's own SHA-256 prefix. Save snapshots are gone entirely.

`LibraryPaths` survives for two jobs only: recognising a leftover `.ankiflow` folder so the library scan skips it, and reading its `library.json` once in `SettingsStore.adoptOldLibraryFile`. Everything but the deck root comes across in that read, because the deck root changed meaning.

No undo history either: every stack in the app is session-scoped.

**Deck names are `<root>::<library folder>::<folders>::<lecture>`.** The root is one app-level setting; the library's own name comes from its folder rather than being stored, which is what lets the app keep nothing per library. `resolvedDeckRoot` **may be empty**, meaning no level above the library — that is the escape hatch for someone whose cards were exported under the old scheme, where the root *was* the library name. Every caller has to guard for the empty case; the one that did not turned an interpolated `"\(root)::"` strip pattern into `"::"` and glued every level of a deck name into one word.

Changing the root after an export splits the collection, because Anki does not move existing cards between decks on import. Settings earns its warning by counting questions with an `export` record.

### Templates are a lens, not a card format

Nothing about a template is written into a question file. A card made through one is an ordinary `kind: .basic` (or `.occlusion`, or `.cloze`) question holding its own finished `front` and `back`; `templateId` and `blanks` are legacy fields that only ever decode. The template's job is the inverse operation: `Template.recover(front:back:)` reads a rendered string back into the values that produced it, which is what puts a card in a template's tab and what fills the blank fields you edit it with.

This is why deleting a template cannot damage a card, and it is the whole reason for the design. Under the old scheme the words on a card lived in the template file and the card held only the blanks — a card held hostage by a file it never mentioned, one Application Support wipe away from being blank. `AppState.adoptTemplateText()` converts any surviving old-scheme question the first time its lecture is opened, and `deleteTemplate` still sweeps unopened lectures across the library for the same reason.

**Matching is front-only.** The wording of the question decides; the answer and the tags do not, because both are things you change freely afterwards and neither should move a card out from under you. The back is read too, but only to recover values it can supply — a back that does not fit costs nothing.

`Template.readings(of:dropping:)` returns two patterns, not one: everything present, and the `optional` blanks removed along with the whitespace that only separated them. That is what lets `How does {{disease}} present?\n\n{{details}}` recognise both the card with details and the card without. `Template.tidy` collapses the blank line an unfilled optional blank leaves behind, so a rendered card matches its own shape.

`pieces(_:)` treats a `{{key}}` containing a colon as literal text. Anki's cloze markup wears the same braces — `{{c1::answer}}` — and reading one as a blank named `c1::answer` would make a cloze template impossible to write.

When several shapes fit, the most literal characters in the **front** wins, ties broken on id: which tab a card sits in must not depend on the order templates happened to load in.

Templates are **not** per library — they live in Application Support, so they follow you between courses. One file, `Templates.json`, not a folder of them: a folder meant a delete could half-succeed, leaving a template on disk the app had already stopped listing. `TemplateStore.adoptOldFolder` folds an older `Templates/` directory in once and renames it. Built-ins are merged in by `reload()` whenever the file does not mention them, which is what makes them undeletable without a rule saying so anywhere else.

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

### The cloze note type

The same seven fields, `"type": 1`, one template, and a different id. The cloze text lives in `Front`.

```
Front:  <div class="q">{{cloze:Front}}</div>
        {{FrontMedia}}

Back:   <div class="q">{{cloze:Front}}</div>
        {{FrontMedia}}
        {{#Back}}<hr id="answer"><div class="a">{{Back}}</div>{{/Back}}
        {{BackMedia}}
        <div class="src">{{Source}}</div>
```

The back repeats the cloze rather than using `{{FrontSide}}`: on a cloze card `{{FrontSide}}` keeps the deletion hidden, so the answer would never appear.

**This is the only kind that makes several cards from one note.** Everything else — including a separate-mode occlusion question — makes several *notes*, each with its own GUID. A cloze note gets one row in `cards` per distinct `{{cN::}}` ordinal, with `ord = N - 1`; that `ord` is what tells Anki which deletion each card hides. `Cloze.ordinals` is the single source of that set, used by the exporter and the preview alike.

Two consequences worth knowing before you touch this:

- Card ids come from their own counter, not from `noteID + 1`. With several cards per note the derived form collides.
- A cloze note with no deletions generates no cards. Anki accepts it and it then sits in the collection invisible, so the exporter skips it and reports the count in `ExportSummary.skippedCloze`.

---

## Model

**`Question.swift`** — the core type, plus `CropRect`, `Mask`, `OcclusionMode` and `PageSet`.

Crops are stored **normalized** — fractions of the page box, not points — so a stored crop stays correct at any render width and survives a PDF replaced by an annotated version whose page box differs slightly. `questionCrops` and `answerCrops` are separate maps because a question can cite the same page on both sides, and one map keyed by page number cannot distinguish them.

A mask's id is a ULID, not its array position, because it becomes part of the GUID of the card that mask produces. Index-based ids would look identical and silently reshuffle review history the first time a mask was deleted from the middle.

`encode(to:)` is hand-written so Int-keyed maps serialize as string keys; Swift's synthesized encoding emits them as a flat `[key, value, key, value]` array, which is unreadable in a file users are expected to be able to open.

**`Topic.swift`** / **`LectureQuestion.swift`** — the two structured lists that live in the notes file, and the parsers and writers for their blocks. Identity is the text itself (`name.lowercased()`, `text.lowercased()`), so nothing invisible has to be written into a file the user reads in a text editor; the cost is that editing a row re-keys it, which is fine for lists this size and is why neither supports duplicates. `TopicBlock.rate`/`rename`/`remove` do a read-modify-write on *another* lecture's file, for the folder and library scopes; the open lecture always goes through its own `LectureNotes`, which owns the file and is watching it.

**`LectureDocument.swift`** — one PDF and its questions. Autosaves 1.5 s after the last keystroke, forced on commit, lecture switch, resign-active and quit. Writes are atomic (temp file then rename), so a crash cannot truncate a lecture. A file modified underneath the app is copied aside as `.conflict.ankiflow.json` rather than overwritten.

**`PageSketch.swift`** — detects that slides moved. Each page's words are hashed and the lowest 24 kept as a bottom-k sketch; pages are compared by Jaccard overlap rather than equality, because annotating a slide changes its words and an exact hash makes every annotated slide look like a different slide. Alignment is Needleman–Wunsch and **order-preserving** — slides get inserted and deleted, not shuffled — which is what allows a loose match threshold without slide 4 ever pairing with slide 30. Pages with no readable text fall out of the alignment entirely and have their offset inferred from the nearest anchored pages either side; those are always surfaced for confirmation rather than applied.

**`OrphanRecovery.swift`** — question files whose PDF has gone. Evidence is tiered: identical file hash, then slide-text overlap, then words shared with the old filename. It proposes and never applies, because a wrong pairing attaches a semester of questions to the wrong slides.

**`UndoLog.swift`** — library-wide undo/redo for your questions, 40 steps, in memory. Each step stores the questions before and after, and the lecture relative to the library root so the log survives the library being moved. A step that trashed files stores where each one went instead, so undo can put them back. Deliberately not in the sidecars: that would rewrite every question file on every small action.

**Every stack is session-scoped.** This one used to persist to `.ankiflow/undo.json` and reload at launch; it no longer does, and `init` deletes any file an older build left behind. Undoing something from three days ago on a freshly opened app is a worse surprise than having nothing to undo, and one rule across all four stacks is worth more than a longer reach in one of them. Recovering from a deletion noticed later is not undo's job: lectures go to the system Trash, question files are readable JSON, and `OrphanRecovery` reunites a sidecar with its PDF.

**The four stacks, and what routes between them.** `UndoLog` for cards; `PDFEditSession`'s own closure stacks for markup, which are pending until ⌘S; `NotesUndoLog` for topics and lecture questions; and `NSTextView`'s own for typing. `AppState.undo()` dispatches in that order of specificity: markup while the edit bar is up, then the focused text field, then whichever list ledger `lastListSurface` names. That last one is a variable rather than a focus test because clicking a rating chip or a checkbox does not move the first responder.

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

**`PDFEditing.swift` / `PDFEditSession.swift` / `PDFEditOverlay.swift`** — the deliberate exception: the only code in the app that writes to the user's lecture file. `PDFEditOverlayView` is a second sibling above the crop overlay whose `hitTest` returns nil unless a tool is in hand, so with editing off the pane behaves exactly as it did before this existed.

`PDFEditSession` is what makes the editor trustworthy. Annotations are added to the **in-memory** `PDFDocument` — which is what the `PDFView` draws, so a mark appears at once — and nothing reaches the file until ⌘S. Undo is a private pair of closure stacks rather than an `NSUndoManager`: AppKit's is shared with every text field in the window, and ⌘Z already means "undo what I did to my questions", so `AppState.undo()` routes to the session only while `isEditingPDF`.

**Surviving a reload.** The lecture can be replaced under an open session — annotated on an iPad, synced back by the cloud folder. `LectureDocument.reloadPDFFromDisk(replaying:)` *moves* the unsaved annotations onto the freshly-loaded document rather than copying them, so every object an undo step holds is still the object on the page; pages, which cannot survive the swap, are reached through `PDFPageBinding`, a redirection table the session owns and every step's page work goes through. `PDFEditSession.adopt` records the redirection and swaps in a new baseline, and the history keeps working. Only two things break it: a mark PDFKit refused to move across (so a copy had to be made), and a slide you had reordered — neither is replayable, and in both cases `AppState` rebuilds the session instead and the marks arrive as a clean slate.

Two rules in that file are easy to get wrong:

- **`perform` runs the redo closure; `record` does not.** A drag applies itself as you drag, so replaying it on the way in would move the mark twice. Anything applied live is `record`ed.
- **Annotation geometry is not always `bounds`.** Ink keeps its paths and Line keeps its endpoints, both with `bounds` pinned to the media box so the two possible PDFKit readings of "relative to bounds" coincide. `PDFEditing.move`, `frame(of:)` and `isResizable` branch on `kind(of:)`, which strips the leading slash PDF puts on a subtype name — branching on the raw `type` gives you an editor where lines and sketches silently refuse to move.

Two rules hold it together, and both are easy to break by accident:

**Every operation reports what it did to the numbering.** `PDFEditing.Change` carries `remap` (old 1-based page → new), `removed` (old numbers that are gone) and `boxChanges` (keyed by *new* number). `LectureDocument.applyPDFEdit` consumes them in a fixed order — remove, then remap, then convert boxes — because `removed` is in the old numbering and `boxChanges` is in the new one. Doing the removal after the remap deletes the *wrong* slide from every question: the deleted page's old number now belongs to whatever moved up into it. `applyPageShift` has the same ordering for the same reason.

**Changing a page box rewrites the crops on that page.** Crops and masks are fractions of the crop box. Trim the box without converting them and every one of them points somewhere else — silently, on cards that already have review history. `CropRect.converted(from:to:)` is that conversion.

The other thing to know: because `contentHash` includes the PDF's hash, *any* edit here re-exports every note in that lecture. That is correct — every slide image changed — but it means a single pen stroke is not a cheap operation at export time.

---

## UI conventions

**Views hold question ids, never `Question` structs.** A captured struct goes stale the moment the model changes, and a control bound to a stale copy silently discards edits. `QuestionCard` takes a `qid` and reads through the document; `bind(_:default:)` builds live bindings from it.

**Menu commands, not view-local key handlers.** Every shortcut is a `CommandGroup` item so it fires while the cursor is in a text field. That is the app's central interaction claim; a key handler attached to a view would break it.

**Two palettes, one structure.** `Palette.editorial` (light) and `Palette.studio` (dark) differ only in colour — no layout changes between them. Read colours from `@Environment(\.palette)`, never from `Theme` directly except for the semantic export colours.

---

## Adding a card type

The likeliest fork. Five places, in order:

1. `QuestionKind` in `Question.swift` — add the case. The compiler will then walk you through every switch that needs it. Removing one is the harder direction: `init(from:)` decodes the kind with `try?` and falls back to `.basic`, so a sidecar naming a kind you deleted still opens instead of throwing away the lecture's questions. Slide2Slide was retired that way.
2. `PanelType` in `AppState.swift` — add the matching case, `kind`, and `matches(_:)`.
3. `AppState.counts()` — add it to the tab row.
4. `QuestionPanel.editor(_:)` — the editing UI for it.
5. `CardComposition.images(for:mask:)` and `AnkiExporter.renderText` — what it becomes on a card.

If it stores new per-question data, add it to `Question`, to `encode(to:)`, and to `contentHash`. If it changes the rendered image, add it to the media filename too.

If it needs its own Anki note type, there are three more: register the model in `writeCollectionRow`, pick the `mid` per note in the export loop, and add its name to `AnkiIdentity.noteTypeScope` so the retire, move and delete searches still find its cards. Cloze is the worked example.

---

## Testing

`Tests/AnkiRoundTrip/` holds a Python mirror of the exporter and a test that exercises it against the **real `anki` library** — export, study, edit, re-export, merge, and confirm scheduling survived.

```bash
pip install anki genanki
python3 Tests/AnkiRoundTrip/test_roundtrip.py
```

Sixty checks, covering crops, occlusion (including per-mask scheduling and deletion), cloze (ordinal-to-card generation, scheduling across all of a note's cards, repeated and missing ordinals), same-second re-exports, moved lectures and retired questions.

**If you touch `Export/`, run it.** The behaviours it pins down — the `mod` rule, duplicate skipping, and the media consequence of a skipped note — are not documented by Anki and were established by experiment. They are easy to break by reasoning and hard to notice by hand: the symptom is a card that quietly stops updating, or an image that quietly stops existing.

`mirror.py` must be kept in step with `AnkiExporter.swift`. It is a second implementation of the same rules, and it is only useful while both agree.
