import AppKit
import PDFKit

/// The mouse and keyboard layer for editing the PDF.
///
/// A sibling view above the crop overlay rather than a `PDFView` subclass, and
/// the same trick the crop overlay uses: with no tool in hand `hitTest` returns
/// nil, so every click falls straight through to PDFKit and the pane behaves
/// exactly as it did before this feature existed.
///
/// What it does, in the order the code below does it:
///
/// - **Select** picks up a mark, draws handles round it, moves it, resizes it,
///   and deletes it on ⌫. Double-clicking a text box types into it in place.
/// - **The drawing tools** create a mark by dragging one out.
/// - Everything goes through `PDFEditSession`, so all of it undoes, and none of
///   it reaches the file until you save.
final class PDFEditOverlayView: NSView, NSTextViewDelegate {
    weak var pdfView: PDFView?
    weak var session: PDFEditSession?

    /// nil means the overlay is inert and invisible to the mouse.
    var tool: PDFEditing.Tool?
    var strokeColour: NSColor = .systemYellow
    var fillColour: NSColor?
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 14
    var fontBold = false
    var fontItalic = false
    var fontUnderline = false
    var findAnnotationHighlight: (PDFPage, CGRect)?

    /// Called when a tool has been used, so a one-shot tool can be put down.
    var onToolUsed: (() -> Void)?
    var onMessage: ((String) -> Void)?

    // Drag state.
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var dragPage: PDFPage?
    private var strokePoints: [NSPoint] = []
    private enum DragKind { case create, move, resize(Handle) }
    private var dragKind: DragKind = .create
    /// The annotation's frame in page space when a move or resize started.
    private var dragOriginalFrame: CGRect = .zero
    /// A sketch's paths as they were when the drag started. Sketches move by
    /// replacement, and this is what the replacement is built from.
    private var dragOriginalPaths: [NSBezierPath] = []
    private var dragMoved = false
    /// The words currently dragged over, while a text-mark tool is in hand.
    private var textSelection: PDFSelection?
    private var copiedAnnotation: PDFAnnotation?

    func clearTextSelection() {
        textSelection = nil
        needsDisplay = true
    }

    func suppressTextAnnotations(_ suppress: Bool) {
        guard let document = pdfView?.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where PDFEditing.kind(of: annotation) == "FreeText" {
                annotation.shouldDisplay = !suppress
            }
        }
        needsDisplay = true
    }

    // In-place text editing.
    private var textEditor: NSTextView?
    private var editingAnnotation: PDFAnnotation?
    private var editingIsNew = false

    private var observing = false
    private let minimumDrag: CGFloat = 5
    private let handleSize: CGFloat = 7

    /// The eight grab points round a selected mark.
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, left, right, topLeft, top, topRight
        /// Where it sits, as a fraction of the frame.
        var anchor: CGPoint {
            switch self {
            case .bottomLeft:  return CGPoint(x: 0, y: 0)
            case .bottom:      return CGPoint(x: 0.5, y: 0)
            case .bottomRight: return CGPoint(x: 1, y: 0)
            case .left:        return CGPoint(x: 0, y: 0.5)
            case .right:       return CGPoint(x: 1, y: 0.5)
            case .topLeft:     return CGPoint(x: 0, y: 1)
            case .top:         return CGPoint(x: 0.5, y: 1)
            case .topRight:    return CGPoint(x: 1, y: 1)
            }
        }
    }

    // MARK: - Staying in step with the page

    func startObservingScroll() {
        guard !observing, let pdfView else { return }
        observing = true
        if let scroller = Self.scrollView(in: pdfView) {
            scroller.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(contentMoved),
                name: NSView.boundsDidChangeNotification, object: scroller.contentView)
        }
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(contentMoved), name: name, object: pdfView)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(pdfSelectionChanged),
            name: Notification.Name.PDFViewSelectionChanged, object: pdfView)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scroller = subview as? NSScrollView { return scroller }
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    /// PDFKit does not repaint when an annotation is changed out from under it,
    /// so anything that adds, removes, moves or retypes a mark has to say so.
    private func refresh() {
        pdfView?.layoutDocumentView()
        needsDisplay = true
    }

    @objc private func contentMoved() {
        // The text editor is positioned in view space, so it has to be moved
        // with the page rather than left floating where the page used to be.
        layoutTextEditor()
        needsDisplay = true
    }

    @objc private func pdfSelectionChanged() {
        guard session?.selection != nil else { return }
        session?.selection = nil
        needsDisplay = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Taking the mouse, but only when asked

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A live text editor must keep its clicks even though it is a subview
        // of an overlay that would otherwise swallow them.
        if let textEditor, textEditor.frame.contains(convert(point, from: superview)) {
            return super.hitTest(point)
        }
        guard let tool, tool.takesMouse else { return nil }
        // Select mode only owns existing marks. Empty page space must remain
        // PDFKit's, otherwise its normal text-selection gesture is swallowed.
        if tool == .select {
            let pagePoint = convert(point, to: pdfView)
            guard let hitPage = pdfView?.page(for: pagePoint, nearest: true),
                  let pageInPoint = pdfView?.convert(pagePoint, to: hitPage),
                  PDFEditing.mark(at: pageInPoint, on: hitPage) != nil else {
                if let selection = session?.selection,
                   let hitPage = pdfView?.page(for: pagePoint, nearest: true),
                   selection.page === hitPage,
                   PDFEditing.isResizable(selection.annotation),
                   handle(at: point, for: selection.annotation, on: hitPage) != nil {
                    return super.hitTest(point)
                }
                return nil
            }
        }
        return super.hitTest(point)
    }

    override var acceptsFirstResponder: Bool { tool?.takesMouse == true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              [7, 8, 9].contains(Int(event.keyCode)) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resetCursorRects() {
        guard let tool, tool.takesMouse else { return }
        addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.keyCode {
            case 8: // C
                guard let session, let selection = session.selection,
                      !["Highlight", "Underline", "StrikeOut"].contains(PDFEditing.kind(of: selection.annotation))
                else { return }
                copiedAnnotation = selection.annotation.copy() as? PDFAnnotation
                return
            case 7: // X
                guard let session, let selection = session.selection,
                      !["Highlight", "Underline", "StrikeOut"].contains(PDFEditing.kind(of: selection.annotation))
                else { return }
                copiedAnnotation = selection.annotation.copy() as? PDFAnnotation
                session.remove(selection.annotation, from: selection.page)
                refresh()
                return
            case 9: // V
                guard let session, let copy = copiedAnnotation,
                      let page = pdfView?.currentPage
                else { return }
                let pasted = copy.copy() as? PDFAnnotation ?? copy
                pasted.shouldDisplay = true
                pasted.bounds = pasted.bounds.offsetBy(dx: 20, dy: -20)
                session.add(pasted, to: page, label: "pasting that mark")
                refresh()
                return
            default:
                break
            }
        }
        let delete = event.keyCode == 51 || event.keyCode == 117   // ⌫ and ⌦
        guard delete, let session, let selection = session.selection else {
            super.keyDown(with: event)
            return
        }

        session.remove(selection.annotation, from: selection.page)
        refresh()
    }

    func toggleFontTrait(_ trait: NSFontTraitMask) -> Bool {
        guard let editor = textEditor else { return false }
        let range = editor.selectedRange()
        let target = range.length == 0 ? NSRange(location: 0, length: editor.string.utf16.count) : range
        guard target.length > 0 else { return false }
        let existing = editor.textStorage?.attribute(.font, at: target.location,
                                                       effectiveRange: nil) as? NSFont
        let hasTrait = existing.map { NSFontManager.shared.traits(of: $0).contains(trait) } ?? false
        let fontManager = NSFontManager.shared
        editor.textStorage?.enumerateAttribute(.font, in: target) { value, subrange, _ in
            let font = (value as? NSFont) ?? editor.font ?? NSFont.systemFont(ofSize: fontSize)
            let currentTraits = font.fontDescriptor.symbolicTraits
            var updatedTraits = currentTraits
            if hasTrait {
                updatedTraits.remove(trait == .boldFontMask ? .bold : .italic)
            } else {
                updatedTraits.insert(trait == .boldFontMask ? .bold : .italic)
            }
            let updated = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(updatedTraits),
                                 size: font.pointSize) ?? fontManager.convert(font, toHaveTrait: trait)
            editor.textStorage?.addAttribute(.font, value: updated, range: subrange)
        }
        if range.length == 0, let annotation = editingAnnotation,
           let font = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            annotation.font = font
        }
        editor.didChangeText()
        editor.setSelectedRange(range)
        refresh()
        return true
    }

    func toggleUnderline() -> Bool {
        guard let editor = textEditor else { return false }
        let range = editor.selectedRange()
        let target = range.length == 0 ? NSRange(location: 0, length: editor.string.utf16.count) : range
        guard target.length > 0 else { return false }
        let existing = editor.textStorage?.attribute(.underlineStyle, at: target.location,
                                                       effectiveRange: nil) as? Int
        let style = (existing ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
        editor.textStorage?.addAttribute(.underlineStyle, value: style, range: target)
        editor.didChangeText()
        editor.setSelectedRange(range)
        refresh()
        return true
    }

    // MARK: - Coordinates

    private func page(at point: NSPoint) -> PDFPage? {
        pdfView?.page(for: convert(point, to: pdfView), nearest: true)
    }

    private func exactPage(at point: NSPoint) -> PDFPage? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let viewPoint = convert(point, to: pdfView)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
            if pageRect.contains(viewPoint) { return page }
        }
        return nil
    }

    private func clampedFrame(_ frame: CGRect, to page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .cropBox)
        var result = frame
        if result.width <= bounds.width {
            result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        } else {
            result.origin.x = bounds.minX
            result.size.width = bounds.width
        }
        if result.height <= bounds.height {
            result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        } else {
            result.origin.y = bounds.minY
            result.size.height = bounds.height
        }
        return result
    }

    private func toPage(_ point: NSPoint, _ page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        return pdfView.convert(convert(point, to: pdfView), to: page)
    }

    private func toView(_ rect: CGRect, _ page: PDFPage) -> NSRect {
        guard let pdfView else { return .zero }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - The drag

    /// Events are pulled off the queue rather than waited for as callbacks:
    /// PDFKit's own tracking swallows `mouseDragged`, so a drag drawn from
    /// callbacks stays zero-sized.
    override func mouseDown(with event: NSEvent) {
        guard let tool, tool.takesMouse, let window else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(at: point) else { return }

        let inPage = toPage(point, page)
        let isHandleHit: Bool = {
            if let current = session?.selection, current.page === page,
               PDFEditing.isResizable(current.annotation),
               handle(at: point, for: current.annotation, on: page) != nil {
                return true
            }
            return false
        }()
        let hitAnnotation = PDFEditing.mark(at: inPage, on: page)

        // In select mode: only intercept if there's an annotation or handle to interact with.
        // Otherwise let the click fall through to PDFKit so the user can select text normally.
        if tool == .select {
            if isHandleHit || hitAnnotation != nil {
                commitTextEditing()
                window.makeFirstResponder(self)
                beginSelectDrag(at: point, on: page, clickCount: event.clickCount)
                // beginSelectDrag always picks something up here, so proceed to drag tracking
            } else {
                // Click on empty space: deselect any annotation and pass through to PDFKit.
                session?.selection = nil
                needsDisplay = true
                return
            }
        } else if isHandleHit || hitAnnotation != nil {
            // Another tool is active but user clicked an existing annotation —
            // select and move/resize it rather than drawing a new one on top.
            commitTextEditing()
            window.makeFirstResponder(self)
            beginSelectDrag(at: point, on: page, clickCount: event.clickCount)
            if case .create = dragKind { return }
        } else {
            // Drawing tool, empty space: create a new mark.
            commitTextEditing()
            window.makeFirstResponder(self)
            session?.selection = nil
            dragKind = .create
        }

        dragPage = page
        dragStart = point
        dragEnd = point
        dragMoved = false
        strokePoints = [point]
        needsDisplay = true

        var last = event
        tracking: while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break tracking }
            last = next
            let here = convert(next.locationInWindow, from: nil)
            if here != dragEnd { dragMoved = true }
            dragEnd = here
            if tool == .pen { strokePoints.append(here) }
            if tool.textMark != nil, let page = dragPage, let from = dragStart {
                textSelection = page.selection(from: toPage(from, page), to: toPage(here, page))
            }
            applyLiveDrag()
            needsDisplay = true
            displayIfNeeded()
            if next.type == .leftMouseUp { break tracking }
        }
        finishDrag(with: last)
    }

    /// Work out what a click with the Select tool is starting.
    private func beginSelectDrag(at point: NSPoint, on page: PDFPage, clickCount: Int) {
        guard let session else { return }
        let inPage = toPage(point, page)

        // A handle on the current selection wins over anything underneath it.
        if let current = session.selection, current.page === page,
           PDFEditing.isResizable(current.annotation),
           let handle = handle(at: point, for: current.annotation, on: page) {
            dragKind = .resize(handle)
            dragOriginalFrame = PDFEditing.frame(of: current.annotation)
            return
        }

        guard let hit = PDFEditing.mark(at: inPage, on: page) else {
            session.selection = nil
            dragKind = .create           // read by the caller as "nothing here"
            needsDisplay = true
            return
        }

        if session.selection?.annotation !== hit {
            session.selection = PDFEditSession.Selection(annotation: hit, page: page)
        }
        if clickCount >= 2, PDFEditing.kind(of: hit) == "FreeText" {
            beginTextEditing(hit, on: page, isNew: false)
            dragKind = .create
            dragPage = nil
            return
        }
        dragKind = .move
        dragOriginalFrame = PDFEditing.frame(of: hit)
        dragOriginalPaths = PDFEditing.isSketch(hit) ? (hit.paths ?? []) : []
    }

    private func handle(at point: NSPoint, for annotation: PDFAnnotation, on page: PDFPage) -> Handle? {
        let frame = toView(PDFEditing.frame(of: annotation), page)
        for handle in Handle.allCases where handleRect(handle, in: frame).contains(point) {
            return handle
        }
        return nil
    }

    private func handleRect(_ handle: Handle, in frame: NSRect) -> NSRect {
        let anchor = handle.anchor
        let centre = NSPoint(x: frame.minX + frame.width * anchor.x,
                             y: frame.minY + frame.height * anchor.y)
        return NSRect(x: centre.x - handleSize / 2, y: centre.y - handleSize / 2,
                      width: handleSize, height: handleSize).insetBy(dx: -2, dy: -2)
    }

    /// Move and resize are shown live by actually changing the annotation --
    /// PDFKit redraws it, so there is nothing to draw here and no chance of the
    /// preview and the result disagreeing. The undo step is recorded once, on
    /// mouse up, from the frame the drag started with.
    private func applyLiveDrag() {
        guard let session, let selection = session.selection,
              let page = dragPage, let start = dragStart, let end = dragEnd else { return }
        guard exactPage(at: end) === page else { return }
        let from = toPage(start, page)
        let to = toPage(end, page)

        switch dragKind {
        case .move:
            if ["Highlight", "Underline", "StrikeOut"].contains(PDFEditing.kind(of: selection.annotation)) {
                return
            }
            // A sketch is moved once, on mouse up, by building a shifted copy.
            // Doing that on every mouse event would churn a new annotation per
            // pixel of travel.
            guard !PDFEditing.isSketch(selection.annotation) else { return }
            let current = PDFEditing.frame(of: selection.annotation)
            let wanted = clampedFrame(
                dragOriginalFrame.offsetBy(dx: to.x - from.x, dy: to.y - from.y),
                to: page)
            PDFEditing.move(selection.annotation,
                            by: CGSize(width: wanted.minX - current.minX,
                                       height: wanted.minY - current.minY))
            pdfView?.layoutDocumentView()
        case .resize(let handle):
            selection.annotation.bounds = clampedFrame(
                resized(dragOriginalFrame, handle: handle,
                        by: CGSize(width: to.x - from.x,
                                   height: to.y - from.y)),
                to: page)
        case .create:
            break
        }
    }

    private func resized(_ frame: CGRect, handle: Handle, by delta: CGSize) -> CGRect {
        var rect = frame
        let anchor = handle.anchor
        if anchor.x == 0 { rect.origin.x += delta.width; rect.size.width -= delta.width }
        if anchor.x == 1 { rect.size.width += delta.width }
        if anchor.y == 0 { rect.origin.y += delta.height; rect.size.height -= delta.height }
        if anchor.y == 1 { rect.size.height += delta.height }
        // Never inside-out, and never so small it cannot be grabbed again.
        return CGRect(x: min(rect.minX, rect.maxX - 8), y: min(rect.minY, rect.maxY - 8),
                      width: max(abs(rect.width), 8), height: max(abs(rect.height), 8))
    }

    private func clearDrag() {
        dragStart = nil
        dragEnd = nil
        dragPage = nil
        strokePoints = []
        dragOriginalPaths = []
        textSelection = nil
        needsDisplay = true
    }

    private func finishDrag(with event: NSEvent) {
        defer { clearDrag() }
        guard let tool, let session, let page = dragPage, let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let viewRect = rect(from: start, to: end)
        let number = (pdfView?.document?.index(for: page) ?? 0) + 1

        // A move or resize was applied live; all that is left is to record it.
        let from = toPage(start, page)
        let to = toPage(end, page)

        switch dragKind {
        case .move where dragMoved:
            guard let selection = session.selection else { return }
            let annotation = selection.annotation
            let targetFrame = clampedFrame(
                dragOriginalFrame.offsetBy(dx: to.x - from.x, dy: to.y - from.y),
                to: page)
            let delta = CGSize(width: targetFrame.minX - dragOriginalFrame.minX,
                               height: targetFrame.minY - dragOriginalFrame.minY)

            if PDFEditing.isSketch(annotation) {
                // Swap in a shifted copy. Undo swaps the original back, which is
                // exact -- no arithmetic to get wrong and nothing accumulated
                // over a drag's worth of mouse events.
                let moved = PDFEditing.translated(annotation, paths: dragOriginalPaths,
                                                  by: delta, on: page)
                // The selection has to travel with the swap. Left pointing at
                // the copy, an undo would draw the dashed outline where the
                // sketch used to be and ⌫ would delete an annotation that is no
                // longer on the page.
                session.perform("moving that sketch",
                                undo: { [weak session] in
                                    moved.shouldDisplay = false
                                    page.removeAnnotation(moved)
                                    annotation.shouldDisplay = true
                                    page.addAnnotation(annotation)
                                    session?.selection = PDFEditSession.Selection(
                                        annotation: annotation, page: page)
                                },
                                redo: { [weak session] in
                                    annotation.shouldDisplay = false
                                    page.removeAnnotation(annotation)
                                    moved.shouldDisplay = true
                                    page.addAnnotation(moved)
                                    session?.selection = PDFEditSession.Selection(
                                        annotation: moved, page: page)
                                })
            } else {
                // Already applied live. `record`, not `perform` -- replaying it
                // on the way in would move it twice.
                let back = CGSize(width: -delta.width, height: -delta.height)
                session.record("moving that mark",
                               undo: { PDFEditing.move(annotation, by: back) },
                               redo: { PDFEditing.move(annotation, by: delta) })
            }
            refresh()
            return

        case .resize where dragMoved:
            guard let selection = session.selection else { return }
            let annotation = selection.annotation
            let now = annotation.bounds
            let before = dragOriginalFrame
            session.record("resizing that mark",
                           undo: { annotation.bounds = before },
                           redo: { annotation.bounds = now })
            refresh()
            return

        case .move, .resize:
            return                                   // a click that did not move
        case .create:
            break
        }

        // A text mark is applied to whatever the drag ran over. One undo step
        // for the lot: a sentence marked across three lines is one thing you
        // did, not three.
        if let mark = tool.textMark {
            let made = PDFEditing.marks(for: textSelection, kind: mark, colour: strokeColour)
            guard !made.isEmpty else {
                onMessage?("Drag across some words to \(mark.label.lowercased()) them.")
                return
            }
            session.perform("that \(mark.label.lowercased())",
                            undo: {
                                for (annotation, page) in made {
                                    annotation.shouldDisplay = false
                                    page.removeAnnotation(annotation)
                                }
                            },
                            redo: {
                                for (annotation, page) in made {
                                    annotation.shouldDisplay = true
                                    page.addAnnotation(annotation)
                                }
                            })
            refresh()
            return
        }

        switch tool {
        case .pen:
            let points = strokePoints.map { toPage($0, page) }
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            session.add(PDFEditing.stroke(path, colour: strokeColour, width: lineWidth, on: page),
                        to: page, label: "that sketch")

        case .line, .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= minimumDrag else { return }
            session.add(PDFEditing.line(from: from, to: to, arrow: tool == .arrow,
                                        colour: strokeColour, width: lineWidth, on: page),
                        to: page, label: tool == .arrow ? "that arrow" : "that line")

        case .rectangle, .oval:
            guard viewRect.width >= minimumDrag, viewRect.height >= minimumDrag else { return }
            guard let shape = PDFEditing.shape(tool, in: rect(from: from, to: to),
                                               stroke: strokeColour, fill: fillColour,
                                               width: lineWidth) else { return }
            session.add(shape, to: page, label: tool == .oval ? "that oval" : "that rectangle")

        case .text:
            let size = CGSize(width: 220, height: 46)
            let boxRect = CGRect(x: from.x, y: from.y, width: size.width, height: size.height)
            let box = PDFEditing.textBox(in: boxRect,
                                         colour: strokeColour, size: fontSize)
            session.add(box, to: page, label: "that text")
            // Straight into typing, in place. A sheet asking for the words
            // would put a modal window between you and the slide you are
            // annotating, which is not how anyone marks up a page.
            beginTextEditing(box, on: page, isNew: true)

        case .trim:
            guard viewRect.width >= minimumDrag, viewRect.height >= minimumDrag else { return }
            // Through the session, so it is undoable and waits for ⌘S like every
            // other edit. It used to write the file on the spot, which made Trim
            // the one tool that could not be taken back.
            session.trim(page, to: rect(from: from, to: to).intersection(page.bounds(for: .mediaBox)),
                         label: "trimming slide \(number)")

        case .select, .highlight, .underline, .strikeOut:
            break
        }
        refresh()
        onToolUsed?()
    }

    // MARK: - Typing into a text box

    func beginTextEditing(_ annotation: PDFAnnotation, on page: PDFPage, isNew: Bool) {
        commitTextEditing()
        guard let pdfView else { return }
        editingAnnotation = annotation
        editingIsNew = isNew

        let editor = NSTextView(frame: toView(annotation.bounds, page))
        if let richText = PDFEditing.richText(for: annotation) {
            editor.textStorage?.setAttributedString(richText)
        } else {
            editor.string = annotation.contents ?? ""
        }
        if PDFEditing.richText(for: annotation) == nil {
            editor.font = currentFont(size: fontSize * pdfView.scaleFactor)
            editor.textColor = annotation.fontColor ?? strokeColour
        }
        editor.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        editor.isRichText = true
        editor.typingAttributes[.underlineStyle] = fontUnderline ? NSUnderlineStyle.single.rawValue : 0
        editor.delegate = self
        editor.textContainerInset = NSSize(width: 2, height: 2)
        editor.wantsLayer = true
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = strokeColour.cgColor
        editor.layer?.cornerRadius = 3
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        needsDisplay = true
    }

    private func currentFont(size: CGFloat) -> NSFont {
        PDFEditing.textFont(size: size, bold: fontBold, italic: fontItalic)
    }

    private func layoutTextEditor() {
        guard let textEditor, let annotation = editingAnnotation,
              let page = annotation.page else { return }
        textEditor.frame = toView(annotation.bounds, page)
    }

    /// Write the words back through the undo stack and put the editor away.
    func commitTextEditing() {
        // Deliberately not guarded on `session`. It is weak, and leaving editing
        // clears the app's only strong reference *before* this runs -- guarding
        // on it left a half-typed note floating over a pane that was no longer
        // in edit mode, with its text lost.
        guard let editor = textEditor, let annotation = editingAnnotation else { return }
        let text = editor.string
        let attributedText = editor.attributedString()
        if let font = attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            annotation.font = font
        }
        let textBounds = attributedText.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let fittedSize = CGSize(width: max(24, ceil(textBounds.width) + 8),
                                height: max(24, ceil(textBounds.height) + 8))
        let oldBounds = annotation.bounds
        annotation.bounds = CGRect(origin: oldBounds.origin, size: fittedSize)
        let wasNew = editingIsNew
        textEditor = nil
        editingAnnotation = nil
        editingIsNew = false
        editor.removeFromSuperview()

        guard let session else { refresh(); return }
        if wasNew, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A text box nobody typed into is an invisible annotation on the
            // page. Thrown away rather than undone, so ⇧⌘U cannot bring an
            // empty one back.
            session.discardLastStep()
            refresh()
            return
        }
        // Merged with the step that created the box: drawing it and typing into
        // it was one action, so it should take one ⌘U.
        session.setAttributedString(attributedText, on: annotation, mergeWithLast: wasNew)
        refresh()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }

    override func cancelOperation(_ sender: Any?) {
        if textEditor != nil {
            commitTextEditing()
        } else if session?.selection != nil {
            session?.selection = nil
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawFlags()
        drawTextMarks()
        drawTextBoxes()
        drawFindAnnotationHighlight()
        drawSelection()
        drawLiveDrag()
    }

    private func drawTextBoxes() {
        guard let pdfView else { return }
        for page in pdfView.visiblePages {
            for annotation in page.annotations
            where PDFEditing.kind(of: annotation) == "FreeText" &&
                  annotation.shouldDisplay == false {
                guard let text = annotation.contents, !text.isEmpty else { continue }
                let rect = toView(annotation.bounds, page).insetBy(dx: 2, dy: 2)
                if let fill = annotation.interiorColor {
                    fill.setFill()
                    rect.fill()
                }
                let attributed = PDFEditing.richText(for: annotation)
                    ?? NSAttributedString(string: text, attributes: [
                        .font: annotation.font ?? NSFont.systemFont(ofSize: 14),
                        .foregroundColor: annotation.fontColor ?? NSColor.labelColor
                    ])
                attributed.draw(in: rect)
            }
        }
    }

    private func drawFindAnnotationHighlight() {
        guard let (page, bounds) = findAnnotationHighlight,
              pdfView?.visiblePages.contains(where: { $0 === page }) == true else { return }
        let rect = toView(bounds, page)
        NSColor.systemYellow.withAlphaComponent(0.3).setFill()
        rect.fill()
    }

    private func drawTextMarks() {
        guard let pdfView else { return }
        for page in pdfView.visiblePages {
            for annotation in page.annotations {
                let kind = PDFEditing.kind(of: annotation)
                guard kind == "Highlight" || kind == "Underline" || kind == "StrikeOut" else { continue }
                let rect = toView(annotation.bounds, page)
                let colour = annotation.color
                switch kind {
                case "Highlight":
                    colour.withAlphaComponent(0.42).setFill()
                    rect.fill()
                case "Underline", "StrikeOut":
                    colour.setStroke()
                    let path = NSBezierPath()
                    let y = kind == "Underline" ? rect.minY + 2 : rect.midY
                    path.move(to: NSPoint(x: rect.minX, y: y))
                    path.line(to: NSPoint(x: rect.maxX, y: y))
                    path.lineWidth = 2
                    path.stroke()
                default: break
                }
            }
        }
    }

    private func drawFlags() {
        guard let pdfView, pdfView.document != nil else { return }
        for page in pdfView.visiblePages {
            guard page.annotations.contains(where: PDFEditing.isFlag) else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            let markerBounds = CGRect(x: pageBounds.minX + 8,
                                      y: pageBounds.maxY - 42,
                                      width: 30, height: 30)
            let rect = toView(markerBounds, page)
            NSColor.systemBlue.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.25))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.close()
            path.fill()
        }
    }

    private func drawSelection() {
        guard let session, let selection = session.selection,
              textEditor == nil else { return }
        let frame = toView(PDFEditing.frame(of: selection.annotation), selection.page)

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

        guard PDFEditing.isResizable(selection.annotation) else { return }
        for handle in Handle.allCases {
            let rect = handleRect(handle, in: frame).insetBy(dx: 2, dy: 2)
            NSColor.white.setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawLiveDrag() {
        guard let tool, case .create = dragKind,
              let start = dragStart, let end = dragEnd else { return }

        switch tool {
        case .pen:
            guard strokePoints.count > 1 else { return }
            strokeColour.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth * (pdfView?.scaleFactor ?? 1)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: strokePoints[0])
            for point in strokePoints.dropFirst() { path.line(to: point) }
            path.stroke()

        case .line, .arrow:
            strokeColour.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth * (pdfView?.scaleFactor ?? 1)
            path.move(to: start)
            path.line(to: end)
            path.stroke()

        case .rectangle, .oval, .text:
            let live = rect(from: start, to: end)
            if let fillColour, tool != .text {
                fillColour.withAlphaComponent(0.35).setFill()
                (tool == .oval ? NSBezierPath(ovalIn: live) : NSBezierPath(rect: live)).fill()
            }
            strokeColour.setStroke()
            let path = tool == .oval ? NSBezierPath(ovalIn: live) : NSBezierPath(rect: live)
            path.lineWidth = tool == .text ? 1.5 : lineWidth * (pdfView?.scaleFactor ?? 1)
            if tool == .text { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()

        case .trim:
            // The same dim-everything-outside affordance the question crop uses,
            // because it is the same gesture -- except this one throws the
            // outside away.
            let live = rect(from: start, to: end)
            NSColor.black.withAlphaComponent(0.45).setFill()
            for band in bounds.bands(around: live) { band.fill() }
            strokeColour.setStroke()
            let path = NSBezierPath(rect: live)
            path.lineWidth = 1.5
            path.stroke()

        case .select:
            break

        case .highlight, .underline, .strikeOut:
            guard let selection = textSelection, let page = dragPage else { return }
            strokeColour.withAlphaComponent(0.45).setFill()
            for line in selection.selectionsByLine() {
                let rect = toView(line.bounds(for: page), page)
                guard rect.width > 1, rect.height > 1 else { continue }
                rect.fill()
            }
        }
    }
}
