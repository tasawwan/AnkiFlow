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
- [Editing the PDF](#editing-the-pdf)
- [Lecture notes](#lecture-notes)
- [Topics](#topics)
- [Lecture questions](#lecture-questions)
- [Tags](#tags)
- [Checking your cards before you export](#checking-your-cards-before-you-export)
- [Exporting](#exporting)
- [Send cards straight to Anki](#send-cards-straight-to-anki)
- [Finding things](#finding-things)
- [Where your work lives](#where-your-work-lives)
- [Keyboard](#keyboard)
- [Problems and ideas](#problems-and-ideas)

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

Every card has the same four fields, always on screen and all of them optional:

> **Question** → **Question slides** → **Answer** → **Answer slides**

**Tab moves between the two text fields, and the slide row you're attaching to follows your cursor.** In the question field, ⌘E and ⌘T fill the question slides. Tab to the answer and the same keys fill the answer slides. Nothing to click, no mode to remember.

You're reading slide 12, where a topic starts.

| | |
|---|---|
| **⌘N** | New question, cursor already in the question field |
| *type* | "What is the key function of respiration?" |
| **Tab** | Move to the answer — the answer slide row is now the armed one |
| **⌘↓** a few times | Read forward to slide 18 — **the slides scroll while your cursor stays in the text box** |
| **⌘E** | The answer slides become 12–18 |
| **⌘⏎** | Done. The card folds shut. |

Nothing is attached until you attach it — ⌘T for the slide you're on, ⌘E for a run from where you started.

No mouse, and no leaving the question you're typing. Fill as few of the four as you like — a card can be a question and some slides, and often that's all it is.

**When the slides aren't in a neat run:**

- **⌘T** adds or removes just the slide you're on, for the strays
- **⌘R** starts a fresh range here instead of extending the old one
- Or click the **Answer slides** row twice and type `12-18, 22` directly

---

## Kinds of card

Pick the kind at the top of the panel. It applies to the whole panel, so you're only ever making one kind at a time.

### Basic

Your question, its slides, the answer, its slides — all four optional. This is most cards.

![A basic card](docs/images/Slide%20to%20Slide.png)

Put slides on the question side and the slides *become* the question: *"which step here is rate-limiting?"* with the pathway on the front and the answer on the back. That used to be a separate card type called Slide2Slide; it isn't any more, because a Basic card already does it. Old questions saved as Slide2Slide open as Basic with everything where you left it.

### Image Occlusion

Hide parts of a slide and recall them. Choose **Image Occlusion**, go to the slide, then **hold ⌥ and drag** over anything you want covered.

![Image Occlusion](docs/images/Image%20Occlusion.png)

Two ways to turn that into cards:

- **All at once** — one card. The front hides everything; the back shows everything, with each region you'd covered boxed in amber, so you can see at a glance which parts you were meant to have recalled.
- **One at a time** — one card per region. The front hides everything with the region *that* card is asking about marked in amber; the back shows everything with that same region boxed.

The panel tells you how many cards you're about to make before you export.

Each region keeps its own review history, so you can add and remove regions later without disturbing the ones you've been studying.

### Cloze

A sentence with pieces blanked out. Type the line, select the part you want hidden, and press **⌘⇧C**.

> The **{{c1::classical}}** pathway is triggered by **{{c2::antibody}}** bound to antigen.

That makes two cards from one question — one hiding *classical*, one hiding *antibody* — and each keeps its own review history, so adding a third blank later doesn't disturb the two you've been studying.

**Separate cards / One card** decides how the blanks are spread out. Separate is the usual thing — each blank tested on its own. One card blanks all of them at once, for the sentence where the pieces only make sense together. Flip it whenever you like: it re-groups the blanks you have already made, so you don't have to know which you wanted before you made them.

**The chevron beside Hide selection** puts the words on a card you name, instead of a new one. That's how you group blanks that aren't next to each other:

> Protein A leads to inflammation. Protein B leads to growth.

Hide *Protein A* with ⌘⇧C — card 1. Hide *inflammation* — card 2. Now hide *Protein B*, but from the chevron choose **Card 1 · Protein A**, and *growth* → **Card 2 · inflammation**. Four blanks, two cards: one asking which proteins, one asking what they do.

Underneath, the blanks are listed **grouped by the card they're on** — the one thing you can't read off the sentence, since `c1` and `c3` four lines apart look identical at a glance. **Drag a blank onto another card** to move it, or onto the dashed well at the bottom to give it a card of its own. Clicking the words opens the same choice as a menu, for when a drag is more trouble than it's worth. The ✕ un-hides them.

Slides attach to the back, the same way they do on a Basic card: the sentence tests you, and the slide is there to look at once you've answered. The answer field goes with them.

The panel tells you how many cards the question makes as you type. If nothing is hidden yet it says so — a cloze question with no blanks makes no cards at all, and AnkiFlow leaves it here rather than sending Anki a note you'd never see again.

### Your own question shapes

If you notice you're typing the same shape for a third time — *"A patient presents with ___. What is the diagnosis?"* — make it a template. Settings ▸ Templates ▸ New Template, then select a phrase and press ⌘B to turn it into a blank. **New from Question** starts one from whatever card you have open.

![A template in use](docs/images/Custom%20Question%20Type.png)

A template gets its own tab, and cards written in that shape collect there — including ones you typed out by hand before the template existed. Matching is on the wording of the question only, so changing an answer or a tag never moves a card out from under you.

**Slides go on** picks which slide row ⌘T aims at when you open one of these — both rows are always there, this just saves you clicking the usual one. **Tags** are applied to every card you make in it. A template can make Occlusion or Cloze cards as well as Basic ones.

**A template can't damage a card.** It isn't stored on one: a card you write through a template is an ordinary Basic card holding its own finished words, and the template only recognises those words afterwards. Turn a template off, edit it, delete it — every card keeps every word and simply moves back to the Basic tab.

Two shapes come with the app — **CC — disease** and **CC — presentation**, for clinical correlations. You can edit them or switch them off, but not delete them. Everything else you make can be switched off too, for the shape you want this term and not next.

---

## Tags

Every card has a row of tag checkboxes at the bottom, and every one of them goes onto the Anki note. Which tags are offered is set in Settings ▸ Tags — the switch turns a tag off without losing it, the pin decides whether it gets a permanent checkbox or lives behind the tag button. The tags AnkiFlow ships with can be renamed and turned off but not deleted; they'd only come back on the next launch.

**Yield is one button that says what it is.** Click it to walk *Normal → High → Low* and round again. Normal is the default and **carries no tag at all** — most cards are ordinary, and a tag that nine cards in ten are wearing is a search term you can never use. So only the two ends get marked, which also means every card you wrote before yields existed already reads as normal.

**Tags are lowercase and never contain a space.** Type "High Yield" and you get `high-yield`. Anki splits its tag field on whitespace, so a tag with a space in it arrives there as two tags, neither of which is the one you meant.

**Making the text bigger.** ⌘+ and ⌘− resize the notes, ⌘0 puts them back — same as the aA buttons in the notes toolbar, and they're in the View menu too. The size survives quitting.

**Filtering.** The chips under the card-type tabs narrow the list to cards carrying *every* tag you pick, and the counts on the tabs follow — so a tab reading zero really is empty under this filter. A question you make while a filter is on is born with those tags, so writing under a filter never produces a card the filter then hides. The filter is forgotten when you close the app.

---

## Cropping a slide

Sometimes you only want one figure from a busy slide. **Hold ⌥ and drag** on the page: everything outside the rectangle dims, and when you let go the card will show just that region.

![Cropping a slide](docs/images/Crop.png)

A cropped slide is outlined on the page, and the slide row counts them — click that badge to see which slides are cropped and remove any of them. Use the slide controls to remove the crop on the slide you're looking at.

The crop belongs to whichever slide row is armed, so the same slide can be cropped one way on a card's front and another on its back.

**Cropping never modifies your PDF.** The crop is four numbers in the question file, and it's stored as a proportion of the page — so it stays correct even if you keep annotating the PDF in another app. (The one place AnkiFlow does write to your PDF is the PDF menu, below, and it says so on screen while you're in it.)

---

## Editing the PDF

Everything above leaves your lecture file untouched. This doesn't — it's the one part of AnkiFlow that writes to the PDF itself, which is why it announces itself while you're in it.

**Edit PDF** at the top of the slide pane turns it on (or **PDF ▸ Edit PDF…**). The button becomes a row of tools laid out like Preview's markup bar. **Esc** or **Done** puts it away.

![Editing a PDF](docs/images/Edit%20PDF.png)

**Nothing is written until you say so.** Marks appear as you make them, but they live in memory until you press **⌘S** (or the **Save** button, which appears the moment there's something to save). **⌘Z** undoes the last PDF edit and **⇧⌘Z** redoes it. Leaving with unsaved marks asks first.

## Lecture notes

Cards are for details. Notes are for the shape of the thing — what this lecture was actually about, the bit that finally made sense, the question you want to ask someone.

The notes pane sits at the bottom of the right panel (**⌘4** to hide or show it, and you can drag the divider). It's an ordinary rich text editor: **bold** (⌘B), *italic* (⌘I), underline (⌘U), ~~strikethrough~~ (⇧⌘X), a link (⌘K), three sizes of heading, and bullets.

**Bigger or smaller text.** The two buttons at the right of the toolbar change how large your notes are drawn, from small to quite large. It's a display setting — it changes nothing in the file, and every lecture opens at the size you last chose.

**Folding.** A bullet with bullets underneath it gets a small triangle in the left margin. Click it to fold that section away while you read, and again to bring it back. Folding is just for looking at — nothing is added to or removed from the file.

Those keys only mean that while you're typing in a note; ⌘Z undoes there, the same as it does everywhere else in the app. Press a button with nothing selected and the next thing you type comes out in that style, the way it does in any editor.

There's no colour well and no font picker, on purpose — Markdown has no way to record either, so those buttons would style the text on screen and lose it on save. Bigger text is a heading, which is the answer the format already has.

**Where it goes.** A plain `.md` file beside the PDF, named after it: `Innate Immunity.pdf` gets `Innate Immunity Notes.md`. Real Markdown, the kind you'd have typed yourself. Open it in Obsidian, on your phone, in TextEdit, in ten years.

It follows the lecture the way your questions do: rename or move the PDF and the note goes with it, delete the lecture and the note goes to the Trash with it, and if the pair ever gets separated, orphan recovery brings both back together.

**The file is the truth.** Empty the note and the `.md` is removed rather than left behind as a blank. Edit it in Obsidian and the pane picks the change up within a couple of seconds. Delete it in Finder and the pane empties to match, and says so — deleting a note is a decision, not an accident to be quietly undone.

---

## Topics

A topic is a name and how well you know it. Nothing else — the writing about it goes in the notes.

The panel sits at the foot of the library sidebar, on a divider you can drag. Type a name, press return, and it joins the list. Each row has one button that steps through **Low, Medium, High, Mastered** and back round again. Double-click a topic to rename it; the ✕ on hover deletes it.

**Three views**, from the switch at the top. *Lecture* is the one you have open. *Folder* is everything in that lecture's folder. *Library* is the lot, grouped by lecture — click a lecture name to open it. Rating and deleting work in all three, so you can go through a whole block without opening a single lecture.

**The list holds still while you work.** Rating a topic doesn't move it, so nothing jumps out from under your cursor mid-session. The circular arrow at the top sorts when you're ready — least comfortable first — and in the folder and library views it also picks up anything you've changed elsewhere.

**Where it goes.** The top of the same `.md` as your notes, so opening the file anywhere shows the list above the writing it belongs to:

```markdown
<!-- ankiflow:topics -->

## Topics

- Wiggers diagram — low
- Preload vs afterload — medium
- Ejection fraction — mastered

<!-- /ankiflow:topics -->
```

Always sorted, least comfortable first. The `<!-- -->` lines are invisible anywhere the Markdown is rendered, and the notes editor never shows this block at all — it shows your writing and nothing else.

**Edit it anywhere.** Type `- Baroreflex` into the file by hand and it appears here rated Low, tidied into place a second later. Delete the last topic and the whole block goes; empty the file completely and the file goes too.

---

## Lecture questions

The pane between your cards and your notes, for the thing that didn't land while the lecturer was still talking. Write it down fast, tick it off once you can answer it.

Think of these as draft cards. They have everything a real card has — a question, an answer, slides on either side, tags — they just aren't in your question file yet, because they aren't finished.

Each row has a checkbox and a caret. Tick one when you can answer it — it stays in the list, struck through, with a tally at the top so you can see what's left. The caret opens the answer box, both slide rows and the tags. The slide rows work exactly as they do on a card: click one to aim ⌘T and ⌘E at it, click again to type page numbers.

Double-click a question to reword it; the ✕ on hover deletes it.

**Turning one into a card.** **Move *n* to Cards** at the top takes across every question that's ticked *and* has an answer — written words or an attached slide, either counts. A slide on the *question* side doesn't count as an answer. The arrow on a row does one at a time. Everything crosses over: question, answer, both slide rows, your tags, plus a `lecture-question` tag so you can always find the cards you wrote during a lecture. It leaves the questions list when it does, and ⌘Z puts it back.

**The list holds still while you work**, same as topics — ticking never reorders it, and the circular arrow sorts unanswered to the top when you ask. Unlike topics, the file keeps them in the order you asked them.

**Where it goes.** A second block in the same `.md`, under the topics, using ordinary task-list checkboxes — so VS Code and GitHub render real tick boxes, and you can tick one there:

```markdown
<!-- ankiflow:questions -->

## Lecture Questions

- [x] Why does a stiff ventricle raise filling pressure without raising volume?
  > Compliance is the slope of the diastolic P–V curve, so the same volume
  > sits higher up a steeper line.
  > Question slides: 11
  > Slides: 12, 14
  > Tags: high-yield, physiology
- [ ] Why is isovolumetric relaxation energy-dependent?

<!-- /ankiflow:questions -->
```

The answer is a blockquote under its question, which is exactly what the caret folds. Add `- [ ] Why…` by hand and it turns up here unanswered.

---

## Checking your cards before you export


Press **⌘P**. You see your cards the way they'll appear, drawn by the same code that builds the deck — and it opens on the card you were just working on, so checking the one you've written is one keystroke rather than a scroll.

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
│   ├── Lecture 04.ankiflow.json ← your questions for that lecture
│   └── Lecture 04 Notes.md      ← your notes, topics and lecture questions
```

**AnkiFlow writes nothing else into your folders.** Your questions sit next to the PDF they belong to as plain readable text, your notes next to that, and that is the whole of it. They're hidden in Finder by default (press ⇧⌘. to see them), and a lecture with no questions gets no file at all.

Everything the app needs for itself lives with the app: **settings and templates** in `~/Library/Application Support/AnkiFlow/`, and **rendered slide images** in `~/Library/Caches/AnkiFlow/`, where macOS can reclaim them when the disk gets tight and Time Machine knows to skip them. Clear the cache whenever you like — the next export just takes longer.

If you used an earlier version you'll have a `.ankiflow` folder sitting in your library. It's read once for your old settings and then never touched again; AnkiFlow says so when it notices, and you can delete it.

**Questions save automatically.** PDF markup and slide reordering are separate: while editing a PDF, click Save to write those changes into the PDF. ⌘⏎ finishes a question and folds it shut; ⌘Z undoes and ⇧⌘Z redoes.

**Undo covers the session you're in.** ⌘Z takes back the last thing you did in whatever you're working on — a card, a mark on a slide, a topic, a line of text. Closing AnkiFlow starts fresh: nothing from yesterday comes back tomorrow.

**Marks on a slide are the exception to autosave**, so they're the one thing you get asked about. Quit with unsaved marks and AnkiFlow offers to write them into the PDF, throw them away, or stay put.

**Renaming and moving lectures.** Do it inside AnkiFlow — **drag a lecture onto a folder** to move it, and right-click for Rename or Move to Trash — and your questions travel with the PDF. If you do move a PDF in Finder and leave its questions behind, AnkiFlow notices next time it scans the library and offers to put them back together, showing you which lecture it thinks they belong to and why.

![Recovering a question file](docs/images/Recovery.png)

**If you annotate your slides**, that's fine and expected — the app re-renders them for your next export. **If you add or delete a slide**, AnkiFlow notices that too, works out where each of your slides went by what it says, and asks you to confirm before renumbering your questions. Slides with no text on them are worked out from their neighbours, and it always asks about those.

**Flagging slides.** Click the bookmark in the edit bar to flag or unflag the current page. Flags are saved directly in the PDF, are not part of your question sidecar, and are hidden from exported card images. Use **View ▸ Show Flagged Pages Only** to limit the gallery and ⌘↓/⌘↑ navigation to flagged pages.

---

## Keyboard

Every one of these is a menu command, so they work while your cursor is in a text box.

| Key | |
|---|---|
| ⌘N | New question |
| Tab / ⇧Tab | Question field ⇄ answer field — the armed slide row follows |
| ⌘↓ ⌘↑ | Next / previous slide — **works while typing**; follows the flagged-pages filter |
| ⌘E | Extend the range to the slide you're on |
| ⌘T | Add or remove just this slide |
| ⌘R | Start a new range here |
| ⌥-drag | Crop a slide, or hide a region on an occlusion card |
| ⌘⏎ | Finish this question |
| ⌘⇧C | Hide the selected words on a cloze card |
| ⌘⌫ | Delete this question |
| ⌘B ⌘I ⌘U | Bold, italic, underline — PDF markup while editing, note text while writing one |
| ⌘Z / ⇧⌘Z | Undo / redo — your questions, your PDF marks while editing, or your typing inside a note |
| ⌘S | Save your marks into the PDF (while editing) |
| ⌘Y | Switch card kind |
| ⌘P | Preview your cards |
| ⌘D | Export |
| ⌘O | Open a different folder of lectures |
| ⌘F ⇧⌘F ⌥F ⌥⌘F | Find (Search local slides, library slides, local questions, library questions)|
| ⌘1 ⌘2 ⌘3 ⌘4 | Sidebar / slide gallery / flagged pages / notes |
| ⇧⌘X ⌘K | In a note: strikethrough, link |
| View ▸ Show Flagged Pages Only | Limit navigation and the gallery to bookmarked pages |
| ⌘? | This documentation, inside the app |

---

## Problems and ideas

**[Open an issue on GitHub](https://github.com/tasawwan/ankiflow/issues)** for either one:

- **Bug reports** — something crashed, exported wrong, or didn't do what this page says it does. Say what you did, what happened, and what you expected instead.
- **Feature requests** — a card type you want, a step that takes too many clicks, anything missing. These are genuinely welcome.

Both go in the same place, and it means other people with the same problem or the same idea can find it.

Your questions are safe whatever happens to the app: they're plain files next to your PDFs, and deleting or reinstalling AnkiFlow doesn't touch them.

---

MIT licence. © 2026 Tasawwar Rahman.
