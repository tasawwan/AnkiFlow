import SwiftUI

/// Help ▸ Documentation. Written to be read once, start to finish, in about
/// four minutes -- and then dipped back into for the keyboard table.
struct TutorialView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heading

                // Grouped only to stay under the ten-child limit a
                // ViewBuilder imposes. No effect on layout.
                Group {
                    section("The idea", """
                    You write big overview questions against a lecture — "explain the classical \
                    pathway, including the proteins involved" — and attach the slides that answer \
                    them. Export, and Anki shows you the question; the back is those slides, \
                    stacked so you scroll through and check yourself.

                    Everything in the app exists to make attaching a run of slides cost two \
                    keystrokes instead of twenty clicks.
                    """)

                    section("Getting started", """
                    1. File ▸ Open Library (⌘O), and pick the folder your lecture PDFs live in. \
                    Subfolders become deck levels in Anki, so the tree you already have is the \
                    deck structure you'll get.

                    2. Click a lecture in the sidebar. The PDF fills the middle; questions go on \
                    the right.

                    3. Press ⌘N. A question appears, already holding the page you're looking at.
                    """)

                    keyboardSection

                }

                // Grouped only to stay under the ten-child limit a
                // ViewBuilder imposes. No effect on layout.
                Group {
                    section("The four fields", """
                    Every card has the same four, always on screen and all of them optional: \
                    **question**, **question slides**, **answer**, **answer slides**.

                    Tab moves between the two text fields, and the slide row you are attaching to \
                    follows your cursor. In the question field, ⌘E and ⌘T fill the question slides; \
                    Tab to the answer and the same keys fill the answer slides. Nothing to click and \
                    no mode to remember.

                    Fill as few of them as you like. Most cards are a question and a run of slides, \
                    and that is a finished card.
                    """)

                    section("The core move", """
                    You're on slide 12, where the topic starts. Press ⌘N and type the question, \
                    then Tab to the answer. Now press ⌘↓ a few times to read forward to slide 18 \
                    — the PDF scrolls even though your cursor is still in the text box, which is \
                    the whole trick. When you get to 18, press ⌘E. The answer slides become 12–18.

                    ⌘⏎ commits the question you're on. ⌘N starts the next one, anchored where you \
                    are. Tab moves to the next field — question, written answer, tags — and ⇧Tab \
                    goes back.

                    That's it. Six presses of ⌘↓ you were going to make anyway, plus two keys.
                    """)

                    section("When slides aren't in a neat run", """
                    ⌘T adds or removes just the page you're on, for the strays.

                    ⌘R re-anchors — start a fresh range here instead of extending the old one.

                    You can also click the "Answer slides" row and type "12-18, 22" directly, if \
                    you already know the numbers.

                    Four searches, two axes. ⌘ searches slides, ⌥ searches your questions; adding \
                    ⇧ or ⌘ widens from this lecture to the whole library — ⌘F, ⇧⌘F, ⌥F, ⌥⌘F.
                    """)

                    section("The card types", """
                    **Basic** — your typed question on the front, the attached slides on the back.

                    **Slide2Slide** — slides are the question. Optional text on the front lets you \
                    ask something specific about them ("which step here is rate-limiting?"), then \
                    other slides answer it. Click either slide row to arm it; the armed row is the \
                    one ⌘E and ⌘T act on.

                    **Cloze** — a sentence with pieces blanked out. Type the line, select the part \
                    you want hidden, and press ⇧⌘C. Each blank becomes its own card with its own \
                    review history, so adding a third one next month doesn't disturb the two you \
                    have been studying. "Add to last card" hides your selection at the same time as \
                    the blank before it, for two things that only make sense together. Slides attach \
                    to the back, as explanation once you have answered.

                    **Templates** — a question shape you fill in. Write one when you notice you've \
                    typed the same shape three times. Settings ▸ Templates ▸ New Template (or New from \
                    Question), then select a phrase and press ⌘B to turn it into a blank. **Slides on** decides \
                    whether cards from this template carry their slides on the front, the back or \
                    both — "name this structure" wants the front, "explain this pathway" the back. Deleting a template turns \
                    its questions into Basic ones — templates are a typing aid, not a card format, \
                    so nothing is lost.

                    The tabs at the top of the panel pick the kind for the whole panel, and ⌘Y \
                    cycles through them. One kind on screen at a time, deliberately.
                    """)

                    section("Image occlusion", """
                    Choose **Occlusion** in the tabs at the top of the panel, go to the slide, then hold ⌥ \
                    and drag over anything you want hidden. Each region is listed in the panel and \
                    filled in on the page, so you can see what the card will look like.

                    **All at once** makes one card: everything hidden on the front; on the back \
                    everything is visible, with each region you covered boxed in amber, so you \
                    can see which parts you were meant to have recalled.

                    **One at a time** makes one card per region. The front hides everything, \
                    with the region that card is asking about marked in amber; the back shows \
                    everything, with that same region boxed in amber. The panel tells you how many \
                    cards you are about to make.

                    The masks are painted into the picture here rather than described to Anki, so \
                    these are ordinary cards that work everywhere Anki does and need no add-on. \
                    The trade is that you edit the regions here, not in Anki. Each region keeps its \
                    own review history; delete one and the export sheet tells you which card was \
                    left behind, just as it does for a deleted question.
                    """)

                    section("Cropping a slide", """
                    Hold ⌥ and drag on the page to keep just part of a slide — one figure out of \
                    a busy layout. Everything outside the rectangle dims while you drag; let go \
                    and it's set. ⌘U undoes it while it is still the last thing you did; after that, the crop badge on the slide row lists every cropped slide so you can remove any one of them.

                    The crop belongs to whichever slide row is armed, so the same page can be \
                    cropped one way on a card's front and another on its back. Cropped slides are \
                    outlined on the page and counted on the row.

                    **Cropping never touches your PDF.** The crop is four numbers in the lecture's \
                    question file, stored as fractions of the page rather than points — so it \
                    stays correct if you keep annotating the PDF in another app. The one place \
                    AnkiFlow does write to your PDF is the PDF menu, and it says so on screen \
                    while you are in it.
                    """)

                    section("Editing the PDF itself", """
                    Everything else in this app leaves your lecture file alone. This does not — it \
                    is the one place AnkiFlow writes to the PDF, which is why it announces \
                    itself while you are in it. **Edit PDF** at the top of the slide pane turns \
                    it on — the button becomes a row of tools laid out like Preview's markup bar \
                    — and Esc puts it away.

                    **Nothing is written until you say so.** Marks appear as you make them and \
                    live in memory until you press ⌘S, or the Save button that turns up the \
                    moment there is something to save. ⌘U takes back the last mark and ⇧⌘U puts \
                    it back, the same keys as everywhere else. Leaving with unsaved marks asks first.

                    Select text and click Highlight, Underline or Strikethrough. For anything that \
                    is not text, pick a tool and drag: Sketch draws freehand, Shapes gives you a \
                    rectangle, oval, line or arrow, and Text drags out a box you type straight \
                    into on the page. The Select tool picks a mark back up — drag to move it, drag \
                    a corner to resize, ⌫ to delete, double-click a text box to retype it, \
                    including one you saved weeks ago. The swatch beside them holds the stroke \
                    colour, the fill, the thickness and the text size.

                    These are real PDF annotations, so they show up in Preview or GoodNotes too — \
                    and because they are part of the page, they appear on every card that uses \
                    that slide.

                    Rotate, move, insert and delete slides are behind the pages button in that \
                    bar, and in the PDF menu. Those write straight away rather than waiting for \
                    ⌘S, because they renumber your questions too — and when slides move, your \
                    questions move with them: the app made the change, so it knows exactly what \
                    shifted and renumbers them without asking. Deleting a slide is the only action \
                    here that asks first — everything else you can undo by doing the opposite, and a \
                    deleted page is gone from the file.

                    Trim cuts a slide down to a rectangle you drag, and **Trim Every Slide Like \
                    This One** applies the same margins to the whole lecture. Trimming moves the page's \
                    edges, so crops and masks you already have on those slides are re-measured \
                    against the new ones and keep pointing at the same part of the picture.
                    """)

                }

                // Grouped only to stay under the ten-child limit a
                // ViewBuilder imposes. No effect on layout.
                Group {
                    section("Finding a slide", """
                    ⌘F searches the lecture you have open and jumps to the hit. ⌘G goes to the \
                    next one, and it wraps around. ⎋ closes the bar.

                    It searches the slides, not your questions — because looking for the slide \
                    that mentions a term is what you do while writing a question about it.
                    """)

                    section("Tags", """
                    Checkboxes at the bottom of each question box. Whatever you tick becomes a real \
                    Anki tag, so you can build filtered decks from "high-yield" later.

                    Settings ▸ Tags is where you choose which tags get a permanent checkbox and in \
                    what order. Anything else lives behind the tag button.

                    Every card also gets a tag mirroring its folder path automatically.
                    """)

                    section("Looking at your cards first", """
                    ⌘P shows your cards the way they will appear, drawn by the same code that \
                    builds the deck. A crop that clipped a label, a mask over the wrong structure, \
                    a range that took 12–18 when you meant 12–8 — all obvious here, all invisible \
                    in the panel, and otherwise found in Anki days later.

                    Press **E** on any card to jump to that question and fix it.

                    Two ways through: **flashcards**, where Space reveals the answer and then \
                    moves on, or **continuous** — one long scroll of question, slides, a rule, then \
                    the answer and its slides.

                    Nothing is graded and nothing is saved. Anki does the spaced repetition; two \
                    review histories would be worse than one.
                    """)

                    section("Exporting, and re-exporting", """
                    ⌘D exports. Pick a scope, save the .apkg, open it in Anki.

                    The important part is the second time. Re-export after adding questions and \
                    Anki **updates your existing cards without touching your review history** — \
                    same intervals, same due dates, same ease. Only genuinely changed questions are \
                    rewritten, and the export sheet tells you how many.

                    **Send them straight to Anki if you can.** In the export window choose \
                    "Straight into Anki" and your cards appear in Anki with no file to save, no \
                    import screen and no settings to get wrong. It needs a free add-on, once: in \
                    Anki, Tools ▸ Add-ons ▸ Get Add-ons, paste the code 2055492159, and restart \
                    Anki. Leave Anki running when you export.

                    If you'd rather have a file: in Anki's import dialog leave "Update notes" on \
                    *If newer* and tick *Merge notetypes*. The export window reminds you.
                    """)

                    section("Two things Anki won't do", """
                    **Cards never change deck.** Reorganise your folders and existing cards stay \
                    where they first landed. Every note carries a tag for its path, and the export \
                    sheet gives you a search to paste into Anki's browser so you can select them \
                    and Change Deck.

                    **Deleting a question doesn't delete its card.** The export sheet gives you a \
                    search for exactly those, so you can remove them deliberately.

                    Neither is a bug here — it's how package import works — so the app reports both \
                    rather than hiding them.
                    """)

                    section("Where your work lives", """
                    Nothing is hidden in a database. Each lecture's questions sit right next to its \
                    PDF as a readable JSON file, and a lecture with no questions gets no file at all.

                    The app autosaves — there's no save dialog and no unsaved state. ⌘⏎ finishes \
                    a question and folds it shut; ⌘U undoes and ⇧⌘U redoes, and that history \
                    survives quitting. Question files are hidden in Finder by default; ⇧⌘. shows \
                    them.

                    **Rename and move lectures from the sidebar**, not in Finder — drag a lecture \
                    onto a folder to move it, and right-click for Rename or Move to Trash — ⌘U puts a trashed lecture back. Done here, your \
                    questions travel with the PDF. Done in Finder they get left behind, and the app \
                    has to notice and offer to put them back.

                    Because the files are plain text, `git init` in your lecture folder gives you \
                    real version history for free.

                    Every card also carries the text of the slides it cites, in a field the card \
                    doesn't display. Anki searches hidden fields too, so you can find a card by \
                    what was written on the slide, not just by what you typed.
                    """)

                    section("Keeping AnkiFlow up to date", """
                    AnkiFlow ▸ Check for Updates asks GitHub whether a newer release exists. It \
                    also asks quietly on its own, at most once a day.

                    If there is one, choose **Update from Source**. The command that pulls and \
                    rebuilds is copied to your clipboard and Terminal opens in your AnkiFlow \
                    folder — paste it, press Return, and the app quits and reopens itself when \
                    the rebuild finishes.

                    It hands you the command instead of running it on purpose. That command \
                    downloads code from the internet and compiles it, and you should be able to \
                    read it before it runs.

                    Two things worth knowing. **Pulling alone changes nothing** — the installed \
                    app holds a copy of the compiled code, so new source on disk does nothing \
                    until it is rebuilt. And **your questions are never at risk**: they live \
                    beside your PDFs, not inside the app, so replacing or even deleting AnkiFlow \
                    leaves everything you have written exactly where it is.
                    """)

                }

                Text("© 2026 Tasawwar Rahman")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
            .padding(34)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(width: 720, height: 640)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                AppIconMark().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AnkiFlow")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Documentation")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            Divider().padding(.top, 6)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(markdown(body))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary.opacity(0.88))
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The keyboard")
                .font(.system(size: 16, weight: .semibold))
            Text("Every one of these is a menu command, so it works while your cursor is in a text box. You should never have to leave the question you're typing to attach the slide you're looking at.")
                .font(.system(size: 13.5))
                .foregroundStyle(.primary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(Shortcuts.all.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 14) {
                        Text(row.key)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 62, alignment: .leading)
                        Text(row.what)
                            .font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    .background(index.isMultiple(of: 2)
                                ? Color.secondary.opacity(0.06) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

/// One list of shortcuts, used by the tutorial and by Settings ▸ Keyboard, so
/// the two can't drift apart.
enum Shortcuts {
    static let all: [(key: String, what: String)] = [
        ("⌘N",  "New question, holding the page you're on"),
        ("Tab  ⇧Tab", "Question field ⇄ answer field — the armed row follows"),
        ("⌘↓ ⌘↑", "Next / previous page — works while typing"),
        ("⌘E",  "Extend: anchor → the page you're on"),
        ("⌘T",  "Toggle this page in or out"),
        ("⌘R",  "Re-anchor: start a new range here"),
        ("⌥-drag", "Crop the slide you're pointing at"),
        ("⌘U  ⇧⌘U", "Undo and redo — questions, or PDF marks while editing"),
        ("⌘S",  "Save your marks into the PDF (while editing)"),
        ("⌘F ⌘G", "Find slides in this lecture, and the next hit"),
        ("⇧⌘F", "Find slides across the library"),
        ("⌥F  ⌥⌘F", "Find questions — this lecture, or the library"),
        ("⇧⌘C", "Hide the selected words on a cloze card"),
        ("⌘⏎",  "Commit this question"),
        ("⌘⌫",  "Delete this question"),
        ("⌘Y",  "Switch card kind"),
        ("⌘P",  "Preview your cards"),
        ("⌘D",  "Export deck"),
        ("⌘O",  "Open library"),
        ("⌘1 ⌘2", "Sidebar / slide gallery"),
        ("⌘,",  "Settings")
    ]
}
