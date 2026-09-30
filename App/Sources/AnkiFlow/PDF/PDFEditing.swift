import Foundation
import PDFKit
import AppKit
import CoreGraphics

/// Edits the lecture PDF itself: markup, page order, page boxes.
///
/// This is the one part of the app that writes to your PDF. Everything else --
/// crops, masks, questions -- lives in the sidecar precisely so the source file
/// is never touched, and that separation is worth keeping in mind while reading
/// this file: these operations are the deliberate exception, invoked only from
/// the Edit PDF menu, never as a side effect of making a card.
///
/// Two rules hold everything together:
///
/// 1. **Every operation reports what it did to the page numbering.** The app
///    already knows how to renumber questions -- that machinery exists for PDFs
///    edited in other apps, where it has to *guess* the mapping. Here the
///    mapping is known exactly, so questions follow the pages with no
///    guesswork and nothing to confirm.
/// 2. **Changing a page box rewrites the crops on that page.** Crops and masks
///    are stored as fractions of the crop box. Shrink the box and every one of
///    them silently points somewhere else. The conversion below is what stops
///    "crop the margins off this lecture" from quietly ruining every card in it.
@MainActor
enum PDFEditing {
    nonisolated static let flagKey = "com.ankiflow.flag"
    /// How a page tag says it is one.
    ///
    /// In `/T`, the annotation's title field, rather than in `/Contents` --
    /// because on a FreeText annotation `/Contents` *is* the words on the page,
    /// and a tag has to be able to say "CC" and still be recognisable as ours.
    /// `/T` is a real PDF field, so unlike a private key it is guaranteed to
    /// survive a round trip through any reader.
    nonisolated static let pageTagOwner = "AnkiFlow tag"

    /// Where the corner marks sit, and how big they are.
    ///
    /// Top left, because the slide-number badge lives in the other corner. All
    /// of it measured against the crop box, so a trimmed slide keeps its marks
    /// on the part of the page you can still see.
    nonisolated static let markerSize: CGFloat = 26
    nonisolated static let markerInset: CGFloat = 10
    nonisolated static let markerGap: CGFloat = 4
    nonisolated static let flagLineWidth: CGFloat = 3
    /// Free highlights are Ink like sketches are, so they carry a tag to tell
    /// the two apart -- the eraser needs to know which is which, and `contents`
    /// on an Ink annotation is not shown by any viewer.
    nonisolated static let highlighterKey = "com.ankiflow.highlighter"
    /// A highlighter at setting 3 is a highlighter, not a fat pen. The slider
    /// stays 1-8 for every tool; this is what those numbers mean on the page.
    nonisolated static let highlighterScale: CGFloat = 5
    enum Failure: LocalizedError {
        case writeFailed(String)
        case wouldEmpty
        case notAPDF(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let name):
                return "Could not save \(name). Check that the file isn't open in another app and that the folder is writable."
            case .wouldEmpty:
                return "That would delete every page. A PDF has to keep at least one."
            case .notAPDF(let name):
                return "\(name) isn't a PDF this app can read."
            }
        }
    }

    /// What an edit did, in the terms the rest of the app needs.
    struct Change {
        /// Old 1-based page number -> new one. Pages not mentioned stay put.
        var remap: [Int: Int] = [:]
        /// Old page numbers that no longer exist.
        var removed: [Int] = []
        /// Pages whose box changed, with the old and new boxes in page space,
        /// so normalized crops and masks can be converted rather than shifted.
        /// Keyed by the page's number *after* the edit.
        var boxChanges: [Int: (old: CGRect, new: CGRect)] = [:]
        /// For the undo label and the status line.
        var label: String

        var touchesNumbering: Bool { !remap.isEmpty || !removed.isEmpty }
    }

    // MARK: - Page operations

    /// Rotate pages by a multiple of 90°. Rotation changes what the page looks
    /// like but not its box or its number, so nothing has to follow it.
    static func rotate(pages: [Int], by degrees: Int, in document: PDFDocument) -> Change {
        for number in pages {
            guard let page = document.page(at: number - 1) else { continue }
            // PDFKit stores rotation in degrees and normalises to 0/90/180/270.
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        let label = pages.count == 1 ? "rotating that slide" : "rotating those slides"
        return Change(label: label)
    }

    /// Delete pages. Everything after each one moves up.
    static func delete(pages: [Int], in document: PDFDocument) throws -> Change {
        let doomed = Set(pages.filter { $0 >= 1 && $0 <= document.pageCount })
        guard !doomed.isEmpty else { return Change(label: "deleting nothing") }
        guard doomed.count < document.pageCount else { throw Failure.wouldEmpty }

        // Highest first: removing page 3 would renumber page 7 mid-loop.
        for number in doomed.sorted(by: >) {
            document.removePage(at: number - 1)
        }

        // pageCount is already the reduced one, so the original count has to be
        // reconstructed to walk the old numbering.
        let originalCount = doomed.count + document.pageCount
        var remap: [Int: Int] = [:]
        var shift = 0
        for old in 1...originalCount {
            if doomed.contains(old) {
                shift += 1
            } else {
                remap[old] = old - shift
            }
        }
        let label = doomed.count == 1 ? "deleting that slide" : "deleting those slides"
        return Change(remap: remap, removed: doomed.sorted(), label: label)
    }

    /// Move one page to sit at `destination` (1-based, in the numbering *after*
    /// the move). Everything between the two positions shuffles by one.
    static func move(page from: Int, to destination: Int, in document: PDFDocument) -> Change {
        let count = document.pageCount
        guard from >= 1, from <= count, let page = document.page(at: from - 1) else {
            return Change(label: "moving nothing")
        }
        let to = min(max(destination, 1), count)
        guard to != from else { return Change(label: "moving that slide") }

        document.removePage(at: from - 1)
        document.insert(page, at: to - 1)

        var remap: [Int: Int] = [from: to]
        if from < to {
            for old in (from + 1)...to { remap[old] = old - 1 }
        } else {
            for old in to...(from - 1) { remap[old] = old + 1 }
        }
        return Change(remap: remap, label: "moving that slide")
    }

    /// Insert every page of another PDF at `destination` (1-based).
    static func insert(contentsOf url: URL, at destination: Int, in document: PDFDocument) throws -> Change {
        guard let incoming = PDFDocument(url: url), incoming.pageCount > 0 else {
            throw Failure.notAPDF(url.finderName)
        }
        let at = min(max(destination, 1), document.pageCount + 1)
        // Counted rather than assumed: a page PDFKit declines to copy is one
        // page fewer, and shifting the questions by the number we *meant* to
        // insert would leave every one of them pointing a slide too far along.
        var inserted = 0
        for offset in 0..<incoming.pageCount {
            guard let page = incoming.page(at: offset)?.copy() as? PDFPage else { continue }
            document.insert(page, at: at - 1 + inserted)
            inserted += 1
        }
        guard inserted > 0 else { throw Failure.notAPDF(url.finderName) }

        var remap: [Int: Int] = [:]
        // Only the pages at or after the insertion point move.
        let originalCount = document.pageCount - inserted
        if at <= originalCount {
            for old in at...originalCount { remap[old] = old + inserted }
        }
        let label = inserted == 1 ? "inserting a slide" : "inserting \(inserted) slides"
        return Change(remap: remap, label: label)
    }

    /// Trim pages down to `rect`, given as a fraction of each page's current
    /// crop box -- the same normalized form question crops use, so the region
    /// you drew on screen is the region that survives.
    ///
    /// The old and new boxes are reported per page so crops and masks stored
    /// against the old box can be re-expressed against the new one.
    static func setCropBox(_ rect: CropRect, pages: [Int], in document: PDFDocument) -> Change {
        var boxChanges: [Int: (old: CGRect, new: CGRect)] = [:]
        for number in pages {
            guard let page = document.page(at: number - 1) else { continue }
            let old = page.bounds(for: .cropBox)
            let new = rect.rect(in: old).intersection(page.bounds(for: .mediaBox))
            guard new.width > 1, new.height > 1 else { continue }
            page.setBounds(new, for: .cropBox)
            boxChanges[number] = (old: old, new: new)
        }
        let label = pages.count == 1 ? "cropping that slide" : "cropping those slides"
        return Change(boxChanges: boxChanges, label: label)
    }

    // MARK: - Markup

    /// What the mouse is doing in the slide pane while editing.
    ///
    /// Modelled on Preview's markup bar, including the split it makes between
    /// *tools* (a mode the mouse is in) and *marks* (something you apply to text
    /// you have already selected). The three text marks are `TextMark` below,
    /// not cases here, because they are buttons rather than modes.
    enum Tool: String, CaseIterable, Identifiable {
        /// The resting state: pick up, move, resize and delete marks already on
        /// the page. It has no button, because it is what you are in whenever
        /// you are not holding something else -- a pointer tool you have to
        /// select is a tool you have to remember to put down.
        case select
        case lasso
        /// The three text marks are modes, not one-shot buttons: pick one up and
        /// every stretch of text you drag over gets marked, which is how you get
        /// through a slide rather than selecting-then-clicking each time.
        case highlight
        case underline
        case strikeOut
        /// Highlight for slides with no text layer under them -- a scan, or a
        /// figure. Drawn like the pen rather than dragged as a box: a wide,
        /// translucent stroke you sweep over whatever you meant to mark.
        case freeHighlight
        case pen
        /// Takes out whole marks, not pixels. See `eraseMarks`.
        case eraser
        case line
        case arrow
        case rectangle
        case oval
        case text
        case trim

        var id: String { rawValue }

        /// The shapes that live behind one toolbar button, as Preview does it.
        static let shapes: [Tool] = [.rectangle, .oval, .line, .arrow]

        var label: String {
            switch self {
            case .select:     return "Select"
            case .lasso:      return "Lasso"
            case .highlight:  return "Highlight"
            case .underline:  return "Underline"
            case .strikeOut:  return "Strikethrough"
            case .freeHighlight: return "Free Highlight"
            case .eraser:     return "Eraser"
            case .pen:        return "Sketch"
            case .line:       return "Line"
            case .arrow:      return "Arrow"
            case .rectangle:  return "Rectangle"
            case .oval:       return "Oval"
            case .text:       return "Text"
            case .trim:       return "Trim"
            }
        }

        var symbol: String {
            switch self {
            case .select:     return "cursorarrow"
            case .lasso:      return "lasso"
            case .highlight:  return "highlighter"
            case .underline:  return "underline"
            case .strikeOut:  return "strikethrough"
            case .freeHighlight: return "highlighter"
            case .eraser:     return "eraser"
            case .pen:        return "scribble"
            case .line:       return "line.diagonal"
            case .arrow:      return "line.diagonal.arrow"
            case .rectangle:  return "rectangle"
            case .oval:       return "oval"
            case .text:       return "textbox"
            case .trim:       return "crop"
            }
        }

        var help: String {
            switch self {
            case .select:     return "Click a mark to move, resize or delete it"
            case .lasso:      return "Drag around a mark to select it"
            case .highlight:  return "Drag across text to highlight it"
            case .underline:  return "Drag across text to underline it"
            case .strikeOut:  return "Drag across text to strike it through"
            case .freeHighlight: return "Draw over anything to highlight it — no text needed"
            case .eraser:     return "Drag across marks to rub them out"
            case .pen:        return "Draw freehand"
            case .line:       return "Drag a line"
            case .arrow:      return "Drag an arrow"
            case .rectangle:  return "Drag a rectangle"
            case .oval:       return "Drag an oval"
            case .text:       return "Drag a box, then type into it"
            case .trim:       return "Drag to trim this slide down to that rectangle"
            }
        }

        /// True while the overlay should take the mouse -- which is now always,
        /// including the text marks: dragging over words is handled here with
        /// `PDFPage.selection(from:to:)` rather than by PDFKit, so the mark can
        /// be applied the moment you let go instead of needing a second click.
        var takesMouse: Bool { true }

        /// The mark this tool applies to dragged-over text, if it is one.
        var textMark: TextMark? {
            switch self {
            case .highlight: return .highlight
            case .underline: return .underline
            case .strikeOut: return .strikeOut
            default:         return nil
            }
        }

        /// True for the tools you put down again as soon as you have used them.
        ///
        /// A shape is one-shot, so the thing you just drew can be nudged without
        /// going and finding a pointer. Select, the text marks and Sketch are
        /// modes and stay in your hand: you draw several strokes in a row far
        /// more often than one, and a pen that jumps back to the pointer after
        /// every stroke cannot be used to write.
        var isOneShot: Bool {
            switch self {
            case .select, .highlight, .underline, .strikeOut,
                 .freeHighlight, .pen, .eraser: return false
            case .lasso: return false
            default: return true
            }
        }

        /// Shapes and text are drawn by dragging a rectangle out.
        var drawsRectangle: Bool {
            self == .rectangle || self == .oval || self == .text || self == .trim
        }

        /// Drawn by dragging a freehand stroke out.
        var drawsStroke: Bool { self == .pen || self == .freeHighlight }

        /// True for the tools that keep working over marks already on the page
        /// rather than picking those marks up. They are the ones you hold down
        /// and repeat, so a press has to mean "do it again here", not "select
        /// that": you hatch over your own sketch, highlight over a highlight,
        /// and an eraser that grabbed instead of erasing would be useless.
        var paintsOverMarks: Bool {
            self == .pen || self == .eraser || self == .freeHighlight
        }

        var drawsLine: Bool { self == .line || self == .arrow }
    }

    /// The subtype behind each text mark.
    enum TextMark: String, CaseIterable, Identifiable {
        case highlight, underline, strikeOut

        var id: String { rawValue }

        var label: String {
            switch self {
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strikeOut: return "Strikethrough"
            }
        }

        var symbol: String {
            switch self {
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strikeOut: return "strikethrough"
            }
        }

        var subtype: PDFAnnotationSubtype {
            switch self {
            case .highlight: return .highlight
            case .underline: return .underline
            case .strikeOut: return .strikeOut
            }
        }
    }

    /// Build the annotations for the current text selection, one per line -- a
    /// selection spanning three lines drawn as a single rectangle would paint
    /// over everything between them. Returns them unattached, so the caller can
    /// add them through the undo stack.
    static func marks(for selection: PDFSelection?, kind: TextMark,
                      colour: NSColor) -> [(annotation: PDFAnnotation, page: PDFPage)] {
        guard let selection else { return [] }
        let group = markGroupPrefix + ULID.generate()
        var made: [(annotation: PDFAnnotation, page: PDFPage)] = []
        for line in selection.selectionsByLine() {
            // A line with no selected text in it is not a line of the selection.
            //
            // `selectionsByLine()` hands back rows the selection does not
            // actually cover -- a blank row it stepped over, and on some pages a
            // spurious one whose bounds sit nowhere near what you dragged. Both
            // used to become a mark, which is where the solid bars over empty
            // paper came from: one per marking action, somewhere else on the
            // page entirely.
            guard line.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else { continue }

            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                // And never outside the selection itself. Whatever PDFKit means
                // by a line, a mark that lands beyond the box around everything
                // you selected is wrong by definition.
                let whole = selection.bounds(for: page)
                guard whole.width > 0, whole.height > 0, whole.insetBy(dx: -2, dy: -2).contains(
                    CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
                // One mark per run of actual text, not one per line.
                //
                // `bounds(for:)` is the box around everything selected on that
                // line, and a slide's text layer puts things on the same line
                // that are nowhere near each other -- a caption beside a figure,
                // two columns, a label floating to the right. Marking the box
                // then paints a bar straight across the gap between them, over
                // artwork and empty space that was never selected.
                for run in textRuns(in: bounds, on: page) {
                    made.append((mark(run, kind: kind, colour: colour, group: group), page))
                }
            }
        }
        return made
    }

    /// Everything one marking action produced wears the same id.
    ///
    /// A sentence marked across four lines is four annotations -- that is how
    /// PDF highlights work -- but it is one thing you did, so it has to behave
    /// like one thing: click any line and you have the sentence, delete and the
    /// sentence goes, recolour and the sentence changes.
    static let markGroupPrefix = "ankiflow.mark:"

    static func markGroup(of annotation: PDFAnnotation) -> String? {
        guard let contents = annotation.contents,
              contents.hasPrefix(markGroupPrefix) else { return nil }
        return contents
    }

    static func isTextMark(_ annotation: PDFAnnotation) -> Bool {
        markGroup(of: annotation) != nil
    }

    /// Full strength, now that highlights are composited rather than laid over.
    ///
    /// The old 0.38 was working around the wrong thing: PDFKit paints a
    /// highlight *over* the text with ordinary alpha, so a strong colour turned
    /// black type olive, and the only way to keep the words readable was to
    /// make the mark faint. Multiplying instead leaves black text black at any
    /// strength -- which is what a real highlighter does, and what Preview and
    /// the iPad have been doing all along.
    static func markColour(_ colour: NSColor, kind: TextMark) -> NSColor {
        kind == .highlight ? colour.withAlphaComponent(1) : colour
    }

    // MARK: - Highlights, drawn properly

    /// `type` comes back as "Highlight" or "/Highlight" depending on where the
    /// annotation came from, so the suffix is what to test.
    static func isHighlight(_ annotation: PDFAnnotation) -> Bool {
        (annotation.type ?? "").hasSuffix("Highlight")
    }

    /// Stops PDFKit drawing the highlights so we can draw them ourselves.
    ///
    /// The flag lives on the annotation and would be written into your file as
    /// a hidden flag, which would make every highlight vanish in Preview -- so
    /// `save(_:to:)` puts them all back before it writes and takes them over
    /// again afterwards. That is the only place a document is written, which is
    /// what makes this safe to do at all.
    /// An annotation moved to another copy of the same lecture.
    ///
    /// Property by property rather than through an archiver: quad points are
    /// relative to the annotation's own bounds, so they carry across verbatim,
    /// and an image stamp is a subclass of ours that a generic copy would
    /// silently turn into an empty stamp. Everything here was made by this app
    /// minutes ago, which is what makes a faithful copy possible at all.
    static func copy(_ annotation: PDFAnnotation) -> PDFAnnotation? {
        if let stamp = annotation as? PDFImageStamp {
            return PDFImageStamp(image: stamp.image, bounds: stamp.bounds)
        }
        guard let type = annotation.type else { return nil }
        let subtype = PDFAnnotationSubtype(rawValue: type.hasPrefix("/") ? type : "/" + type)
        let made = PDFAnnotation(bounds: annotation.bounds, forType: subtype, withProperties: nil)
        made.color = annotation.color
        made.contents = annotation.contents
        made.quadrilateralPoints = annotation.quadrilateralPoints
        made.border = annotation.border
        made.interiorColor = annotation.interiorColor
        made.startPoint = annotation.startPoint
        made.endPoint = annotation.endPoint
        made.font = annotation.font
        made.fontColor = annotation.fontColor
        made.alignment = annotation.alignment
        if let paths = annotation.paths {
            for path in paths { made.add(path) }
        }
        made.shouldDisplay = annotation.shouldDisplay
        return made
    }

    /// Which annotations *we* hid, so restoring puts back only those.
    ///
    /// A highlight that was already hidden in your file was hidden by whoever
    /// wrote it, and un-hiding it on the next save would be this app editing
    /// your document without being asked.
    private static var hiddenByUs = Set<ObjectIdentifier>()

    static func takeOverHighlights(in document: PDFDocument?) {
        forEachHighlight(in: document) { annotation in
            guard annotation.shouldDisplay else { return }
            annotation.shouldDisplay = false
            hiddenByUs.insert(ObjectIdentifier(annotation))
        }
    }

    static func restoreHighlights(in document: PDFDocument?) {
        forEachHighlight(in: document) { annotation in
            guard hiddenByUs.contains(ObjectIdentifier(annotation)) else { return }
            annotation.shouldDisplay = true
        }
    }

    private static func forEachHighlight(in document: PDFDocument?,
                                         _ body: (PDFAnnotation) -> Void) {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where isHighlight(annotation) {
                body(annotation)
            }
        }
    }

    /// Paints a page's highlights the way a highlighter works: multiplied into
    /// what is underneath, so the paper goes yellow and the ink stays black.
    ///
    /// **PDFKit still draws each annotation.** Nothing here reconstructs a
    /// highlight from its quad points -- that would square off rounded ends,
    /// straighten a skewed quad and throw away any appearance the writer gave
    /// it. The annotation is drawn by the same code that drew it before; the
    /// only difference is the blend mode of the context it lands in.
    ///
    /// `place` maps the page's own coordinate space into whatever is being
    /// drawn -- the view, or the card image -- so the screen and the exported
    /// slide go through one function and cannot drift apart.
    static func drawHighlights(on page: PDFPage, box: PDFDisplayBox = .cropBox,
                               place: (CGContext) -> Void) {
        let highlights = page.annotations.filter(isHighlight)
        guard !highlights.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.setBlendMode(.multiply)
        place(context)
        for annotation in highlights {
            // Visible for exactly this call. `shouldDisplay` is what keeps
            // PDFKit from drawing it in the ordinary pass; drawing it here is
            // the whole point of having hidden it.
            guard hiddenByUs.contains(ObjectIdentifier(annotation)) else { continue }
            let authored = annotation.color
            annotation.shouldDisplay = true
            // Ours were drawn faint to survive being laid over text. Multiplied,
            // that is no longer necessary, so they are shown at full strength --
            // for the drawing only, never written. A highlight you made
            // somewhere else is shown exactly as you made it.
            if isTextMark(annotation), authored.alphaComponent < 0.99 {
                annotation.color = authored.withAlphaComponent(1)
            }
            annotation.draw(with: box, in: context)
            annotation.color = authored
            annotation.shouldDisplay = false
        }
        context.restoreGState()
    }

    private static func mark(_ bounds: CGRect, kind: TextMark, colour: NSColor,
                             group: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: kind.subtype,
                                       withProperties: nil)
        annotation.color = markColour(colour, kind: kind)
        annotation.contents = group
        // Perimeter order, and **relative to the annotation's own bounds** --
        // not page coordinates.
        //
        // This is the stray bar. Handing PDFKit absolute page points put the
        // quad at bounds.origin + the point, so every mark drew its text
        // highlight in the right place and a second copy of itself displaced by
        // its own origin -- up the page, and further the lower down the page you
        // marked. One annotation with two rectangles, which is exactly why
        // moving the good one moved the ghost, deleting it deleted both, and the
        // ghost could not be clicked: there was nothing there to click, only a
        // misplaced part of the annotation you already had.
        let p1 = CGPoint(x: 0, y: bounds.height)
        let p2 = CGPoint(x: bounds.width, y: bounds.height)
        let p3 = CGPoint(x: 0, y: 0)
        let p4 = CGPoint(x: bounds.width, y: 0)
        annotation.quadrilateralPoints = [NSValue(point: p1), NSValue(point: p2),
                                          NSValue(point: p3), NSValue(point: p4)]
        // A new highlight joins the ones we draw ourselves; underlines and
        // strikethroughs are lines, not washes, and PDFKit draws those fine.
        annotation.shouldDisplay = !isHighlight(annotation)
        return annotation
    }

    /// The characters inside one line's selection, grouped into runs.
    ///
    /// Every character whose box sits inside the line's own bounds was between
    /// the start and end of the selection on that line, so it was selected --
    /// which is why this can gather them by geometry without needing the
    /// selection's character ranges, something PDFKit does not hand out.
    ///
    /// Runs break where the horizontal gap is wider than the line is tall. That
    /// is comfortably more than the space between two words at any size, and
    /// comfortably less than the gap between two columns, so ordinary spaces
    /// stay inside one mark and a real void splits it in two.
    private static func textRuns(in lineBounds: CGRect, on page: PDFPage) -> [CGRect] {
        var boxes: [CGRect] = []
        for index in 0..<page.numberOfCharacters {
            let box = page.characterBounds(at: index)
            guard box.width > 0, box.height > 0,
                  box.midY > lineBounds.minY, box.midY < lineBounds.maxY,
                  box.midX > lineBounds.minX - 0.5, box.midX < lineBounds.maxX + 0.5
            else { continue }
            boxes.append(box)
        }
        // No characters on this line means there is nothing here to mark.
        //
        // `selectionsByLine()` hands back a line for every row the drag passed
        // through, including blank ones, and a blank line's bounds still span
        // the width of the text column. Falling back to those bounds -- which is
        // what this did -- painted a bar across empty paper for each of them,
        // and several stacked on nearly the same spot turned a translucent
        // highlight into a solid block. Marking nothing is the honest answer.
        guard !boxes.isEmpty else { return [] }

        boxes.sort { $0.minX < $1.minX }
        let gapLimit = lineBounds.height
        var runs: [CGRect] = []
        var current = boxes[0]
        for box in boxes.dropFirst() {
            if box.minX - current.maxX > gapLimit {
                runs.append(current)
                current = box
            } else {
                current = current.union(box)
            }
        }
        runs.append(current)
        return runs.filter { $0.width > 1 && $0.height > 1 }
    }

    /// The pennant on a flagged page.
    ///
    /// Still an Ink path, and so still an outline: PDF has no way to fill an
    /// Ink annotation, `/InkList` being a list of strokes and nothing else.
    /// PDFKit fills a closed one anyway, which is why it looks solid here and
    /// hollow everywhere else. That is a cosmetic difference and worth keeping
    /// the shape for.
    ///
    /// **What is not cosmetic is the rectangle.** The bounds used to be the
    /// whole media box with the pennant drawn small inside it. PDFKit clips to
    /// the path so nothing looked wrong here -- but every other reader takes
    /// `/Rect` as the annotation's extent, so in Preview the flag *was* the
    /// page: it could not be missed by a lasso, and every attempt to select
    /// something else dragged the pennant along with it. The rectangle now
    /// fits the pennant, padded by the stroke, which straddles the path and
    /// would otherwise be clipped by its own bounds.
    static func flag(on page: PDFPage) -> PDFAnnotation {
        let frame = markerFrame(slot: 0, width: markerSize, in: page.bounds(for: .cropBox))
        let marker = PDFAnnotation(bounds: frame.insetBy(dx: -flagLineWidth, dy: -flagLineWidth),
                                   forType: .ink, withProperties: nil)
        marker.contents = flagKey
        marker.color = .systemBlue
        // Page coordinates, which is what `/InkList` holds and what every pen
        // stroke in this app already writes. The rectangle is the bounding box,
        // not the origin the points are measured from.
        let path = NSBezierPath()
        let x = frame.minX, y = frame.minY, w = frame.width, h = frame.height
        path.move(to: CGPoint(x: x, y: y + h))
        path.line(to: CGPoint(x: x + w, y: y + h))
        path.line(to: CGPoint(x: x + w, y: y))
        path.line(to: CGPoint(x: x + w / 2, y: y + h * 0.3))
        path.line(to: CGPoint(x: x, y: y))
        path.close()
        marker.add(path)
        let border = PDFBorder()
        border.lineWidth = flagLineWidth
        marker.border = border
        return marker
    }

    nonisolated static func isFlag(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents == flagKey
    }

    // MARK: - Page tags

    /// Where the nth mark along the top-left corner sits.
    nonisolated static func markerFrame(slot: CGFloat, width: CGFloat, in box: CGRect) -> CGRect {
        CGRect(x: box.minX + markerInset + slot,
               y: box.maxY - markerInset - markerSize,
               width: width, height: markerSize)
    }

    nonisolated static func isPageTag(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName == pageTagOwner
    }

    nonisolated static func pageTagLabel(of annotation: PDFAnnotation) -> String? {
        isPageTag(annotation) ? annotation.contents : nil
    }

    /// A short label beside the pennant -- "CC", "HY", whatever you have made.
    ///
    /// FreeText, so the letters are in the file as letters: readable in Preview,
    /// on the iPad, in anything. Its position is settled by `placeTags`, which
    /// runs after every change so the row never has a hole in it.
    static func pageTag(_ label: String, on page: PDFPage) -> PDFAnnotation {
        let tag = PDFAnnotation(bounds: markerFrame(slot: 0, width: tagWidth(for: label),
                                                    in: page.bounds(for: .cropBox)),
                                forType: .freeText, withProperties: nil)
        tag.contents = label
        tag.userName = pageTagOwner
        tag.font = tagFont
        tag.fontColor = .systemBlue
        // Transparent, not white: a tag sits on the slide, it does not patch it.
        tag.color = .clear
        tag.alignment = .center
        return tag
    }

    nonisolated static var tagFont: NSFont { NSFont.boldSystemFont(ofSize: 13) }

    nonisolated static func tagWidth(for label: String) -> CGFloat {
        let text = label as NSString
        let measured = text.size(withAttributes: [.font: tagFont]).width
        return max(markerSize, ceil(measured) + 10)
    }

    /// Lays the tags out along the corner, after the pennant when there is one.
    ///
    /// Called after every add and every removal rather than positioning a tag
    /// when it is made, because taking the first of three away has to close the
    /// gap it leaves -- and a tag's place depends on what else is on the page,
    /// not on when you added it.
    nonisolated static func placeTags(on page: PDFPage) {
        let box = page.bounds(for: .cropBox)
        var offset: CGFloat = page.annotations.contains(where: isFlag)
            ? markerSize + markerGap : 0
        for tag in page.annotations where isPageTag(tag) {
            let width = tagWidth(for: tag.contents ?? "")
            tag.bounds = markerFrame(slot: offset, width: width, in: box)
            offset += width + markerGap
        }
    }

    /// A rectangle or an oval.
    static func shape(_ tool: Tool, in rect: CGRect, stroke: NSColor,
                      fill: NSColor?, width: CGFloat) -> PDFAnnotation? {
        let subtype: PDFAnnotationSubtype
        switch tool {
        case .rectangle: subtype = .square
        case .oval:      subtype = .circle
        default:         return nil
        }
        let annotation = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
        annotation.color = stroke
        annotation.interiorColor = fill
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        return annotation
    }

    /// A line, optionally with an arrowhead at the far end.
    ///
    /// Bounds are the page's media box and the endpoints are in page
    /// coordinates, for the same reason `stroke` does it: PDFKit is
    /// inconsistent across versions about whether a line's points are stored
    /// relative to its bounds, and a bounds origin at the page's own origin
    /// makes both readings land in the same place.
    static func line(from start: CGPoint, to end: CGPoint, arrow: Bool,
                     colour: NSColor, width: CGFloat, on page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: page.bounds(for: .mediaBox),
                                       forType: .line, withProperties: nil)
        annotation.startPoint = start
        annotation.endPoint = end
        annotation.endLineStyle = arrow ? .closedArrow : .none
        annotation.color = colour
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        return annotation
    }

    /// A freehand stroke, given in page coordinates.
    static func stroke(_ path: NSBezierPath, colour: NSColor, width: CGFloat,
                       on page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: page.bounds(for: .mediaBox),
                                       forType: .ink, withProperties: nil)
        annotation.color = colour
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.add(path)
        return annotation
    }

    /// A free highlight: the pen's stroke, drawn fat and see-through.
    static func highlighterStroke(_ path: NSBezierPath, colour: NSColor, width: CGFloat,
                                  on page: PDFPage) -> PDFAnnotation {
        let annotation = stroke(path, colour: highlighterColour(colour), width: width, on: page)
        annotation.contents = highlighterKey
        return annotation
    }

    /// See-through enough to read the slide through, opaque enough to see.
    static func highlighterColour(_ colour: NSColor) -> NSColor {
        (colour.usingColorSpace(.sRGB) ?? colour).withAlphaComponent(0.35)
    }

    static func isHighlighter(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents == highlighterKey
    }

    /// What an eraser sweep is allowed to take in one pass.
    ///
    /// A sweep erases one class and one only. Highlights and sketches end up
    /// layered on top of each other constantly -- that is what highlighting is
    /// for -- and a sweep that took both would cost you the drawing every time
    /// you meant to clear a highlight. Marks win when a sweep touches both, so
    /// clearing a highlight off a diagram leaves the diagram; a second sweep,
    /// with the highlight gone, takes the drawing.
    enum EraseClass {
        case marks
        case drawings
    }

    static func eraseClass(of annotation: PDFAnnotation) -> EraseClass {
        if isHighlighter(annotation) { return .marks }
        switch kind(of: annotation) {
        case "Highlight", "Underline", "StrikeOut": return .marks
        default: return .drawings
        }
    }

    /// A picture off the clipboard, dropped onto a slide at a sensible size.
    static func imageStamp(_ image: NSImage, on page: PDFPage) -> PDFAnnotation {
        let box = page.bounds(for: .mediaBox)
        let native = image.size
        guard native.width > 0, native.height > 0 else {
            return PDFImageStamp(image: image, bounds: box.insetBy(dx: box.width / 3,
                                                                   dy: box.height / 3))
        }
        // Big enough to see, small enough to leave the slide visible around it.
        let scale = min(box.width * 0.45 / native.width,
                        box.height * 0.45 / native.height, 1)
        let size = CGSize(width: native.width * scale, height: native.height * scale)
        let origin = CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
        return PDFImageStamp(image: image, bounds: CGRect(origin: origin, size: size))
    }

    /// A copy that survives being a picture. `PDFAnnotation.copy()` knows
    /// nothing about the image a stamp carries, so copy and paste of a pasted
    /// picture would otherwise hand back an empty box.
    static func duplicate(_ annotation: PDFAnnotation) -> PDFAnnotation? {
        if let stamp = annotation as? PDFImageStamp {
            return PDFImageStamp(image: stamp.image, bounds: stamp.bounds)
        }
        return annotation.copy() as? PDFAnnotation
    }

    static func hasImageStamps(_ document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { index in
            document.page(at: index)?.annotations.contains { $0 is PDFImageStamp } == true
        }
    }

    /// The smallest a text box can be and still show everything in it.
    ///
    /// One definition, used both when a box is committed and when one is being
    /// resized, so the size it settles at and the size it refuses to go below
    /// are the same number.
    /// The breathing room a text box keeps around its words.
    nonisolated static let textInset: CGFloat = 8

    /// The styled text of a box, however it happens to be stored.
    static func attributedText(of annotation: PDFAnnotation) -> NSAttributedString {
        if let rich = richText(for: annotation) { return rich }
        let font = annotation.font ?? NSFont.systemFont(ofSize: 14)
        return NSAttributedString(string: annotation.contents ?? "",
                                  attributes: [.font: font])
    }

    static func fittedSize(of text: NSAttributedString) -> CGSize {
        guard text.length > 0 else { return CGSize(width: 24, height: 24) }
        let bounds = text.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: max(24, ceil(bounds.width) + textInset),
                      height: max(24, ceil(bounds.height) + textInset))
    }

    /// The size the same text needs when it is allowed to wrap at `width`.
    ///
    /// The unconstrained measurement above answers a different question -- how
    /// wide would this be all on one line -- and using it as a minimum is what
    /// made a paragraph in a text box impossible to narrow.
    static func fittedSize(of text: NSAttributedString, wrappingAt width: CGFloat) -> CGSize {
        guard text.length > 0 else { return CGSize(width: 24, height: 24) }
        let bounds = text.boundingRect(
            with: NSSize(width: max(1, width - textInset),
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: max(24, ceil(bounds.width) + textInset),
                      height: max(24, ceil(bounds.height) + textInset))
    }

    static func fittedSize(for annotation: PDFAnnotation) -> CGSize {
        fittedSize(of: attributedText(of: annotation))
    }

    /// The smallest a text box may be dragged, given the width it is being
    /// dragged to.
    ///
    /// Width and height are two different questions, asked in that order.
    /// Narrowing a box is how you make its text wrap, so the only real floor on
    /// width is the longest single word -- below that there is nothing left to
    /// break. The height then has to be whatever the text needs *once wrapped
    /// at that width*, which grows as the box narrows. Measuring both against
    /// one unwrapped line got this backwards on both axes: the width could
    /// never shrink, and the height could be dragged down over text that had
    /// wrapped onto four lines.
    static func minimumSize(for annotation: PDFAnnotation, atWidth width: CGFloat) -> CGSize {
        let text = attributedText(of: annotation)
        guard text.length > 0 else { return CGSize(width: 24, height: 24) }
        let floorWidth = max(24, ceil(longestWordWidth(in: text)) + textInset)
        let wrapped = fittedSize(of: text, wrappingAt: max(width, floorWidth))
        return CGSize(width: floorWidth, height: wrapped.height)
    }

    /// The widest run with no break in it -- the one thing a narrower box
    /// cannot make room for.
    private static func longestWordWidth(in text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let whole = text.string as NSString
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length),
                                  options: [.byWords]) { _, range, _, _ in
            let word = text.attributedSubstring(from: range)
            let bounds = word.boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                             height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            widest = max(widest, bounds.width)
        }
        return widest
    }

    /// An empty text box, ready to be typed into.
    static func textBox(in rect: CGRect, colour: NSColor, size: CGFloat) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = ""
        annotation.fontColor = colour
        annotation.font = NSFont.systemFont(ofSize: size)
        // Transparent, not white: a note is an addition to the slide, not a
        // patch over it.
        annotation.color = .clear
        return annotation
    }

    static let richTextKey = PDFAnnotationKey(rawValue: "com.ankiflow.richText")

    static func richText(for annotation: PDFAnnotation) -> NSAttributedString? {
        guard let data = annotation.value(forAnnotationKey: richTextKey) as? Data else { return nil }
        return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                       documentAttributes: nil)
    }

    static func setRichText(_ text: NSAttributedString, on annotation: PDFAnnotation) {
        guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else { return }
        annotation.setValue(data, forAnnotationKey: richTextKey)
    }

    static func textFont(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// An annotation's subtype without PDF's leading slash.
    ///
    /// `PDFAnnotation.type` reports the raw PDF name, which on some macOS
    /// versions is "/Ink" and on others "Ink". Branching on the unnormalised
    /// string is how you get an editor where lines and sketches silently refuse
    /// to move: every `case` misses and they fall through to the bounds path,
    /// which for those two does nothing at all.
    static func kind(of annotation: PDFAnnotation) -> String {
        let raw = annotation.type ?? ""
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    /// Move a mark by a delta in page coordinates.
    ///
    /// Three shapes of annotation need three different moves. Ink and line keep
    /// their geometry in their own properties with the bounds pinned to the
    /// page, so shifting the bounds would move nothing; everything else is
    /// positioned by its bounds alone. Returns a closure that puts it back,
    /// which is what the undo stack stores.
    /// Move a mark that keeps its position in its bounds or its endpoints.
    ///
    /// Sketches are not handled here -- see `translated`. Removing and re-adding
    /// an ink annotation's paths in place relies on `paths` handing back the
    /// same objects PDFKit stored, and if it hands back copies the removes
    /// quietly do nothing and every mouse event stacks another stroke on top.
    static func move(_ annotation: PDFAnnotation, by delta: CGSize) {
        switch kind(of: annotation) {
        case "Line":
            let start = annotation.startPoint
            let end = annotation.endPoint
            annotation.startPoint = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
            annotation.endPoint = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        case "Ink":
            guard let paths = annotation.paths else { return }
            let transform = AffineTransform(translationByX: delta.width, byY: delta.height)
            for path in paths {
                guard let moved = path.copy() as? NSBezierPath else { continue }
                moved.transform(using: transform)
                annotation.remove(path)
                annotation.add(moved)
            }
        default:
            annotation.bounds = annotation.bounds.offsetBy(dx: delta.width, dy: delta.height)
        }
    }

    static func isSketch(_ annotation: PDFAnnotation) -> Bool { kind(of: annotation) == "Ink" }

    /// A copy of a sketch, shifted. Sketches move by replacement rather than
    /// mutation: build a fresh annotation from the original's paths, swap it in,
    /// and the undo step is simply swapping the original back.
    static func translated(_ annotation: PDFAnnotation, paths: [NSBezierPath],
                           by delta: CGSize, on page: PDFPage) -> PDFAnnotation {
        let transform = AffineTransform(translationByX: delta.width, byY: delta.height)
        let copy = PDFAnnotation(bounds: page.bounds(for: .mediaBox),
                                 forType: .ink, withProperties: nil)
        copy.color = annotation.color
        copy.border = annotation.border
        copy.contents = annotation.contents
        for path in paths {
            guard let moved = path.copy() as? NSBezierPath else { continue }
            moved.transform(using: transform)
            copy.add(moved)
        }
        return copy
    }

    static func transformedInk(_ annotation: PDFAnnotation, paths: [NSBezierPath],
                               using transform: AffineTransform, on page: PDFPage) -> PDFAnnotation {
        let copy = PDFAnnotation(bounds: page.bounds(for: .mediaBox),
                                 forType: .ink, withProperties: nil)
        copy.color = annotation.color
        copy.border = annotation.border
        copy.contents = annotation.contents
        for path in paths {
            guard let transformed = path.copy() as? NSBezierPath else { continue }
            transformed.transform(using: transform)
            copy.add(transformed)
        }
        return copy
    }

    /// The rectangle a mark occupies on the page, whatever it keeps its
    /// geometry in. Used to draw the selection and to hit-test it.
    static func frame(of annotation: PDFAnnotation) -> CGRect {
        switch kind(of: annotation) {
        case "Line":
            let start = annotation.startPoint
            let end = annotation.endPoint
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
                .insetBy(dx: -4, dy: -4)
        case "Ink":
            guard let paths = annotation.paths, !paths.isEmpty else { return annotation.bounds }
            return paths.dropFirst().reduce(paths[0].bounds) { $0.union($1.bounds) }
                .insetBy(dx: -4, dy: -4)
        default:
            return annotation.bounds
        }
    }

    /// Whether a mark can be resized by dragging a corner. Sketches cannot --
    /// scaling a freehand stroke by its bounding box is a gesture nobody wants
    /// and PDFKit gives no clean way to do it.
    /// Lines are excluded too: a line's geometry is its two endpoints, and its
    /// bounds are the whole page, so dragging a corner of the box round it would
    /// stamp a meaningless rectangle into `bounds` and not move the line at all.
    static func isResizable(_ annotation: PDFAnnotation) -> Bool {
        let type = kind(of: annotation)
        return type != "Ink" && type != "Line" &&
            type != "Highlight" && type != "Underline" && type != "StrikeOut"
    }

    /// The topmost mark under a point in page coordinates.
    static func mark(at point: CGPoint, on page: PDFPage, tolerance: CGFloat = 6) -> PDFAnnotation? {
        page.annotations.last { hits($0, at: point, tolerance: tolerance) }
    }

    /// Every mark under a point, topmost first. The eraser needs the whole
    /// stack, not just the top of it: a highlight under a sketch has to be
    /// reachable in one sweep.
    static func marks(at point: CGPoint, on page: PDFPage,
                      tolerance: CGFloat = 6) -> [PDFAnnotation] {
        Array(page.annotations.filter { hits($0, at: point, tolerance: tolerance) }.reversed())
    }

    private static func hits(_ annotation: PDFAnnotation, at point: CGPoint,
                             tolerance: CGFloat) -> Bool {
        guard !isFlag(annotation) else { return false }
        if kind(of: annotation) == "Ink", let paths = annotation.paths, !paths.isEmpty {
            // A fat highlighter stroke has to be catchable anywhere across its
            // width, not only along the line its points were recorded on.
            let reach = max(tolerance, (annotation.border?.lineWidth ?? 1) / 2)
            let origin = annotation.bounds.origin
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            return paths.contains {
                near($0, point: point, tolerance: reach)
                    || near($0, point: local, tolerance: reach)
            }
        }
        return frame(of: annotation).insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Whether a point lands on a path, judged by its control points. Exact
    /// curve distance would be better and is not worth the arithmetic: pen
    /// strokes are captured as short straight segments, so the points *are* the
    /// stroke.
    private static func near(_ path: NSBezierPath, point: CGPoint, tolerance: CGFloat) -> Bool {
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let kind = path.element(at: index, associatedPoints: &points)
            // How many of the three slots the element actually filled. Reading
            // past what it wrote would compare against the last one's points.
            let count: Int
            switch kind {
            case .moveTo, .lineTo:    count = 1
            case .quadraticCurveTo:   count = 2
            case .cubicCurveTo:       count = 3
            case .closePath:          count = 0
            @unknown default:         count = 1
            }
            for offset in 0..<count {
                let candidate = points[offset]
                if abs(candidate.x - point.x) <= tolerance && abs(candidate.y - point.y) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Saving

    /// Burn pasted pictures into the pages that carry them.
    ///
    /// A `PDFImageStamp` draws itself, which is all the editor needs but is not
    /// how PDF works: `write(to:)` serialises an annotation's dictionary, and a
    /// Stamp with no appearance stream comes back as an empty box. So before
    /// writing, any page holding one is rebuilt with the picture as part of the
    /// page itself.
    ///
    /// The rebuild draws the page through PDFKit rather than rasterising it, so
    /// the text stays text -- search, extraction and the card renderer all still
    /// work on the result. Every other mark is hidden for the draw and copied
    /// onto the new page afterwards, so highlights and sketches stay live
    /// annotations you can still move and erase.
    static func flattenImageStamps(in document: PDFDocument) -> PDFDocument {
        guard hasImageStamps(document) else { return document }

        // Serialised first and patched second, so every page without a picture
        // on it goes out exactly as `write(to:)` would have written it. Only the
        // pages that actually carry a stamp are rebuilt.
        guard let data = document.dataRepresentation(),
              let flattened = PDFDocument(data: data),
              flattened.pageCount == document.pageCount else { return document }

        for index in 0..<document.pageCount {
            guard let live = document.page(at: index),
                  live.annotations.contains(where: { $0 is PDFImageStamp }),
                  let rebuilt = burnStamps(on: live) else { continue }
            flattened.removePage(at: index)
            flattened.insert(rebuilt, at: index)
        }
        return flattened
    }

    private static func burnStamps(on page: PDFPage) -> PDFPage? {
        var box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let keep = page.annotations.filter { !($0 is PDFImageStamp) }
        let wereShown = keep.filter(\.shouldDisplay)
        for annotation in wereShown { annotation.shouldDisplay = false }
        defer { for annotation in wereShown { annotation.shouldDisplay = true } }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: context)
        context.endPDFPage()
        context.closePDF()

        guard let rebuilt = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        rebuilt.rotation = page.rotation
        for annotation in keep {
            guard let copy = duplicate(annotation) else { continue }
            rebuilt.addAnnotation(copy)
        }
        return rebuilt
    }

    /// Writes the document back over the file it came from.
    ///
    /// Written to a neighbouring temporary file and swapped in, so an interrupted
    /// write cannot leave you with half a lecture. PDFKit's `write(to:)` on the
    /// live URL truncates first, which is exactly the failure worth avoiding on
    /// a file the app does not own.
    static func save(_ document: PDFDocument, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).ankiflow-write")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // Visible again for the write, hidden again after. Their hidden flag is
        // ours, not yours, and it has no business being in your file.
        restoreHighlights(in: document)
        defer { takeOverHighlights(in: document) }
        guard flattenImageStamps(in: document).write(to: temporary) else {
            throw Failure.writeFailed(url.finderName)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            throw Failure.writeFailed(url.finderName)
        }
    }
}

extension CropRect {
    /// Re-express this rect, normalized against `old`, as a rect normalized
    /// against `new`. Both boxes are in the same page space.
    ///
    /// This is what makes cropping the PDF safe: a mask over the aorta stays
    /// over the aorta instead of becoming a fraction of a smaller page and
    /// landing somewhere else entirely.
    func converted(from old: CGRect, to new: CGRect) -> CropRect {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return self }
        let absolute = rect(in: old)
        return CropRect(rect: absolute, in: new)
    }
}


/// A picture pasted onto a slide.
///
/// PDFKit has no image annotation, so this is a Stamp that draws itself. That
/// is enough to move and resize it like any other mark while you are editing;
/// making it permanent is `PDFEditing.flattenImageStamps`, which runs on the
/// way to disk.
final class PDFImageStamp: PDFAnnotation {
    let image: NSImage

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldDisplay = true
    }

    required init?(coder: NSCoder) {
        self.image = NSImage()
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        var frame = bounds
        guard let picture = image.cgImage(forProposedRect: &frame, context: nil, hints: nil)
        else { return }
        context.saveGState()
        context.draw(picture, in: bounds)
        context.restoreGState()
    }
}
