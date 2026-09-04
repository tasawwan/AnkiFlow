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
            throw Failure.notAPDF(url.lastPathComponent)
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
        guard inserted > 0 else { throw Failure.notAPDF(url.lastPathComponent) }

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
        /// The three text marks are modes, not one-shot buttons: pick one up and
        /// every stretch of text you drag over gets marked, which is how you get
        /// through a slide rather than selecting-then-clicking each time.
        case highlight
        case underline
        case strikeOut
        case pen
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
            case .highlight:  return "Highlight"
            case .underline:  return "Underline"
            case .strikeOut:  return "Strikethrough"
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
            case .highlight:  return "highlighter"
            case .underline:  return "underline"
            case .strikeOut:  return "strikethrough"
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
            case .highlight:  return "Drag across text to highlight it"
            case .underline:  return "Drag across text to underline it"
            case .strikeOut:  return "Drag across text to strike it through"
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
        /// The text marks and Select stay in your hand; a shape does not, so the
        /// thing you just drew can be moved without going and finding a pointer.
        var isOneShot: Bool {
            switch self {
            case .select, .highlight, .underline, .strikeOut: return false
            default: return true
            }
        }

        /// Shapes and text are drawn by dragging a rectangle out.
        var drawsRectangle: Bool {
            self == .rectangle || self == .oval || self == .text || self == .trim
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
        var made: [(annotation: PDFAnnotation, page: PDFPage)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: kind.subtype,
                                               withProperties: nil)
                annotation.color = colour
                // PDFKit expects the quadrilateral in perimeter order.
                let p1 = CGPoint(x: bounds.minX, y: bounds.maxY)
                let p2 = CGPoint(x: bounds.maxX, y: bounds.maxY)
                let p3 = CGPoint(x: bounds.minX, y: bounds.minY)
                let p4 = CGPoint(x: bounds.maxX, y: bounds.minY)
                annotation.quadrilateralPoints = [NSValue(point: p1), NSValue(point: p2), NSValue(point: p3), NSValue(point: p4)]
                annotation.shouldDisplay = true
                made.append((annotation, page))
            }

        }
        return made
    }

    static func flag(on page: PDFPage) -> PDFAnnotation {
        let bounds = page.bounds(for: .cropBox)
        let marker = PDFAnnotation(bounds: page.bounds(for: .mediaBox),
                                   forType: .ink, withProperties: nil)
        marker.contents = flagKey
        marker.color = .systemBlue
        let path = NSBezierPath()
        let x = bounds.minX + 8
        let y = bounds.maxY - 42
        path.move(to: CGPoint(x: x, y: y + 30))
        path.line(to: CGPoint(x: x + 30, y: y + 30))
        path.line(to: CGPoint(x: x + 30, y: y))
        path.line(to: CGPoint(x: x + 15, y: y + 8))
        path.line(to: CGPoint(x: x, y: y))
        path.close()
        marker.add(path)
        let border = PDFBorder()
        border.lineWidth = 4
        marker.border = border
        return marker
    }

    nonisolated static func isFlag(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents == flagKey
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
            break
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
        for path in paths {
            guard let moved = path.copy() as? NSBezierPath else { continue }
            moved.transform(using: transform)
            copy.add(moved)
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
        page.annotations.last { annotation in
            guard !isFlag(annotation) else { return false }
            if kind(of: annotation) == "Ink", let paths = annotation.paths, !paths.isEmpty {
                let origin = annotation.bounds.origin
                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                return paths.contains {
                    near($0, point: point, tolerance: tolerance)
                        || near($0, point: local, tolerance: tolerance)
                }
            }
            return frame(of: annotation).insetBy(dx: -2, dy: -2).contains(point)
        }
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

        guard document.write(to: temporary) else {
            throw Failure.writeFailed(url.lastPathComponent)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            throw Failure.writeFailed(url.lastPathComponent)
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
