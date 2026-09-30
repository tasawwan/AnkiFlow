import SwiftUI
import AppKit

/// The notes editor at the foot of the right-hand panel.
///
/// A real `NSTextView` rather than SwiftUI's `TextEditor`, because the whole
/// point is formatting: SwiftUI has no way to bold a selection, change its
/// colour or attach a link. Everything the toolbar does is an ordinary AppKit
/// text-view command applied to the current selection, so selection behaviour,
/// undo and the system font and colour panels all work the way they do in any
/// Mac text field, for free.
struct NotesPane: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    @ObservedObject var notes: LectureNotes

    /// Rebuilt whenever the selection moves, so the toolbar can light up the
    /// buttons that apply to what is selected.
    @State private var active: Set<NotesFormat> = []
    @State private var showingLinkSheet = false
    @State private var linkText = ""
    /// 0 for body text, 1–3 for a heading, so the toolbar can say which.
    @State private var headingLevel = 0
    /// Survives quitting, because a size you have to set every morning is a size
    /// you stop using.
    @AppStorage("notesTextSize") private var textSize: Double = 17

    var body: some View {
        // The note is a card, like the questions above it -- same surface, same
        // border, same radius. It was the only thing in this panel that wasn't,
        // which is what made the pane read as chrome stuck to the bottom rather
        // than as one more object in the list. It fills whatever height the
        // divider gives it.
        VStack(alignment: .leading, spacing: 7) {
            header
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(palette.lineSoft).frame(height: 1)
                    }
                NotesEditor(notes: notes, active: $active, headingLevel: $headingLevel,
                            palette: palette,
                            onLink: { showingLinkSheet = true; linkText = "https://" },
                            currentPage: { state.currentPage },
                            pageCount: { state.pageCount },
                            onGoToPage: { state.currentPage = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
        .sheet(isPresented: $showingLinkSheet) {
            LinkSheet(url: $linkText) { url in
                NotesCommand.link(url).run()
                showingLinkSheet = false
            }
            .environment(\.palette, palette)
        }
        // ⌘+ / ⌘− / ⌘0 from the View menu. A menu item cannot rebuild the
        // styled text itself -- only this pane knows how to put the caret back
        // afterwards -- so it raises a tick and this answers it.
        .onChange(of: state.textSizeTick) {
            apply(state.pendingTextSizeChange)
        }
    }

    /// One quiet line above the card: what this is, which file it is, and
    /// whether it has been written.
    private var header: some View {
        HStack(spacing: 8) {
            Text("LECTURE NOTES")
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            // The filename gives way to whatever just happened to the file.
            // Something changing your notes from outside the app is worth a
            // sentence, and this is the line already looking at that file.
            if let change = notes.externalChange {
                Text(change)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.amber)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(change)
            } else {
                Text(notes.fileURL.finderName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.dim.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            savedMark
        }
    }

    // MARK: - Formatting

    /// Exactly what the `.md` can hold, and nothing else.
    ///
    /// No colour well and no font panel: Markdown has no way to record either,
    /// so those buttons would have styled the text on screen and lost it on
    /// save. Bigger text is a heading, which is the answer the format already
    /// has.
    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 4) {
            Group {
                formatButton(.bold, "bold")
                formatButton(.italic, "italic")
                formatButton(.underline, "underline")
                formatButton(.strikethrough, "strikethrough")
                divider
            }
            Group {
                headingMenu
                command("list.bullet", "Bullet list", .bulletList)
                divider
                command("link", "Add a link (⌘K)") { showingLinkSheet = true; linkText = "https://" }
                command("chevron.up.chevron.down",
                        "Fold or unfold every section (⌥⌘← and ⌥⌘→)") {
                    NotesFocus.shared.view?.toggleAllFolds()
                }
            }
            Spacer(minLength: 0)
            // Display only. Markdown cannot record a point size, so this changes
            // how the notes are drawn and never what is saved -- which is why it
            // sits apart from the formatting buttons rather than among them.
            Group {
                button("textformat.size.smaller", "Smaller text", on: false) { resize(by: -1) }
                    .disabled(textSize <= Double(RichTextMarkdown.sizeRange.lowerBound))
                button("textformat.size.larger", "Bigger text", on: false) { resize(by: 1) }
                    .disabled(textSize >= Double(RichTextMarkdown.sizeRange.upperBound))
            }
        }
    }

    /// Re-rendered from the Markdown rather than by scaling the fonts already in
    /// the text storage.
    ///
    /// Heading levels are recognised on the way back out by how much bigger a
    /// line is than body text, and those comparisons are fixed differences
    /// rather than ratios. Multiply every font by 0.9 to shrink the note and an
    /// H3 that was 2pt bigger than body ends up 1.8pt bigger, under the
    /// threshold -- so it would be written to the file as an ordinary
    /// paragraph, and the heading would be gone. Rebuilding from the Markdown
    /// produces exactly the right sizes for the new base instead.
    ///
    /// The rebuild replaces the whole text storage, which would put the caret
    /// back at the top; the character offsets are unchanged by it, so the
    /// selection is simply put back where it was.
    private func resize(by step: Double) { resize(to: textSize + step) }

    /// The size ⌘0 goes back to. Matches the `@AppStorage` default above.
    static let defaultTextSize: Double = 17

    /// ⌘+ / ⌘− from the View menu land here. The buttons in the toolbar do the
    /// same thing -- one path, so the two cannot drift.
    private func apply(_ change: AppState.TextSizeChange) {
        switch change {
        case .bigger:  resize(by: 1)
        case .smaller: resize(by: -1)
        case .reset:   resize(to: Self.defaultTextSize)
        }
    }

    private func resize(to size: Double) {
        let wanted = min(max(size, Double(RichTextMarkdown.sizeRange.lowerBound)),
                         Double(RichTextMarkdown.sizeRange.upperBound))
        let old = RichTextMarkdown.baseSize
        guard CGFloat(wanted) != old else { return }
        let caret = NotesFocus.shared.view?.selectedRange()
        RichTextMarkdown.baseSize = CGFloat(wanted)
        textSize = wanted
        notes.replaceText(RichTextMarkdown.rescaled(notes.text, from: old))
        guard let caret else { return }
        // After the editor has taken the new text, not before.
        DispatchQueue.main.async {
            guard let view = NotesFocus.shared.view else { return }
            let end = (view.string as NSString).length
            let start = min(caret.location, end)
            view.setSelectedRange(NSRange(location: start,
                                          length: min(caret.length, end - start)))
            view.scrollRangeToVisible(view.selectedRange())
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.line).frame(width: 1, height: 14).padding(.horizontal, 2)
    }

    private func formatButton(_ format: NotesFormat, _ symbol: String) -> some View {
        button(symbol, format.label, on: active.contains(format)) {
            NotesCommand.toggle(format).run()
        }
    }

    private func command(_ symbol: String, _ label: String, _ command: NotesCommand) -> some View {
        button(symbol, label, on: false) { command.run() }
    }

    private func command(_ symbol: String, _ label: String,
                         _ action: @escaping () -> Void) -> some View {
        button(symbol, label, on: false, action: action)
    }

    private func button(_ symbol: String, _ label: String, on: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5))
                .frame(width: 22, height: 19)
                .foregroundStyle(on ? palette.ink : palette.dim)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(on ? palette.field : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// The heading picker, showing the level the caret is in.
    ///
    /// A menu rather than three buttons: H1, H2, H3 and Body are one choice with
    /// four answers, not four independent switches, and a control that reads
    /// back the current level tells you where you are as well as what you can do.
    private var headingMenu: some View {
        Menu {
            Button("Heading 1") { NotesCommand.heading(1).run() }
            Button("Heading 2") { NotesCommand.heading(2).run() }
            Button("Heading 3") { NotesCommand.heading(3).run() }
            Divider()
            Button("Body") { NotesCommand.heading(0).run() }
        } label: {
            HStack(spacing: 2) {
                Text(headingLevel == 0 ? "Body" : "H\(headingLevel)")
                    .font(.system(size: 11, weight: headingLevel == 0 ? .regular : .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(headingLevel == 0 ? palette.dim : palette.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 19)
        .help("Heading level")
    }

    @ViewBuilder
    private var savedMark: some View {
        if notes.externalChange != nil {
            Button("Dismiss") { notes.externalChange = nil }
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.dim)
        } else if notes.loadError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.retired)
                .help(notes.loadError ?? "")
        } else if notes.lastSavedAt != nil {
            Text("saved")
                .font(.system(size: 9.5))
                .foregroundStyle(palette.dim.opacity(0.7))
        }
    }
}

/// The inline styles the toolbar can turn on and off.
enum NotesFormat: Hashable {
    case bold, italic, underline, strikethrough

    var label: String {
        switch self {
        case .bold:          return "Bold (⌘B)"
        case .italic:        return "Italic (⌘I)"
        case .underline:     return "Underline (⌘U)"
        case .strikethrough: return "Strikethrough (⇧⌘X)"
        }
    }
}

/// The note editor the toolbar acts on.
///
/// The toolbar used to find it through `NSApp.keyWindow?.firstResponder`, which
/// is how AppKit text commands normally work and which did not work here:
/// clicking a SwiftUI button can move first responder before the action runs, so
/// the cast failed and the button did nothing at all. Holding the view directly
/// removes the question.
@MainActor
final class NotesFocus {
    static let shared = NotesFocus()
    weak var view: NotesTextView?
    private init() {}
}

/// One thing the toolbar can do to the note that currently has focus.
///
/// Routed through the first responder rather than held as state, which is how
/// AppKit text editing works and why the system font and colour panels apply to
/// the selection with no wiring of their own.
enum NotesCommand {
    case toggle(NotesFormat)
    case heading(Int)
    case bulletList
    case link(String)

    /// Turn one inline style on or off.
    ///
    /// The two cases matter equally. With text selected it restyles that text;
    /// with only a caret it changes the *typing attributes*, so the next thing
    /// you type comes out in that style. Only handling the first is the mistake
    /// that makes an editor feel broken -- you press Bold, nothing happens, and
    /// you learn to type the words first and go back and select them, which is
    /// not how any other editor works.
    /// The editor to act on: the one this pane owns, or whatever text view holds
    /// focus if that is somehow not set.
    @MainActor
    private var target: NSTextView? {
        if let view = NotesFocus.shared.view, view.isEditable { return view }
        let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        return responder?.isEditable == true ? responder : nil
    }

    @MainActor
    private func restyle(_ view: NSTextView, format: NotesFormat) {
        let range = view.selectedRange()

        /// Whether the style is on where the caret is, so the button toggles.
        func isOn(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            switch format {
            case .bold, .italic:
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                return traits.contains(format == .bold ? .bold : .italic)
            case .underline:
                return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strikethrough:
                return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        }

        func apply(_ attributes: [NSAttributedString.Key: Any],
                   on: Bool) -> [NSAttributedString.Key: Any] {
            var out = attributes
            switch format {
            case .bold, .italic:
                let trait: NSFontDescriptor.SymbolicTraits = format == .bold ? .bold : .italic
                let font = (attributes[.font] as? NSFont) ?? RichTextMarkdown.baseFont
                var traits = font.fontDescriptor.symbolicTraits
                if on { traits.insert(trait) } else { traits.remove(trait) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                out[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            case .underline:
                out[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            case .strikethrough:
                out[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : 0
            }
            return out
        }

        guard range.length > 0, let storage = view.textStorage else {
            // Just a caret: style what comes next.
            let wanted = !isOn(view.typingAttributes)
            view.typingAttributes = apply(view.typingAttributes, on: wanted)
            return
        }

        // Turning it on unless the whole selection already has it, which is what
        // makes a mixed selection go fully bold on the first press rather than
        // half-toggling.
        var everywhere = true
        storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if !isOn(attributes) { everywhere = false; stop.pointee = true }
        }
        let wanted = !everywhere

        storage.beginEditing()
        storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            storage.setAttributes(apply(attributes, on: wanted), range: subrange)
        }
        storage.endEditing()
        view.didChangeText()
        // So the next character typed at the end of the selection continues in
        // the style you just applied.
        view.typingAttributes = apply(view.typingAttributes, on: wanted)
    }

    @MainActor
    func run() {
        guard let view = target else { return }
        // The caret goes back into the note afterwards, so you can keep typing
        // in the style you just chose instead of clicking back into the text.
        defer { view.window?.makeFirstResponder(view) }
        let range = view.selectedRange()
        let storage = view.textStorage

        switch self {
        case .toggle(let format):
            restyle(view, format: format)

        case .heading(let level):
            guard let storage else { return }
            let paragraph = (view.string as NSString).paragraphRange(for: range)
            let size = RichTextMarkdown.headingSize(level)
            let font = level == 0
                ? NSFont.systemFont(ofSize: RichTextMarkdown.baseSize)
                : NSFont.boldSystemFont(ofSize: size)
            storage.addAttribute(.font, value: font, range: paragraph)
            view.didChangeText()

        case .bulletList:
            guard let storage else { return }
            let text = view.string as NSString
            // Every paragraph the selection touches, not just the one the caret
            // is in. Selecting six lines and pressing the button obviously means
            // all six; doing one was the bug.
            let span = text.paragraphRange(for: range)

            // Each line's own range, collected before anything is edited: the
            // edits change every offset after them, so walking and editing in
            // one pass works from stale numbers.
            var lines: [NSRange] = []
            var cursor = span.location
            while cursor < NSMaxRange(span) {
                let line = text.paragraphRange(for: NSRange(location: cursor, length: 0))
                lines.append(line)
                cursor = NSMaxRange(line)
                if line.length == 0 { break }
            }
            guard !lines.isEmpty else { return }

            // One decision for the whole selection rather than per line, so a
            // mixed block becomes all-bulleted on the first press and plain on
            // the second, instead of inverting into a different mess each time.
            let bulleted = lines.allSatisfy { line in
                let content = text.substring(with: line)
                return content.hasPrefix("• ") || content.trimmingCharacters(in: .whitespaces).isEmpty
            }

            storage.beginEditing()
            // Back to front: editing the last line first leaves the earlier
            // ranges still valid.
            for line in lines.reversed() {
                let content = text.substring(with: line)
                if bulleted {
                    guard content.hasPrefix("• ") else { continue }
                    storage.replaceCharacters(
                        in: NSRange(location: line.location, length: 2), with: "")
                } else {
                    guard !content.trimmingCharacters(in: .whitespaces).isEmpty,
                          !content.hasPrefix("• ") else { continue }
                    storage.replaceCharacters(
                        in: NSRange(location: line.location, length: 0), with: "• ")
                }
            }
            storage.endEditing()
            view.didChangeText()

        case .link(let url):
            guard range.length > 0, let storage, !url.isEmpty else { return }
            storage.addAttributes([
                .link: URL(string: url) ?? url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.linkColor
            ], range: range)
            view.didChangeText()
        }
    }
}

/// Where a link points.
struct LinkSheet: View {
    @Environment(\.palette) private var palette
    @Binding var url: String
    let apply: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link the selected text")
                .font(.title3.weight(.semibold))
            TextField("https://…", text: $url)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            HStack {
                Button("Cancel") { apply("") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Link") { apply(url) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390)
    }
}

/// A text view that owns its formatting keys.
///
/// The shortcuts live here rather than on menu items so that they mean bold and
/// underline *inside a note* and nothing anywhere else -- ⌘B is PDF markup while
/// the markup bar is up, and ⌘U is nothing at all otherwise. AppKit offers a
/// view the key equivalent before the main menu does, which is what makes that
/// possible, and it is how these keys behave in every other editor on the
/// machine.
///
/// ⌘Z is claimed too, so that undo inside a note undoes typing rather than the
/// last thing you did to your questions.
/// The fold triangles, in a view of their own.
///
/// A subview rather than something the text view paints for itself. Subviews are
/// drawn after their parent and hit-tested before it, so the triangles are
/// reliably on top and reliably clickable without anyone having to reason about
/// how a text view treats its own margins -- which is where two attempts at
/// drawing these inside `NSTextView.draw` went wrong.
///
/// `hitTest` hands back every click that is not on a triangle, so selecting and
/// typing are untouched.
final class FoldRibbon: NSView {
    weak var owner: NotesTextView?

    /// Flipped to match the text view. Without this every triangle would be
    /// measured from the wrong edge and land off the bottom of a long note.
    override var isFlipped: Bool { true }

    private func spot(near y: CGFloat) -> NotesTextView.FoldSpot? {
        owner?.foldSpots().first { abs($0.midY - y) <= 10 }
    }

    /// How far in from the right edge the triangles have to sit.
    ///
    /// An overlay scroller floats over the content rather than beside it, and it
    /// fades in as the pointer approaches the right edge -- which is exactly the
    /// journey you make to reach a triangle, so it was arriving first and taking
    /// the click. Stepping in by its width puts the triangles beside it instead
    /// of under it. A legacy scroller sits outside the document view entirely
    /// and needs no allowance.
    private var scrollerAllowance: CGFloat {
        guard owner?.enclosingScrollView?.scrollerStyle == .overlay else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    }

    private var column: CGFloat {
        bounds.width - scrollerAllowance - NotesTextView.gutter / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let strip = bounds.width - scrollerAllowance
        guard local.x >= strip - NotesTextView.gutter, local.x <= strip,
              spot(near: local.y) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let target = spot(near: local.y) else { return }
        owner?.toggleFold(atIndex: target.index)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let x = column
        for spot in owner.foldSpots() {
            triangle(open: spot.open, at: NSPoint(x: x, y: spot.midY))
        }
    }

    private func triangle(open: Bool, at centre: NSPoint) {
        let width: CGFloat = 8, height: CGFloat = 5
        let path = NSBezierPath()
        if open {
            path.move(to: NSPoint(x: centre.x - width / 2, y: centre.y - height / 2))
            path.line(to: NSPoint(x: centre.x + width / 2, y: centre.y - height / 2))
            path.line(to: NSPoint(x: centre.x, y: centre.y + height / 2))
        } else {
            path.move(to: NSPoint(x: centre.x - width / 2, y: centre.y + height / 2))
            path.line(to: NSPoint(x: centre.x + width / 2, y: centre.y + height / 2))
            path.line(to: NSPoint(x: centre.x, y: centre.y - height / 2))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
    }
}

extension NSAttributedString.Key {
    /// Marks characters the folding layout manager should draw as nothing.
    /// Display only -- it is never read on the way to the file.
    static let notesFolded = NSAttributedString.Key("ankiflow.notesFolded")
}

/// Hides text without removing it.
///
/// A text view has no notion of folding, and the only place to say "these
/// characters are not to be drawn" is here: a glyph marked `.null` produces no
/// ink and takes no space, and nulling a run including its newlines collapses
/// those lines away entirely. The characters stay in the storage throughout, so
/// what gets written to the file is exactly what it would have been.
final class FoldingLayoutManager: NSLayoutManager {
    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes: UnsafePointer<Int>,
                            font: NSFont,
                            forGlyphRange glyphRange: NSRange) {
        guard let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes,
                            font: font, forGlyphRange: glyphRange)
            return
        }
        var adjusted = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var hidAny = false
        for offset in 0..<glyphRange.length {
            let character = characterIndexes[offset]
            guard character < storage.length,
                  storage.attribute(.notesFolded, at: character, effectiveRange: nil) != nil
            else { continue }
            adjusted[offset].insert(.null)
            hidAny = true
        }
        guard hidAny else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes,
                            font: font, forGlyphRange: glyphRange)
            return
        }
        adjusted.withUnsafeBufferPointer { buffer in
            super.setGlyphs(glyphs, properties: buffer.baseAddress!,
                            characterIndexes: characterIndexes,
                            font: font, forGlyphRange: glyphRange)
        }
    }
}

final class NotesTextView: NSTextView {
    var onLink: (() -> Void)?
    /// Which slide the pane beside this one is showing, for ⌘T. A closure
    /// rather than a stored number because the answer changes as you scroll and
    /// the text view is not rebuilt when it does.
    var currentPage: (() -> Int)?
    /// How many slides the lecture has, so a reference to one it does not have
    /// is left as ordinary words.
    var pageCount: (() -> Int)?
    /// Go to a slide. Raised rather than done here: the pane does not own the
    /// PDF, it only writes about it.
    var onGoToPage: ((Int) -> Void)?
    /// The note's own ink, for text arriving from somewhere else.
    var inkColour: NSColor = .textColor
    /// What a slide reference is drawn in.
    var referenceColour: NSColor = .linkColor
    /// The ranges currently drawn as references, so the next pass can take its
    /// own underline back off without touching the spell checker's.
    private var markedReferences: [NSRange] = []
    /// Held because the manual text stack has nothing else keeping it alive.
    var backingStorage: NSTextStorage?
    /// The strip of disclosure triangles laid over the right-hand margin.
    weak var ribbon: FoldRibbon?

    /// The ribbon is sized by hand rather than by an autoresizing mask: the text
    /// view starts at zero and grows, and a mask resizing from nothing does not
    /// reliably end up matching.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        ribbon?.frame = bounds
        ribbon?.needsDisplay = true
    }

    /// Parent paragraphs whose children are folded away.
    ///
    /// Indices rather than ranges: an edit anywhere above a fold moves every
    /// character range below it, while the index survives as long as the shape
    /// of the list does. Not written anywhere -- folding is how you are reading
    /// the note right now, not a property of the note.
    private var folded: Set<Int> = []
    private var applyingFolds = false
    /// The margin the disclosure triangles live in. On the right, out of the
    /// way of the words and of the indentation that shows the nesting -- a
    /// triangle on the left would sit where the deeper bullets are trying to
    /// step in from. The inset is symmetric because AppKit has no way to ask for
    /// a wider margin on one side, so the left gets the same room and simply
    /// does not use it.
    static let gutter: CGFloat = 18

    private func listMarker(in line: String) -> (level: Int, length: Int)? {
        guard let match = line.range(of: #"^([ \t]*)(?:•|[-*+]) "#, options: .regularExpression) else {
            return nil
        }
        let prefix = line[..<match.upperBound]
        let indentation = prefix.dropLast(2)
        let spaces = indentation.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        return (spaces / 4, prefix.count)
    }

    /// "Page 12", "Slide 12", "page #12" -- however you happened to write it.
    ///
    /// Not stored anywhere and never written to the file: the Markdown says
    /// `(Page 12)` in plain words, and this is only how AnkiFlow chooses to draw
    /// it. Open the same note in any other editor and it is a sentence.
    private static let pageReference = try? NSRegularExpression(
        pattern: "\\b(?:page|slide)s?\\.?\\s*#?\\s*(\\d{1,4})\\b",
        options: [.caseInsensitive])

    /// Every reference in the note that points at a slide this lecture has.
    func pageReferences() -> [(range: NSRange, page: Int)] {
        guard let regex = Self.pageReference, let total = pageCount?(), total > 0 else { return [] }
        let source = string as NSString
        var found: [(range: NSRange, page: Int)] = []
        regex.enumerateMatches(in: string,
                               range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let page = Int(source.substring(with: match.range(at: 1))),
                  page >= 1, page <= total else { return }
            found.append((match.range, page))
        }
        return found
    }

    /// Draws the references, through the layout manager rather than the text.
    ///
    /// Temporary attributes exist for exactly this: something the reader should
    /// see that the document does not contain. Writing the colour into the text
    /// storage would put it in `text`, and from there into the file, where the
    /// format has no way to say it.
    func markPageReferences() {
        guard let layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        // Colour can go in one sweep -- nothing else uses a temporary one. The
        // underline cannot: that is also how spell checking draws, so only the
        // ranges this method put one on are cleared.
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for stale in markedReferences {
            let clamped = NSIntersectionRange(stale, whole)
            guard clamped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: clamped)
        }
        markedReferences = pageReferences().map { $0.range }
        for range in markedReferences {
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: referenceColour,
                 .underlineStyle: NSUnderlineStyle.single.rawValue],
                forCharacterRange: range)
        }
        window?.invalidateCursorRects(for: self)
    }

    /// The slide named under the pointer, if the pointer is on one.
    private func pageReference(at point: NSPoint) -> Int? {
        guard !string.isEmpty, let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        // `glyphIndex` answers with the nearest glyph even for a click out in
        // the margin past the end of a line, so the glyph's own box is checked
        // too -- otherwise clicking anywhere right of "(Page 12)" jumped.
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                             in: textContainer)
        guard box.contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return pageReferences().first { NSLocationInRange(index, $0.range) }?.page
    }

    override func mouseDown(with event: NSEvent) {
        // Before `super`, which opens a tracking loop that does not return until
        // you let go. Going to the slide does not take the keyboard, so the
        // click still places the caret exactly as it would anywhere else.
        if let page = pageReference(at: convert(event.locationInWindow, from: nil)) {
            onGoToPage?(page)
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let none = NSRange(location: NSNotFound, length: 0)
        for reference in pageReferences() {
            let glyphs = layoutManager.glyphRange(forCharacterRange: reference.range,
                                                  actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                  withinSelectedGlyphRange: none,
                                                  in: textContainer) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y),
                                   cursor: .pointingHand)
            }
        }
    }

    /// Everything arriving from outside is rewritten in the editor's own terms.
    ///
    /// Left to itself an `NSTextView` takes a paste whole -- the source's fonts,
    /// its colours, its shading, its point sizes -- and none of that can be
    /// written to a `.md`. The result was a note that looked one way on screen
    /// and saved as something plainer, which you only found out about later. The
    /// conversion happens here instead, where you can see it and undo it.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        var incoming: NSAttributedString?
        if let data = board.data(forType: .rtf) {
            incoming = NSAttributedString(rtf: data, documentAttributes: nil)
        } else if let data = board.data(forType: .rtfd) {
            incoming = NSAttributedString(rtfd: data, documentAttributes: nil)
        } else if let data = board.data(forType: .html) {
            incoming = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        } else if let plain = board.string(forType: .string) {
            // Plain text needs no conversion: it picks up whatever the caret is
            // already typing in, which is what pasting into a heading should do.
            insertText(plain, replacementRange: selectedRange())
            return
        }
        guard let incoming, incoming.length > 0 else { super.paste(sender); return }
        let cleaned = RichTextMarkdown.normalised(incoming, textColour: inkColour)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: cleaned.string) else { return }
        textStorage?.replaceCharacters(in: range, with: cleaned)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + cleaned.length, length: 0))
    }

    private func marker(for level: Int) -> String {
        String(repeating: " ", count: level * 4) + (level.isMultiple(of: 2) ? "• " : "- ")
    }

    private func replaceListMarker(in paragraph: NSRange, with level: Int) {
        let source = string as NSString
        let line = source.substring(with: paragraph)
        guard let current = listMarker(in: line) else { return }
        let range = NSRange(location: paragraph.location, length: current.length)
        let replacement = marker(for: level)
        // Through shouldChangeText/didChangeText rather than straight at the
        // storage. That pair is what registers the edit with the undo manager
        // and tells the delegate the note changed -- writing to the storage
        // directly meant Tab could not be undone, did not mark the note for
        // saving, and left the folds stale.
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    /// ⌘T -- the key that attaches the current slide to a question, doing the
    /// same job in prose.
    ///
    /// The number is written out rather than made into a link of some kind:
    /// these notes are Markdown meant to be readable anywhere, and "(Page 12)"
    /// says the same thing in any text editor as it does here.
    func insertPageReference() {
        // There is always a page: these notes belong to a lecture, and the pane
        // only exists while one is open.
        guard let number = currentPage?() else { return }
        // A space in front when you are mid-sentence, so the reference does not
        // land welded to the word before it.
        let range = selectedRange()
        let source = string as NSString
        let previous = range.location > 0
            ? source.substring(with: NSRange(location: range.location - 1, length: 1))
            : ""
        let lead = previous.isEmpty
            || previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ? "" : " "
        let reference = "(Page \(number))"
        let text = lead + reference

        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(
            in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()

        // After the bracket, which is where you were about to keep writing.
        let start = range.location + (lead as NSString).length
        setSelectedRange(NSRange(location: start + (reference as NSString).length, length: 0))
    }

    override func insertNewline(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0 else {
            super.insertNewline(sender)
            return
        }

        let source = string as NSString
        let paragraph = source.paragraphRange(for: range)
        let line = source.substring(with: paragraph)
        guard let current = listMarker(in: line) else {
            super.insertNewline(sender)
            return
        }

        let content = line.dropFirst(current.length).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            if current.level > 0 {
                replaceListMarker(in: paragraph, with: current.level - 1)
            } else {
                super.insertNewline(sender)
            }
            return
        }

        insertText("\n" + marker(for: current.level), replacementRange: range)
    }

    override func insertTab(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0 else {
            super.insertTab(sender)
            return
        }
        let paragraph = (string as NSString).paragraphRange(for: range)
        let line = (string as NSString).substring(with: paragraph)
        guard let current = listMarker(in: line) else {
            super.insertTab(sender)
            return
        }
        replaceListMarker(in: paragraph, with: current.level + 1)
    }

    override func insertBacktab(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0 else {
            super.insertBacktab(sender)
            return
        }
        let paragraph = (string as NSString).paragraphRange(for: range)
        let line = (string as NSString).substring(with: paragraph)
        guard let current = listMarker(in: line), current.level > 0 else {
            super.insertBacktab(sender)
            return
        }
        replaceListMarker(in: paragraph, with: current.level - 1)
    }

    // MARK: - Folding

    private var paragraphs: [String] { string.components(separatedBy: "\n") }

    /// The paragraphs nested under this one: everything after it until a line
    /// that is not deeper. Blank lines are carried along rather than ending the
    /// run, so a gap inside a list does not cut it in half.
    private func children(of index: Int, in lines: [String]) -> Range<Int>? {
        guard index < lines.count, let depth = listMarker(in: lines[index])?.level else { return nil }
        var cursor = index + 1
        var last = index
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1; continue }
            guard let deeper = listMarker(in: line)?.level, deeper > depth else { break }
            last = cursor
            cursor += 1
        }
        return last > index ? (index + 1)..<(last + 1) : nil
    }

    private func characterRange(ofParagraphs range: Range<Int>, in lines: [String]) -> NSRange {
        var location = 0
        for index in 0..<range.lowerBound { location += (lines[index] as NSString).length + 1 }
        var length = 0
        for index in range { length += (lines[index] as NSString).length + 1 }
        let total = (string as NSString).length
        if location + length > total { length = max(0, total - location) }
        return NSRange(location: location, length: length)
    }

    private func paragraphIndex(forCharacter character: Int, in lines: [String]) -> Int? {
        var location = 0
        for (index, line) in lines.enumerated() {
            let end = location + (line as NSString).length
            if character <= end { return index }
            location = end + 1
        }
        return nil
    }

    /// Rewrite every fold from the current text. Called after any edit, because
    /// the indices are only meaningful against the text as it stands, and a fold
    /// whose parent stopped having children stops existing.
    func applyFolds() {
        guard let storage = textStorage, !applyingFolds else { return }
        applyingFolds = true
        defer { applyingFolds = false }

        let whole = NSRange(location: 0, length: storage.length)
        let lines = paragraphs
        storage.beginEditing()
        storage.removeAttribute(.notesFolded, range: whole)
        var surviving: Set<Int> = []
        for index in folded.sorted() {
            guard let kids = children(of: index, in: lines) else { continue }
            surviving.insert(index)
            let range = characterRange(ofParagraphs: kids, in: lines)
            guard range.length > 0 else { continue }
            storage.addAttribute(.notesFolded, value: true, range: range)
        }
        folded = surviving
        storage.endEditing()

        layoutManager?.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0,
                                        actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        markPageReferences()
        needsDisplay = true
        ribbon?.needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        applyFolds()
    }

    /// Where each foldable line sits, for the ribbon that draws the triangles.
    ///
    /// Public to the ribbon rather than drawn here: putting the triangles in a
    /// subview of their own takes them out of the text view's own drawing
    /// entirely, which is one less thing that has to be true for them to appear.
    struct FoldSpot {
        let index: Int
        let midY: CGFloat
        let open: Bool
    }

    func foldSpots() -> [FoldSpot] {
        guard let layoutManager else { return [] }
        let lines = paragraphs
        let origin = textContainerOrigin
        let total = (string as NSString).length
        var spots: [FoldSpot] = []
        var location = 0
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            defer { location += length + 1 }
            guard children(of: index, in: lines) != nil, location < total else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location,
                                           length: max(1, min(length, total - location))),
                actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                      effectiveRange: nil)
            spots.append(FoldSpot(index: index,
                                  midY: rect.midY + origin.y,
                                  open: !folded.contains(index)))
        }
        return spots
    }

    func toggleFold(atIndex index: Int) {
        if folded.contains(index) { folded.remove(index) } else { folded.insert(index) }
        applyFolds()
    }

    /// Every paragraph with something nested under it.
    private var foldableIndices: [Int] {
        let lines = paragraphs
        return lines.indices.filter { children(of: $0, in: lines) != nil }
    }

    func foldAll() {
        folded = Set(foldableIndices)
        applyFolds()
    }

    func unfoldAll() {
        folded = []
        applyFolds()
    }

    /// What the toolbar button does: fold the lot, unless the lot is already
    /// folded, in which case open it back up. One control instead of two,
    /// because the state it would be reporting is on screen anyway -- every
    /// triangle is already pointing the answer.
    func toggleAllFolds() {
        let all = foldableIndices
        guard !all.isEmpty else { return }
        if all.contains(where: { !folded.contains($0) }) { foldAll() } else { unfoldAll() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit walks the whole view tree of the key window looking for a key
        // equivalent, not just the responder chain, so without this guard the
        // notes editor answered for ⌘Z everywhere in the app -- including PDF
        // edit mode, where it called undo on its own empty undo manager and ⌘Z
        // looked dead. These keys belong to this view only while it has focus.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌥⌘← and ⌥⌘→, which is what folding is bound to in Xcode and in most
        // editors that have it. Nothing else in the app claims them, and these
        // only answer while the notes editor has focus.
        if modifiers == [.command, .option] {
            switch event.keyCode {
            case 123: foldAll();   return true
            case 124: unfoldAll(); return true
            default:  break
            }
        }

        let plainCommand = modifiers == .command
        let shiftCommand = modifiers == [.command, .shift]
        guard plainCommand || shiftCommand,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        if plainCommand {
            switch key {
            case "b": NotesCommand.toggle(.bold).run();          return true
            case "i": NotesCommand.toggle(.italic).run();        return true
            case "u": NotesCommand.toggle(.underline).run();     return true
            case "k": onLink?();                                 return true
            case "t": insertPageReference();                     return true
            case "z": undoManager?.undo();                       return true
            default:  break
            }
        }
        if shiftCommand {
            switch key {
            case "x": NotesCommand.toggle(.strikethrough).run(); return true
            case "z": undoManager?.redo();                       return true
            default:  break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The text view itself.
struct NotesEditor: NSViewRepresentable {
    @ObservedObject var notes: LectureNotes
    @Binding var active: Set<NotesFormat>
    @Binding var headingLevel: Int
    let palette: Palette
    /// ⌘K. Raised here rather than handled here because linking needs an
    /// address, and asking for one is the panel's job.
    let onLink: () -> Void
    /// The slide on screen, asked for at the moment ⌘T is pressed.
    let currentPage: () -> Int
    /// How many slides there are, and how to go to one.
    let pageCount: () -> Int
    let onGoToPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than `NSTextView.scrollableTextView()`, which
        // returns a plain NSTextView and gives no way to substitute a subclass
        // -- and the subclass is what owns ⌘B, ⌘I, ⌘U and ⌘K.
        let scroll = NSScrollView()
        // The text stack is assembled by hand as well, because the folding lives
        // in the layout manager and there is no way to substitute one into a
        // ready-made text view either.
        let storage = NSTextStorage()
        let layout = FoldingLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = NotesTextView(frame: .zero, textContainer: container)
        view.backingStorage = storage
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        view.onLink = onLink
        view.currentPage = currentPage
        view.pageCount = pageCount
        view.onGoToPage = onGoToPage
        view.inkColour = NSColor(palette.ink)
        view.referenceColour = NSColor(palette.select)

        view.isEditable = true
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        // Link detection off: typing a URL should not silently become a link
        // with formatting you did not ask for. The toolbar's Link button is the
        // way to make one.
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.usesFindBar = true
        // Wide enough on the right for the triangles and the overlay scroller
        // side by side. The inset is symmetric, so the left gets the same and
        // simply reads as a margin.
        view.textContainerInset = NSSize(width: NotesTextView.gutter + 10, height: 10)
        view.font = RichTextMarkdown.baseFont
        view.textStorage?.setAttributedString(notes.text)

        let ribbon = FoldRibbon(frame: view.bounds)
        ribbon.owner = view
        view.addSubview(ribbon)
        view.ribbon = ribbon

        view.applyFolds()
        context.coordinator.view = view
        NotesFocus.shared.view = view

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NotesTextView else { return }
        view.onLink = onLink
        view.currentPage = currentPage
        view.pageCount = pageCount
        view.onGoToPage = onGoToPage
        scroll.backgroundColor = NSColor(palette.field)
        view.backgroundColor = NSColor(palette.field)
        view.insertionPointColor = NSColor(palette.ink)
        view.inkColour = NSColor(palette.ink)
        view.referenceColour = NSColor(palette.select)
        context.coordinator.parent = self

        // Only replace the contents when the model changed underneath us -- a
        // different lecture, or the file edited or deleted outside the app.
        // Writing on every update would fight the person typing, resetting the
        // caret with each keystroke.
        if context.coordinator.loadedFile != notes.fileURL
            || context.coordinator.loadedToken != notes.reloadToken {
            context.coordinator.loadedFile = notes.fileURL
            context.coordinator.loadedToken = notes.reloadToken
            view.textStorage?.setAttributedString(notes.text)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            // Folds are indices into the old text; re-derive them against the
            // new one rather than leaving stale ranges marked hidden.
            view.applyFolds()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEditor
        weak var view: NSTextView?
        var loadedFile: URL?
        var loadedToken = 0

        init(_ parent: NotesEditor) {
            self.parent = parent
            self.loadedFile = parent.notes.fileURL
            self.loadedToken = parent.notes.reloadToken
        }

        /// Claim the toolbar. With one note open at a time this is belt and
        /// braces, but it also covers the pane being rebuilt for a new lecture.
        func textDidBeginEditing(_ notification: Notification) {
            // Only a notes editor may claim this. A stray text view -- the one
            // that opens over a PDF text annotation, say -- taking the slot
            // would point every toolbar button at the wrong place.
            guard let view = notification.object as? NotesTextView else { return }
            NotesFocus.shared.view = view
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView,
                  let storage = view.textStorage else { return }
            parent.notes.text = NSAttributedString(attributedString: storage)
            parent.notes.scheduleSave()
        }

        /// Keeps the toolbar honest about what is selected.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView,
                  let storage = view.textStorage, storage.length > 0 else {
                parent.active = []
                return
            }
            let range = view.selectedRange()
            // At a caret, report the character behind it -- that is what typing
            // will inherit, and it is what every other editor shows.
            let index = range.length > 0 ? range.location : max(0, range.location - 1)
            guard index < storage.length else { parent.active = []; return }
            let attributes = storage.attributes(at: index, effectiveRange: nil)

            var found: Set<NotesFormat> = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { found.insert(.bold) }
                if traits.contains(.italic) { found.insert(.italic) }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                found.insert(.underline)
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                found.insert(.strikethrough)
            }
            if parent.active != found { parent.active = found }

            // Read the level off the paragraph, not the run: a heading is a
            // property of the line, and the caret can sit in a plain word inside
            // one.
            let paragraph = (view.string as NSString).paragraphRange(for: range)
            let level: Int
            if paragraph.length > 0,
               let font = storage.attributes(at: paragraph.location, effectiveRange: nil)[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) {
                let over = font.pointSize - RichTextMarkdown.baseSize
                level = over >= 8 ? 1 : (over >= 4 ? 2 : (over >= 1 ? 3 : 0))
            } else {
                level = 0
            }
            if parent.headingLevel != level { parent.headingLevel = level }
        }
    }
}
