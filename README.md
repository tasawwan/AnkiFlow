<img src="docs/images/logo.png" width="96" align="left" alt="" hspace="14">

# AnkiFlow

**Turn lecture PDFs into Anki decks, fast.**

As you review a lecture, write big picture questions, and attach slides that answer them. From the app you can export directly to Anki — the front of the card is your question and the back is those slides, stacked so you can scroll through and check yourself. As you update your deck in AnkiFlow, you can reexport directly to Anki to update your cards.

Using keyboard shortcuts, you can create Anki decks with just a few key strokes, in just a few seconds.

![The main window](docs/images/Basic%20Question.png)

<sub>macOS 14 or later · free · open source</sub>

---

## Contents

- [Install](#install)
- [Your first deck](#your-first-deck)
- [The core move](#the-core-move)
- [Kinds of card](#kinds-of-card)
- [Cropping a slide](#cropping-a-slide)
- [Checking your cards before you export](#checking-your-cards-before-you-export)
- [Exporting](#exporting)
- [Send cards straight to Anki](#send-cards-straight-to-anki)
- [Finding things](#finding-things)
- [Where your work lives](#where-your-work-lives)
- [Keyboard](#keyboard)
- [Problems](#problems)

---

## Install

You'll need a Mac running macOS 14 or later, [Anki](https://apps.ankiweb.net) for the actual reviewing, and Apple's command line tools. If you've never installed those, open Terminal and run:

```bash
xcode-select --install
```

Then pick a folder to keep AnkiFlow in — your Documents folder is fine, anywhere you'll be able to find it again. **Whatever folder you're in when you run `git clone` is where AnkiFlow's code will live, and you'll need it again to update.** For example:

```bash
cd ~/Documents
git clone https://github.com/tasawwan/ankiflow.git
cd ankiflow/App
./make-app.sh --install
```

The first build takes a few seconds. When it finishes, AnkiFlow is in your Applications folder. Open it, then right-click its Dock icon ▸ Options ▸ Keep in Dock.

**To update later**, use **AnkiFlow ▸ Check for Updates**. If there's a new version it copies the update command to your clipboard and opens Terminal in the right folder — paste, press Return, and the app rebuilds and reopens itself.

---

## Your first deck

**1. Open your lectures.** File ▸ Open Library (⌘O), and choose the folder your PDFs live in. Subfolders become deck levels in Anki, so the folder tree you already have is the deck structure you get. Nothing is copied or moved — AnkiFlow reads your folder where it sits.

**2. Click a lecture** in the sidebar. The slides fill the middle; your questions go on the right.

**3. Write a question.** Press ⌘N, type it, and attach the slides that answer it (below).

**4. Export.** Press ⌘D.

---

## The core move

You're reading slide 12, where a topic starts.

| | |
|---|---|
| **⌘N** | New question, already holding the slide you're on |
| *type* | "What is the key function of respiration?" |
| **⌘↓** a few times | Read forward to slide 18 — **the slides scroll while your cursor stays in the text box** |
| **⌘E** | The answer becomes slides 12–18 |
| **Tab** | Move to the next field — written answer, then tags (⇧Tab goes back) |
| **⌘⏎** | Done. The card folds shut. |

No mouse, and no leaving the question you're typing.

**When the slides aren't in a neat run:**

- **⌘T** adds or removes just the slide you're on, for the strays
- **⌘R** starts a fresh range here instead of extending the old one
- Or click the **Answer slides** row twice and type `12-18, 22` directly

---

## Kinds of card

Pick the kind at the top of the panel. It applies to the whole panel, so you're only ever making one kind at a time.

### Basic

Your question on the front, the attached slides on the back. This is most cards.

### Slide2Slide

The slides *are* the question. Optional text on the front lets you ask something specific about them — *"which step here is rate-limiting?"* — and other slides answer it.

![Slide2Slide](docs/images/Slide%20to%20Slide.png)

Click either slide row to aim ⌘E and ⌘T at it. The armed row has an amber dot.

### Image Occlusion

Hide parts of a slide and recall them. Choose **Image Occlusion**, go to the slide, then **hold ⌥ and drag** over anything you want covered.

![Image Occlusion](docs/images/Image%20Occlusion.png)

Two ways to turn that into cards:

- **All at once** — one card. Everything hidden on the front, everything visible on the back.
- **One at a time** — one card per region. The front hides everything with the region *that* card is asking about marked in amber; the back shows everything with that same region boxed.

The panel tells you how many cards you're about to make before you export.

Each region keeps its own review history, so you can add and remove regions later without disturbing the ones you've been studying.

### Your own question shapes

If you notice you're typing the same shape for a third time — *"A patient presents with ___. What is the diagnosis?"* — make it a template. Settings ▸ Templates ▸ New Template, then select a phrase and press ⌘B to turn it into a blank.

![A template in use](docs/images/Custom%20Question%20Type.png)

**Slides on** decides whether cards from that template carry their slides on the front, the back, or both. Deleting a template turns its questions into Basic ones, keeping the text exactly as it reads — nothing is lost.

---

## Cropping a slide

Sometimes you only want one figure from a busy slide. **Hold ⌥ and drag** on the page: everything outside the rectangle dims, and when you let go the card will show just that region.

![Cropping a slide](docs/images/Crop.png)

A cropped slide is outlined on the page, and the slide row counts them — click that badge to see which slides are cropped and remove any of them. ⌘U removes the crop on the slide you're looking at.

The crop belongs to whichever slide row is armed, so the same slide can be cropped one way on a card's front and another on its back.

**Your PDF is never modified.** The crop is four numbers in the question file, and it's stored as a proportion of the page — so it stays correct even if you keep annotating the PDF in another app.

---

## Checking your cards before you export

Press **⌘P**. You see your cards the way they'll appear, drawn by the same code that builds the deck.

![Previewing cards](docs/images/Preview.png)

This catches things that are invisible in the panel: a crop that clipped a label, a mask over the wrong structure, a range that took 12–18 when you meant 12–8. Press **E** on any card to jump straight to that question and fix it.

Two ways through: **flashcards**, where Space reveals the answer and then moves on, or **continuous** — one long scroll of question, slides, a rule, then the answer and its slides.

Nothing is graded and nothing is saved here. Anki does the spaced repetition. However, this is a great way to quickly move through the lectures.

---

## Exporting

Press **⌘D**.

![The export window](docs/images/Export%20Window.png)

Choose how much to export — this lecture, this folder, or everything — and where it should go.

**The important part is the second time.** Add questions to a lecture, export again, and Anki **updates your existing cards while keeping every interval, due date and ease**. Only questions that genuinely changed get rewritten, and the export window tells you how many.

![What an export did](docs/images/Export%20Confirmation.png)

If you're importing a `.apkg` file by hand, leave Anki's **Update notes** on *If newer* and tick **Merge notetypes**. The export window reminds you.

### Two things Anki can't do

Neither is a bug — it's how importing works — so AnkiFlow tells you rather than hiding it.

**Cards never change deck.** Reorganise your folders and cards you've already studied stay where they first landed. The export window gives you a search to paste into Anki's browser: select them all, then Change Deck.

**Deleting a question doesn't delete its card.** AnkiFlow remembers what you removed and hands you a search for exactly those cards — or, if Anki is running, deletes them for you.

---

## Send cards straight to Anki

**This is the way to do it.** Choose **Straight into Anki** in the export window and your cards appear in Anki immediately — no save dialog, no file to find, no import screen, no checkboxes to get wrong. It's the same cards either way; it just removes every step where something can go wrong, and it means the "If newer / Merge notetypes" settings can never be set wrongly by accident.

It needs a free add-on called AnkiConnect. Once, in Anki:

1. **Tools ▸ Add-ons ▸ Get Add-ons…**
2. Paste in this code: **`2055492159`**
3. Click OK, then restart Anki

That's it. Leave Anki running when you export and AnkiFlow will find it. If Anki is closed, the export window says so and falls back to saving a file, which always works.

---

## Finding things

| | this lecture | everywhere |
|---|---|---|
| **slides** | ⌘F | ⇧⌘F |
| **your questions** | ⌥F | ⌥⌘F |

⌘F searches the slides of the lecture you have open and jumps to the hit — what you want while writing a question. The library-wide searches show you which lectures match, and you click through to the hits.

---

## Where your work lives

Nothing is hidden in a database.

```
YourLectures/                    ← the folder you opened
├── Immunology/
│   ├── Lecture 04.pdf
│   └── Lecture 04.ankiflow.json ← your questions for that lecture
└── .ankiflow/                   ← settings, image cache, undo history
```

Your questions sit next to the PDF they belong to, as plain readable text. They're hidden in Finder by default (press ⇧⌘. to see them), and a lecture with no questions gets no file at all.

**There's no Save.** AnkiFlow saves as you type. ⌘⏎ finishes a question and folds it shut; ⌘U undoes, ⇧⌘U redoes, and that history survives quitting the app.

**Renaming and moving lectures.** Do it inside AnkiFlow — **drag a lecture onto a folder** to move it, and right-click for Rename or Move to Trash — and your questions travel with the PDF. If you do move a PDF in Finder and leave its questions behind, AnkiFlow notices next time it scans the library and offers to put them back together, showing you which lecture it thinks they belong to and why.

**If you annotate your slides**, that's fine and expected — the app re-renders them for your next export. **If you add or delete a slide**, AnkiFlow notices that too, works out where each of your slides went by what it says, and asks you to confirm before renumbering your questions. Slides with no text on them are worked out from their neighbours, and it always asks about those.

---

## Keyboard

Every one of these is a menu command, so they work while your cursor is in a text box.

| Key | |
|---|---|
| ⌘N | New question |
| Tab / ⇧Tab | Next / previous field |
| ⌘↓ ⌘↑ | Next / previous slide — **works while typing** |
| ⌘E | Extend the range to the slide you're on |
| ⌘T | Add or remove just this slide |
| ⌘R | Start a new range here |
| ⌥-drag | Crop a slide, or hide a region on an occlusion card |
| ⌘⏎ | Finish this question |
| ⌘B | Add a written answer |
| ⌘⌫ | Delete this question |
| ⌘U / ⇧⌘U | Undo / redo |
| ⌘Y | Switch card kind |
| ⌘P | Preview your cards |
| ⌘D | Export |
| ⌘O | Open a different folder of lectures |
| ⌘F ⇧⌘F ⌥F ⌥⌘F | Find (Search local slides, library slides, local questions, library questions)|
| ⌘1 ⌘2 | Sidebar / slide gallery |
| ⌘? | This documentation, inside the app |

---

## Problems

Something not working, or an idea for it? **[Open an issue on GitHub](https://github.com/tasawwan/ankiflow/issues)** — that's the right place for both, and it means other people with the same problem can find the answer.

Your questions are safe whatever happens to the app: they're plain files next to your PDFs, and deleting or reinstalling AnkiFlow doesn't touch them.

---

MIT licence. © 2026 Tasawwar Rahman.
