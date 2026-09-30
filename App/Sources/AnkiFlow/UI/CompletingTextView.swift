import SwiftUI
import AppKit

/// Which of a card's two written fields has the caret.
enum QuestionField: Hashable { case question, answer }

/// Vocabulary taken off the slides, and the rules for when a word may be
/// offered as a completion.
///
/// The corpus is the point. A general autocomplete has to guess from all of
/// English and is wrong constantly; one built from the handful of slides in
/// front of you is a few hundred words, nearly all of them the exact terms you
/// are about to type, and the long ones are precisely the ones worth not
/// spelling out.
enum SlideVocabulary {
    /// Only words long enough that finishing them saves something. Completing
    /// "cell" costs more attention than it saves.
    static let minimumLength = 8
    /// How much you must have typed before anything is offered.
    static let minimumPrefix = 4
    /// How much of what you have written is matched against the slide when
    /// continuing a phrase. Longer is more certain and rarer; this is the point
    /// where more context stops changing the answer.
    static let maximumContext = 6

    /// Every word on a slide, in the order it appears. Order is what makes
    /// continuing a phrase possible -- a set of words can finish a term, only a
    /// sequence can tell you what comes after it.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// The long ones, deduplicated -- what a half-typed word is matched against.
    static func completionWords(from tokens: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in tokens where word.count >= minimumLength && word.contains(where: \.isLetter) {
            if seen.insert(word.lowercased()).inserted { out.append(word) }
        }
        return out
    }

    /// The one word that can finish `prefix`, or nil.
    ///
    /// Exactly one, never a best guess. Where two slide terms share a prefix --
    /// phosphatidylinositol and phosphatidylserine -- nothing is offered until
    /// you have typed them apart, rather than showing a guess you then have to
    /// notice and reject.
    static func completion(for prefix: String, in words: [String]) -> String? {
        guard prefix.count >= minimumPrefix else { return nil }
        let needle = prefix.lowercased()
        var found: String?
        for word in words {
            guard word.lowercased().hasPrefix(needle), word.count > prefix.count else { continue }
            if found != nil { return nil }        // ambiguous
            found = word
        }
        return found
    }
}

/// The slides in play, as ordered words.
struct SlideCorpus {
    /// One array per slide. Phrases never run across the boundary, because two
    /// slides put next to each other did not say anything in sequence.
    var pages: [[String]] = []
    var words: [String] = []

    var isEmpty: Bool { words.isEmpty && pages.isEmpty }

    /// What the slide says next, given the words written so far.
    ///
    /// Tried longest-context-first, and the first length that matches anywhere
    /// is the answer -- or, if its matches disagree, the end of the line. A
    /// shorter context is strictly less informative, so falling back to one
    /// after a longer one has already proved ambiguous would be trading
    /// certainty for a guess. When a phrase appears twice on a slide followed
    /// by different words, nothing is offered, which is correct: the slide
    /// genuinely does not say which one you mean.
    func nextWord(after context: [String], minimumContext: Int) -> String? {
        let lowered = context.map { $0.lowercased() }
        var length = min(SlideVocabulary.maximumContext, lowered.count)
        while length >= max(1, minimumContext) {
            let tail = Array(lowered.suffix(length))
            var found: [String] = []
            for tokens in pages where tokens.count > length {
                let low = tokens.map { $0.lowercased() }
                for start in 0...(low.count - length - 1)
                where Array(low[start..<(start + length)]) == tail {
                    found.append(tokens[start + length])
                }
            }
            if !found.isEmpty {
                return Set(found.map { $0.lowercased() }).count == 1 ? found[0] : nil
            }
            length -= 1
        }
        return nil
    }
}

// MARK: - The view

/// A text field that can draw a completion after the caret.
///
/// An `NSTextView` rather than SwiftUI's `TextField`, because SwiftUI has no
/// way to render text that is visible but not in the string. Here the ghost is
/// *drawn*, never inserted: the text storage and the binding never contain it,
/// so a suggestion you ignored cannot end up in a card.
struct CompletingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focus: QuestionField?

    let placeholder: String
    let field: QuestionField
    let tabTarget: QuestionField
    var fontSize: CGFloat = 15
    var minLines: Int = 2
    var maxLines: Int = 10
    var corpus = SlideCorpus()
    /// Stock phrases this field offers. Shown while it is empty and matched as
    /// you type, so a prompt you write on nearly every card of a kind is one
    /// keystroke rather than four words.
    var suggestions: [String] = []
    var textColour: Color = .primary

    func makeNSView(context: Context) -> GhostTextView {
        // Built by hand rather than through a convenience initialiser so this
        // is TextKit 1: the ghost is positioned from `layoutManager`, which
        // TextKit 2 does not vend.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = GhostTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.placeholder = placeholder
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GhostTextView, context: Context) {
        context.coordinator.parent = self

        if view.string != text {
            view.string = text
            view.clearGhost()
        }
        view.font = AppFont.questionNS(fontSize)
        view.textColor = NSColor(textColour)
        view.ghostColour = NSColor(textColour).withAlphaComponent(0.38)
        view.placeholderColour = NSColor(textColour).withAlphaComponent(0.35)
        view.minLines = minLines
        view.maxLines = maxLines
        view.corpus = corpus
        view.suggestions = suggestions
        view.invalidateIntrinsicContentSize()

        // Focus is driven from the card, so ⌘N and Tab land in the right field
        // without this view having to know why.
        if focus == field, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CompletingTextView

        init(_ parent: CompletingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? GhostTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            view.refreshGhost()
        }

        func textDidBeginEditing(_ notification: Notification) {
            claimFocus()
        }

        /// Async: this fires during AppKit's responder change, and writing to
        /// SwiftUI state inside that is how you get a mid-update warning.
        func claimFocus() {
            let field = parent.field
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.focus != field else { return }
                self.parent.focus = field
            }
        }

        /// Tab keeps its old job -- moving to the other field. The completion is
        /// accepted with space, so the two never compete.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let ghost = view as? GhostTextView else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                // Tab keeps its one job. The suggestion is taken with ⇧Space,
                // so the two never compete and neither key is overloaded.
                ghost.clearGhost()
                let target = parent.tabTarget
                DispatchQueue.main.async { [weak self] in self?.parent.focus = target }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard ghost.hasGhost else { return false }
                ghost.clearGhost()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - The text view

final class GhostTextView: NSTextView {
    weak var coordinator: CompletingTextView.Coordinator?

    var placeholder = ""
    var placeholderColour: NSColor = .placeholderTextColor
    var ghostColour: NSColor = .placeholderTextColor
    var corpus = SlideCorpus()
    var suggestions: [String] = []
    var minLines = 2
    var maxLines = 10

    /// What would be inserted at the caret. Drawn, never stored.
    private(set) var ghost = ""
    var hasGhost: Bool { !ghost.isEmpty }

    /// True while you are reproducing a phrase off the slide -- set by taking a
    /// suggestion, cleared by writing anything of your own.
    ///
    /// It is what lets a single word be enough context to continue from. Out of
    /// a chain that would be far too little (every "the" on the slide would
    /// offer whatever followed the first one); in one, the previous word was
    /// itself taken from the slide, so the app already knows which sentence you
    /// are in.
    private var inChain = false
    private var accepting = false

    func clearGhost() {
        guard hasGhost else { return }
        ghost = ""
        needsDisplay = true
    }

    /// Works out what, if anything, comes next: the rest of the word you are
    /// part-way through, or -- once you are reproducing a phrase -- the next
    /// word of it.
    func refreshGhost() {
        let previous = ghost
        ghost = ""
        defer { if ghost != previous { needsDisplay = true } }

        guard selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let characters = Array(string)

        // Stock phrases first, and they are the only thing offered to an empty
        // field: with nothing typed there is no prefix to match a slide word
        // against, but "the prompt you always write here" is knowable anyway.
        if !suggestions.isEmpty, caret == characters.count {
            let typed = String(characters)
            if typed.isEmpty {
                ghost = suggestions[0]
                return
            }
            let matches = suggestions.filter {
                $0.count > typed.count && $0.lowercased().hasPrefix(typed.lowercased())
            }
            if matches.count == 1 {
                ghost = String(matches[0].dropFirst(typed.count))
                return
            }
        }

        guard !corpus.isEmpty else { return }
        guard caret <= characters.count else { return }
        // Only at the end of a word: completing into the middle of existing
        // text would push the rest along and read as a bug.
        if caret < characters.count, !characters[caret].isWhitespace { return }

        var start = caret
        while start > 0, characters[start - 1].isLetter || characters[start - 1] == "-" {
            start -= 1
        }
        let typed = String(characters[start..<caret])

        if !typed.isEmpty {
            if let match = SlideVocabulary.completion(for: typed, in: corpus.words) {
                ghost = String(match.dropFirst(typed.count))
                return
            }
            // A finished word with nothing to complete. Worth continuing from
            // only if it was the slide's word rather than yours -- which is
            // exactly the state after taking a suggestion.
            guard inChain else { return }
        }

        let context = Array(SlideVocabulary.tokens(in: String(characters[0..<caret]))
            .suffix(SlideVocabulary.maximumContext))
        guard !context.isEmpty,
              let next = corpus.nextWord(after: context, minimumContext: inChain ? 1 : 2)
        else { return }

        let needsSpace = caret > 0 && !characters[caret - 1].isWhitespace
        ghost = (needsSpace ? " " : "") + next
    }

    /// ⇧Space takes the suggestion; a bare space is still a space.
    ///
    /// Caught here rather than in `insertText` because by then the two are
    /// indistinguishable -- AppKit hands both of them along as a single space
    /// character, and only the event still knows which keys were held. With no
    /// suggestion showing it falls through and types a space, which is what
    /// ⇧Space does everywhere else.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers == " ",
           acceptGhost() {
            return
        }
        super.keyDown(with: event)
    }

    /// Takes the suggestion. Returns false when there was nothing to take.
    @discardableResult
    func acceptGhost() -> Bool {
        guard hasGhost else { return false }
        let completion = ghost
        ghost = ""
        // Set before inserting: the insert triggers a recompute, and the
        // recompute needs to know it is continuing a phrase rather than
        // watching someone type.
        inChain = true
        accepting = true
        insertText(completion, replacementRange: selectedRange())
        accepting = false
        return true
    }

    /// Typing is how you ignore a suggestion -- the ghost is recomputed against
    /// the longer prefix and usually just disappears. It also ends a phrase:
    /// once you are writing your own words, the slide has stopped being what
    /// you are reproducing.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !accepting { inChain = false }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// Return inserts a line break, which is what a multi-line field should do
    /// and what SwiftUI's `TextField(axis: .vertical)` would not: there, Return
    /// submits, and getting a second line meant ⌥Return or pasting one in.
    override func insertNewline(_ sender: Any?) {
        inChain = false
        clearGhost()
        super.insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        inChain = false
        clearGhost()
        super.deleteBackward(sender)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Recomputed rather than cleared. This runs during ordinary typing too
        // -- AppKit moves the selection as part of the edit -- so clearing here
        // would wipe the suggestion a keystroke after making it. Recomputing
        // gives the same answer for a caret that moved away (nothing) without
        // fighting the caret that simply advanced.
        guard !stillSelecting else { return }
        refreshGhost()
    }

    /// Clicking into a field is focusing it.
    ///
    /// `textDidBeginEditing` is not: AppKit posts that on the first *edit*, so
    /// clicking from the question into the answer and not yet typing left the
    /// card still believing the caret was where it used to be -- and the armed
    /// slide row, which follows the caret, pointed at the wrong side.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.claimFocus() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        inChain = false
        clearGhost()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        // Putting the caret somewhere by hand is not continuing a phrase.
        inChain = false
        super.mouseDown(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty, !placeholder.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 15),
                .foregroundColor: placeholderColour
            ]
            NSString(string: placeholder).draw(
                at: NSPoint(x: textContainerOrigin.x + 2, y: textContainerOrigin.y),
                withAttributes: attributes)
        }

        guard hasGhost, let caret = caretRect() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: ghostColour
        ]
        NSString(string: ghost).draw(at: NSPoint(x: caret.maxX, y: caret.minY),
                                     withAttributes: attributes)
    }

    private func caretRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let location = selectedRange().location
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.width == 0, location > 0 {
            // A zero-length range at the end of a run can come back empty, so
            // fall back to the character before it and use its trailing edge.
            let previous = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location - 1, length: 1),
                actualCharacterRange: nil)
            let before = layoutManager.boundingRect(forGlyphRange: previous, in: textContainer)
            rect = NSRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Sizing

    /// Grows with the text between a floor and a ceiling, the way the SwiftUI
    /// field it replaces did.
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let line = layoutManager.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 15))
        let padding = textContainerInset.height * 2
        let height = min(max(used, line * CGFloat(minLines)), line * CGFloat(maxLines)) + padding
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }
}
