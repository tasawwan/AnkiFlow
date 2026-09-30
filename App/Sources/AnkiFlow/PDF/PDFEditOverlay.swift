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
    /// What the current eraser sweep has picked up. Nothing is taken off the
    /// page until you let go -- while the sweep is running these are only
    /// faded, so you can see what is about to go and slide off it if it is not
    /// what you meant.
    private struct Doomed {
        let annotation: PDFAnnotation
        let page: PDFPage
        let colour: NSColor
        let interior: NSColor?
    }
    private var doomed: [Doomed] = []
    /// A sweep commits to one class of mark. See `PDFEditing.EraseClass`.
    private var sweepClass: PDFEditing.EraseClass?
    private let eraserRadius: CGFloat = 9
    private var copiedChangeCount = -1
    /// `pinned` is a selection that does not move. A text mark belongs to the
    /// words underneath it, and a highlight you can slide off its sentence is a
    /// highlight that will eventually be sitting on the wrong one.
    private enum DragKind { case create, move, resize(Handle), pinned }
    private var dragKind: DragKind = .create
    /// The annotation's frame in page space when a move or resize started.
    private var dragOriginalFrame: CGRect = .zero
    private var dragOriginalBounds: [ObjectIdentifier: CGRect] = [:]
    private var dragOriginalFrames: [ObjectIdentifier: CGRect] = [:]
    private struct GeometrySnapshot {
        let bounds: CGRect
        let paths: [NSBezierPath]
        let lineStart: CGPoint?
        let lineEnd: CGPoint?
    }
    private var dragOriginalGeometry: [ObjectIdentifier: GeometrySnapshot] = [:]
    /// A sketch's paths as they were when the drag started. Sketches move by
    /// replacement, and this is what the replacement is built from.
    private var dragOriginalPaths: [NSBezierPath] = []
    private var dragMoved = false
    /// The words currently dragged over, while a text-mark tool is in hand.
    private var textSelection: PDFSelection?
    private var copiedAnnotation: PDFAnnotation?

    func clearTextSelection() {
        textSelection = nil
        // The view's selection too. It is what a toolbar click reads, and
        // nothing else clears it -- the overlay is in front, so PDFKit never
        // sees the clicks that would normally end a selection.
        pdfView?.setCurrentSelection(nil, animate: false)
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
    /// The grip as it is drawn.
    private let handleSize: CGFloat = 7
    /// The grip as it is aimed at. A 7-point square is accurate to hit with a
    /// trackpad only if you are willing to try twice, which is most of what
    /// "I can't resize this" turns out to mean.
    private let handleGrab: CGFloat = 18

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

        /// What the pointer turns into over this grip. macOS has no public
        /// diagonal resize cursor before 15, so a corner gets the crosshair --
        /// "a grab point is here" rather than a lie about which way it goes.
        var cursor: NSCursor {
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default:            return .crosshair
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
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    @objc private func contentMoved() {
        window?.invalidateCursorRects(for: self)
        // The text editor is positioned in view space, so it has to be moved
        // with the page rather than left floating where the page used to be.
        layoutTextEditor()
        needsDisplay = true
    }

    @objc private func pdfSelectionChanged() {
        guard let session, session.selections.isEmpty else { return }
        guard session.selection != nil else { return }
        session.selection = nil
        needsDisplay = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Taking the mouse, but only when asked

    /// True while the crop control in the chip row is lit.
    var isCropping = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A live text editor takes the whole page, not just its own frame.
        //
        // Inside the box, `super` finds the editor and the click goes to it as a
        // subview would expect. Outside it, the overlay answers -- and that is
        // the point: Text is a one-shot tool, so by the time you are typing the
        // tool has already flipped back to Select, and Select deliberately hands
        // empty page space to PDFKit. The click that was meant to put the box
        // down went to the PDF view, which does not take first responder, so
        // nothing ended the editing and the box would not let go of you.
        if textEditor != nil { return super.hitTest(point) }
        // ⌥ means crop, tool or no tool. It used to mean crop only when no tool
        // was in your hand, so cropping a slide for a card meant leaving edit
        // mode, cropping, and going back in -- for a modifier whose whole point
        // is that it needs no mode.
        if NSEvent.modifierFlags.contains(.option) { return nil }
        // And an explicit crop, started from the chip row, outranks everything:
        // you asked for a crop, so the next drag is one.
        if isCropping { return nil }
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
        // Only while this overlay actually has focus. AppKit offers a key
        // equivalent to every view in the key window, so without this the markup
        // overlay answered for ⌘X, ⌘C and ⌘V everywhere -- including in the
        // notes editor, where copy and paste silently did nothing because the
        // overlay had swallowed the key and had no annotation to act on.
        guard window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              [7, 8, 9].contains(Int(event.keyCode)) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resetCursorRects() {
        guard let tool, tool.takesMouse else { return }
        addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair)
        // The grips, after the whole-view rect so they win where they overlap.
        // Without this there was nothing at all to tell you a corner was live,
        // and a grip you cannot see is a grip you hunt for.
        guard tool == .select, let session else { return }
        if session.selections.count > 1,
           let page = session.selections.first?.page,
           let group = selectionFrame(session.selections, on: page) {
            addGripCursors(in: toView(group, page), for: [.bottomRight])
        } else if let selection = session.selection,
                  PDFEditing.isResizable(selection.annotation) {
            addGripCursors(in: toView(PDFEditing.frame(of: selection.annotation), selection.page),
                           for: Handle.allCases)
        }
    }

    private func addGripCursors(in frame: NSRect, for handles: [Handle]) {
        let reach = grabReach(in: frame)
        for handle in handles {
            addCursorRect(centred(handle, in: frame, size: reach), cursor: handle.cursor)
        }
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.keyCode {
            case 8: // C
                guard let session, let selection = session.selection,
                      !["Highlight", "Underline", "StrikeOut"].contains(PDFEditing.kind(of: selection.annotation))
                else { return }
                copiedAnnotation = PDFEditing.duplicate(selection.annotation)
                copiedChangeCount = NSPasteboard.general.changeCount
                return
            case 7: // X
                guard let session, let selection = session.selection,
                      !["Highlight", "Underline", "StrikeOut"].contains(PDFEditing.kind(of: selection.annotation))
                else { return }
                copiedAnnotation = PDFEditing.duplicate(selection.annotation)
                copiedChangeCount = NSPasteboard.general.changeCount
                session.remove(selection.annotation, from: selection.page)
                refresh()
                return
            case 9: // V
                guard let session, let page = pdfView?.currentPage else { return }
                // A picture copied anywhere else on the Mac wins over a mark
                // copied in here, judged by the pasteboard moving on since the
                // last ⌘C -- copying a mark never touches the system pasteboard,
                // so a newer changeCount means the picture is the newer thing.
                let board = NSPasteboard.general
                if board.changeCount != copiedChangeCount,
                   let picture = (board.readObjects(forClasses: [NSImage.self]) as? [NSImage])?
                       .first(where: { $0.size.width > 0 && $0.size.height > 0 }) {
                    let stamp = PDFEditing.imageStamp(picture, on: page)
                    session.add(stamp, to: page, label: "pasting that picture")
                    onMessage?("Pasted — drag it to move it, or a corner to resize.")
                    refresh()
                    return
                }
                guard let copy = copiedAnnotation,
                      let pasted = PDFEditing.duplicate(copy) else { return }
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
        guard delete, let session else {
            super.keyDown(with: event)
            return
        }
        let selected = session.selections.isEmpty
            ? session.selection.map { [$0] } ?? []
            : session.selections
        let pages = session.pages
        session.perform(selected.count == 1 ? "deleting that mark" : "deleting those marks",
                       undo: {
                           for item in selected {
                               item.annotation.shouldDisplay = true
                               pages.add(item.annotation, to: item.page)
                           }
                       },
                       redo: {
                           for item in selected {
                               item.annotation.shouldDisplay = false
                               pages.remove(item.annotation, from: item.page)
                           }
                       })
        session.selections = []
        session.selection = nil
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

        // Any click that is not inside the box you are typing in puts it down,
        // decided once, here, before anything below can return early. Each
        // branch used to remember this for itself, and the two that return
        // without drawing -- empty space in Select, a point off any page --
        // did not.
        let wasEditing = textEditor != nil
        if wasEditing {
            commitTextEditing()
            window.makeFirstResponder(self)
        }

        guard let page = page(at: point) else { return }

        let inPage = toPage(point, page)
        let isHandleHit: Bool = {
            if let session, session.selections.count > 1,
               let group = selectionFrame(session.selections, on: page),
               groupHandle(at: point, for: group, on: page) != nil {
                return true
            }
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
        } else if tool == .lasso {
            let selectedHit = session?.selections.contains {
                $0.page === page && PDFEditing.frame(of: $0.annotation).contains(inPage)
            } == true
            let groupHit = session.flatMap { selectionFrame($0.selections, on: page)?.contains(inPage) } == true
            if selectedHit || groupHit || isHandleHit {
                commitTextEditing()
                window.makeFirstResponder(self)
                beginSelectDrag(at: point, on: page, clickCount: event.clickCount)
            } else {
                commitTextEditing()
                window.makeFirstResponder(self)
                session?.selection = nil
                session?.selections = []
                dragKind = .create
            }
        } else if !tool.paintsOverMarks, isHandleHit || hitAnnotation != nil {
            // Another tool is active but user clicked an existing annotation —
            // select and move/resize it rather than drawing a new one on top.
            // The painting modes are exempt: they stay in your hand, so a press
            // over a mark has to keep painting rather than pick that mark up.
            commitTextEditing()
            window.makeFirstResponder(self)
            beginSelectDrag(at: point, on: page, clickCount: event.clickCount)
            if case .create = dragKind { return }
        } else {
            // Drawing tool, empty space: create a new mark -- unless this click
            // is letting go of something, in which case letting go is all it
            // does. Clicking away from the text box you were typing in used to
            // close it *and* stamp a new one where you clicked, so getting rid
            // of a text box left you with another text box.
            let dismissing = wasEditing
                || (tool == .text && session?.selection != nil)
            window.makeFirstResponder(self)
            session?.selection = nil
            needsDisplay = true
            if dismissing { return }
            dragKind = .create
        }

        dragPage = page
        dragStart = point
        dragEnd = point
        dragMoved = false
        strokePoints = [point]
        doomed = []
        sweepClass = nil
        needsDisplay = true

        var last = event
        tracking: while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break tracking }
            last = next
            let here = convert(next.locationInWindow, from: nil)
            if here != dragEnd { dragMoved = true }
            dragEnd = here
            if tool.drawsStroke || tool == .lasso { strokePoints.append(here) }
            if tool == .eraser { markForErasing(at: here) }
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

        if session.selections.count > 1,
           let group = selectionFrame(session.selections, on: page),
           groupHandle(at: point, for: group, on: page) != nil {
            dragKind = .resize(.bottomRight)
            dragOriginalFrame = group
            dragOriginalBounds = Dictionary(uniqueKeysWithValues: session.selections.map {
                (ObjectIdentifier($0.annotation), $0.annotation.bounds)
            })
            dragOriginalFrames = Dictionary(uniqueKeysWithValues: session.selections.map {
                (ObjectIdentifier($0.annotation), PDFEditing.frame(of: $0.annotation))
            })
            captureGeometry(for: session.selections)
            return
        }
        if session.selections.count > 1,
           let group = selectionFrame(session.selections, on: page),
           group.contains(inPage) {
            dragKind = .move
            dragOriginalFrame = group
            dragOriginalBounds = Dictionary(uniqueKeysWithValues: session.selections.map {
                (ObjectIdentifier($0.annotation), $0.annotation.bounds)
            })
            dragOriginalFrames = Dictionary(uniqueKeysWithValues: session.selections.map {
                (ObjectIdentifier($0.annotation), PDFEditing.frame(of: $0.annotation))
            })
            captureGeometry(for: session.selections)
            return
        }

        // A handle on the current selection wins over anything underneath it.
        if let current = session.selection, current.page === page,
           PDFEditing.isResizable(current.annotation),
           let handle = handle(at: point, for: current.annotation, on: page) {
            dragKind = .resize(handle)
            dragOriginalFrame = PDFEditing.frame(of: current.annotation)
            dragOriginalBounds = [ObjectIdentifier(current.annotation): current.annotation.bounds]
            dragOriginalFrames = [ObjectIdentifier(current.annotation): PDFEditing.frame(of: current.annotation)]
            captureGeometry(for: [current])
            return
        }

        guard let hit = PDFEditing.mark(at: inPage, on: page) else {
            session.selection = nil
            dragKind = .create           // read by the caller as "nothing here"
            needsDisplay = true
            return
        }

        // One line of a marked sentence means the whole sentence.
        if let group = PDFEditing.markGroup(of: hit) {
            let family = page.annotations
                .filter { PDFEditing.markGroup(of: $0) == group }
                .map { PDFEditSession.Selection(annotation: $0, page: page) }
            session.selection = PDFEditSession.Selection(annotation: hit, page: page)
            session.selections = family
            dragKind = .pinned
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
        dragOriginalBounds = [ObjectIdentifier(hit): hit.bounds]
        dragOriginalFrames = [ObjectIdentifier(hit): PDFEditing.frame(of: hit)]
        captureGeometry(for: [PDFEditSession.Selection(annotation: hit, page: page)])
    }

    private func handle(at point: NSPoint, for annotation: PDFAnnotation, on page: PDFPage) -> Handle? {
        handle(at: point, for: PDFEditing.frame(of: annotation), on: page)
    }

    private func handle(at point: NSPoint, for frame: CGRect, on page: PDFPage) -> Handle? {
        nearestHandle(at: point, in: toView(frame, page), among: Handle.allCases)
    }

    private func groupHandle(at point: NSPoint, for frame: CGRect, on page: PDFPage) -> Handle? {
        nearestHandle(at: point, in: toView(frame, page), among: [.bottomRight])
    }

    /// The closest grip under the pointer, rather than the first one that
    /// happens to contain it.
    ///
    /// With a grab area wide enough to aim at, neighbouring grips overlap on a
    /// small mark, and taking the first match meant the bottom-left corner
    /// answered for the whole thing.
    private func nearestHandle(at point: NSPoint, in frame: NSRect,
                               among handles: [Handle]) -> Handle? {
        let reach = grabReach(in: frame)
        var best: (handle: Handle, distance: CGFloat)?
        for handle in handles {
            let rect = centred(handle, in: frame, size: reach)
            guard rect.contains(point) else { continue }
            let distance = hypot(point.x - rect.midX, point.y - rect.midY)
            if let current = best, distance >= current.distance { continue }
            best = (handle, distance)
        }
        return best?.handle
    }

    /// How far from a grip counts as grabbing it, given how big the mark is.
    ///
    /// Shrinks on a small mark so that the middle of it is still middle -- a
    /// box 20 points across that is entirely grip cannot be dragged anywhere.
    private func grabReach(in frame: NSRect) -> CGFloat {
        min(handleGrab, max(handleSize, min(frame.width, frame.height) / 2.5))
    }

    private func selectionFrame(_ selections: [PDFEditSession.Selection], on page: PDFPage) -> CGRect? {
        let frames = selections.filter { $0.page === page }.map { PDFEditing.frame(of: $0.annotation) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func handleRect(_ handle: Handle, in frame: NSRect) -> NSRect {
        centred(handle, in: frame, size: handleSize)
    }

    private func centred(_ handle: Handle, in frame: NSRect, size: CGFloat) -> NSRect {
        let anchor = handle.anchor
        let centre = NSPoint(x: frame.minX + frame.width * anchor.x,
                             y: frame.minY + frame.height * anchor.y)
        return NSRect(x: centre.x - size / 2, y: centre.y - size / 2,
                      width: size, height: size)
    }

    /// Move and resize are shown live by actually changing the annotation --
    /// PDFKit redraws it, so there is nothing to draw here and no chance of the
    /// preview and the result disagreeing. The undo step is recorded once, on
    /// mouse up, from the frame the drag started with.
    private func applyLiveDrag() {
        guard let session,
              let page = dragPage, let start = dragStart, let end = dragEnd else { return }
        let selection = session.selection ?? session.selections.first
        guard let selection else { return }
        guard exactPage(at: end) === page else { return }
        let from = toPage(start, page)
        let to = toPage(end, page)

        switch dragKind {
        case .pinned:
            return
        case .move:
            let selected = session.selections.count > 1
                ? session.selections
                : [selection]
            // A sketch is moved once, on mouse up, by building a shifted copy.
            // Doing that on every mouse event would churn a new annotation per
            // pixel of travel.
            let wanted = clampedFrame(
                dragOriginalFrame.offsetBy(dx: to.x - from.x, dy: to.y - from.y),
                to: page)
            let delta = CGSize(width: wanted.minX - dragOriginalFrame.minX,
                               height: wanted.minY - dragOriginalFrame.minY)
            let transform = AffineTransform(translationByX: delta.width, byY: delta.height)
            let drawable = selected.filter { PDFEditing.kind(of: $0.annotation) != "Ink" }
            applyGroupGeometry(to: drawable, pathTransform: transform) { point in
                CGPoint(x: point.x + delta.width, y: point.y + delta.height)
            }
            pdfView?.layoutDocumentView()
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            pdfView?.documentView?.setNeedsDisplay(pdfView?.documentView?.bounds ?? .zero)
        case .resize(let handle):
            let delta = CGSize(width: to.x - from.x, height: to.y - from.y)
            let frame: CGRect
            if session.selections.count > 1 {
                frame = scaled(dragOriginalFrame, handle: handle, by: delta)
            } else if selection.annotation is PDFImageStamp {
                // A picture has an aspect ratio worth keeping. Stretching one is
                // never what you meant by dragging its corner.
                frame = clampedFrame(scaled(dragOriginalFrame, handle: handle, by: delta),
                                     to: page)
            } else {
                frame = clampedFrame(
                    clampedToText(resized(dragOriginalFrame, handle: handle, by: delta),
                                  handle: handle, for: selection.annotation),
                    to: page)
            }
            if session.selections.count > 1 {
                let old = dragOriginalFrame
                let sx = old.width > 0 ? frame.width / old.width : 1
                let sy = old.height > 0 ? frame.height / old.height : 1
                applyGroupGeometry(to: session.selections,
                                   pathTransform: AffineTransform(
                                       m11: sx, m12: 0, m21: 0, m22: sy,
                                       tX: frame.minX - old.minX * sx,
                                       tY: frame.minY - old.minY * sy)) { point in
                    CGPoint(x: frame.minX + (point.x - old.minX) * sx,
                            y: frame.minY + (point.y - old.minY) * sy)
                }
            } else {
                selection.annotation.bounds = frame
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            pdfView?.documentView?.setNeedsDisplay(pdfView?.documentView?.bounds ?? .zero)
        case .create:
            break
        }
    }

    /// A text box may not be dragged smaller than its text needs.
    ///
    /// "Needs" is measured against the width being dragged to, not against one
    /// unwrapped line: narrowing a box is how you make its text wrap, and the
    /// only real floor on width is the longest single word. The height then
    /// follows from that width, so a box grows taller as you narrow it rather
    /// than clipping what no longer fits.
    ///
    /// The clamp re-anchors rather than just widening: dragging the top-left
    /// handle moves the origin, so pinning the size while leaving `minX` alone
    /// would slide the corner you were *not* dragging out from under itself.
    private func clampedToText(_ frame: CGRect, handle: Handle,
                               for annotation: PDFAnnotation) -> CGRect {
        guard PDFEditing.kind(of: annotation) == "FreeText" else { return frame }
        let minimum = PDFEditing.minimumSize(for: annotation, atWidth: frame.width)
        guard frame.width < minimum.width || frame.height < minimum.height else { return frame }
        let size = CGSize(width: max(frame.width, minimum.width),
                          height: max(frame.height, minimum.height))
        let fixed = CGPoint(x: 1 - handle.anchor.x, y: 1 - handle.anchor.y)
        let held = CGPoint(x: frame.minX + frame.width * fixed.x,
                           y: frame.minY + frame.height * fixed.y)
        return CGRect(x: held.x - size.width * fixed.x,
                      y: held.y - size.height * fixed.y,
                      width: size.width, height: size.height)
    }

    /// Resize about the opposite corner, in proportion, driven by how far along
    /// the diagonal you have dragged.
    ///
    /// The old arithmetic took whichever axis had grown more, which is why the
    /// bottom-right handle misbehaved: page coordinates put y upwards, so
    /// dragging that handle down and right *shrinks* the height while the width
    /// grows, and dragging up and left does the reverse. Taking the larger of
    /// two ratios that disagree by construction meant the selection grew in both
    /// directions. Projecting the drag onto the anchor-to-handle diagonal gives
    /// one number that is above 1 only when you are genuinely pulling away from
    /// the anchor, so away grows, back shrinks, and nothing jumps.
    private func scaled(_ old: CGRect, handle: Handle, by delta: CGSize) -> CGRect {
        guard old.width > 0, old.height > 0 else { return old }
        let opposite = CGPoint(x: 1 - handle.anchor.x, y: 1 - handle.anchor.y)
        let anchor = CGPoint(x: old.minX + old.width * opposite.x,
                             y: old.minY + old.height * opposite.y)
        let grip = CGPoint(x: old.minX + old.width * handle.anchor.x,
                           y: old.minY + old.height * handle.anchor.y)

        let reach = CGVector(dx: grip.x - anchor.x, dy: grip.y - anchor.y)
        let span = reach.dx * reach.dx + reach.dy * reach.dy
        guard span > 0 else { return old }
        let pulled = CGVector(dx: reach.dx + delta.width, dy: reach.dy + delta.height)
        let projected = (pulled.dx * reach.dx + pulled.dy * reach.dy) / span

        // Floor the scale rather than the width and height, so the frame stays
        // in proportion right down to the smallest it is allowed to be.
        let floor = max(8 / old.width, 8 / old.height)
        let scale = max(floor, projected)
        return CGRect(x: anchor.x + (old.minX - anchor.x) * scale,
                      y: anchor.y + (old.minY - anchor.y) * scale,
                      width: old.width * scale,
                      height: old.height * scale)
    }

    private func captureGeometry(for selections: [PDFEditSession.Selection]) {
        dragOriginalGeometry = geometry(for: selections)
    }

    private func geometry(for selections: [PDFEditSession.Selection])
        -> [ObjectIdentifier: GeometrySnapshot] {
        Dictionary(uniqueKeysWithValues: selections.map { item in
            let annotation = item.annotation
            let paths = (annotation.paths ?? []).compactMap { $0.copy() as? NSBezierPath }
            let isLine = PDFEditing.kind(of: annotation) == "Line"
            return (ObjectIdentifier(annotation),
                    GeometrySnapshot(bounds: annotation.bounds,
                                     paths: paths,
                                     lineStart: isLine ? annotation.startPoint : nil,
                                     lineEnd: isLine ? annotation.endPoint : nil))
        })
    }

    private func applyGeometry(_ snapshots: [ObjectIdentifier: GeometrySnapshot],
                               to selections: [PDFEditSession.Selection]) {
        for item in selections {
            guard let snapshot = snapshots[ObjectIdentifier(item.annotation)] else { continue }
            let annotation = item.annotation
            annotation.bounds = snapshot.bounds
            if let start = snapshot.lineStart, let end = snapshot.lineEnd {
                annotation.startPoint = start
                annotation.endPoint = end
            }
            if !snapshot.paths.isEmpty {
                for path in annotation.paths ?? [] { annotation.remove(path) }
                for path in snapshot.paths {
                    if let copy = path.copy() as? NSBezierPath { annotation.add(copy) }
                }
            }

        }
    }

    /// Undo and redo for a group move or resize.
    ///
    /// Geometry alone is not enough, and that was the bug. A sketch cannot be
    /// transformed where it lies -- `replaceInkSelections` rebuilds its paths
    /// into a new annotation and swaps that onto the page -- so undo has to put
    /// the original *annotation* back, not write old coordinates onto an object
    /// that was taken off the page a moment ago. Restoring geometry alone left
    /// the replacement sitting exactly where you dragged it: ⌘Z did nothing,
    /// Discard on the way out did nothing, and `revertAll` then cleared the
    /// dirty flag, so the app believed a document it had quietly changed still
    /// matched the file. The next save of anything wrote the lot.
    ///
    /// The two lists come from `replaceInkSelections`, which returns what it was
    /// given in the same order, so they pair up by position.
    private func swapSteps(from originals: [PDFEditSession.Selection],
                           to replacements: [PDFEditSession.Selection],
                           before: [ObjectIdentifier: GeometrySnapshot],
                           after: [ObjectIdentifier: GeometrySnapshot])
        -> (undo: () -> Void, redo: () -> Void) {
        let swapped = zip(originals, replacements)
            .filter { $0.0.annotation !== $0.1.annotation }
            .map { (old: $0.0, new: $0.1) }

        let pages = session?.pages ?? .identity
        func put(_ wanted: [PDFEditSession.Selection],
                 over unwanted: [PDFEditSession.Selection]) {
            for item in unwanted {
                item.annotation.shouldDisplay = false
                pages.remove(item.annotation, from: item.page)
            }
            for item in wanted {
                item.annotation.shouldDisplay = true
                pages.add(item.annotation, to: item.page)
            }
        }

        return (
            undo: { [weak self] in
                put(swapped.map { $0.old }, over: swapped.map { $0.new })
                self?.applyGeometry(before, to: originals)
                // The selection has to follow the swap, or the handles are drawn
                // round an annotation that is no longer on the page and ⌫ would
                // delete nothing.
                self?.session?.selections = originals
                self?.session?.selection = originals.first
                self?.refresh()
            },
            redo: { [weak self] in
                put(swapped.map { $0.new }, over: swapped.map { $0.old })
                self?.applyGeometry(after, to: replacements)
                self?.session?.selections = replacements
                self?.session?.selection = replacements.first
                self?.refresh()
            }
        )
    }

    private func replaceInkSelections(
        _ selections: [PDFEditSession.Selection],
        using transform: AffineTransform
    ) -> [PDFEditSession.Selection] {
        guard let session else { return selections }
        var replacements: [ObjectIdentifier: PDFAnnotation] = [:]
        for item in selections where PDFEditing.kind(of: item.annotation) == "Ink" {
            guard let original = dragOriginalGeometry[ObjectIdentifier(item.annotation)] else { continue }
            let replacement = PDFEditing.transformedInk(item.annotation,
                                                         paths: original.paths,
                                                         using: transform,
                                                         on: item.page)
            item.page.removeAnnotation(item.annotation)
            item.page.addAnnotation(replacement)
            replacements[ObjectIdentifier(item.annotation)] = replacement
        }
        guard !replacements.isEmpty else { return selections }
        let updated = selections.map { item in
            guard let replacement = replacements[ObjectIdentifier(item.annotation)] else { return item }
            return PDFEditSession.Selection(annotation: replacement, page: item.page)
        }
        session.selections = session.selections.map { item in
            guard let replacement = replacements[ObjectIdentifier(item.annotation)] else { return item }
            return PDFEditSession.Selection(annotation: replacement, page: item.page)
        }
        if let current = session.selection,
           let replacement = replacements[ObjectIdentifier(current.annotation)] {
            session.selection = PDFEditSession.Selection(annotation: replacement, page: current.page)
        }
        return updated
    }

    private func applyGroupGeometry(to selections: [PDFEditSession.Selection],
                                    pathTransform: AffineTransform,
                                    transform: (CGPoint) -> CGPoint) {
        for item in selections {
            let annotation = item.annotation
            guard let original = dragOriginalGeometry[ObjectIdentifier(annotation)] else { continue }
            switch PDFEditing.kind(of: annotation) {
            case "Line":
                if let start = original.lineStart, let end = original.lineEnd {
                    annotation.startPoint = transform(start)
                    annotation.endPoint = transform(end)
                }
            case "Ink":
                for path in annotation.paths ?? [] { annotation.remove(path) }
                for path in original.paths {
                    guard let copy = path.copy() as? NSBezierPath else { continue }
                    copy.transform(using: pathTransform)
                    annotation.add(copy)
                }
            default:
                let min = transform(original.bounds.origin)
                let maximum = transform(CGPoint(x: original.bounds.maxX, y: original.bounds.maxY))
                annotation.bounds = CGRect(x: min.x, y: min.y,
                                           width: Swift.max(8, maximum.x - min.x),
                                           height: Swift.max(8, maximum.y - min.y))
            }
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
        unfade(doomed)
        doomed = []
        sweepClass = nil
        dragOriginalPaths = []
        dragOriginalBounds = [:]
        dragOriginalFrames = [:]
        dragOriginalGeometry = [:]
        textSelection = nil
        needsDisplay = true
    }

    /// Whole marks, not pixels. A sketch is one annotation holding every point
    /// of the stroke, so rubbing out half of one would mean splitting its paths
    /// and leaving two marks where you drew one; taking the mark you touched
    /// matches the objects actually on the page.
    ///
    /// Nothing is removed here. Marks the sweep has caught are faded, and the
    /// removal happens once, on mouse up -- so a sweep that wanders somewhere
    /// you did not mean is something you can see before it costs you anything.
    private func markForErasing(at point: NSPoint) {
        guard let page = page(at: point) else { return }
        let inPage = toPage(point, page)
        let caught = PDFEditing.marks(at: inPage, on: page, tolerance: eraserRadius)
            .filter { annotation in !doomed.contains { $0.annotation === annotation } }
        guard !caught.isEmpty else { return }

        for annotation in caught {
            let colour = annotation.color
            doomed.append(Doomed(annotation: annotation, page: page,
                                 colour: colour, interior: annotation.interiorColor))
            fade(annotation)
        }

        // Marks win over drawings, so clearing a highlight off a diagram does
        // not take the diagram with it. Anything already caught that is not of
        // the winning class is let go, and comes back to full strength.
        let classes = Set(doomed.map { PDFEditing.eraseClass(of: $0.annotation) })
        sweepClass = classes.contains(.marks) ? .marks : .drawings
        let released = doomed.filter { PDFEditing.eraseClass(of: $0.annotation) != sweepClass }
        if !released.isEmpty {
            unfade(released)
            doomed.removeAll { entry in released.contains { $0.annotation === entry.annotation } }
        }
        needsDisplay = true
    }

    private func fade(_ annotation: PDFAnnotation) {
        annotation.color = translucent(annotation.color)
        if let interior = annotation.interiorColor {
            annotation.interiorColor = translucent(interior)
        }
    }

    private func unfade(_ entries: [Doomed]) {
        for entry in entries {
            entry.annotation.color = entry.colour
            entry.annotation.interiorColor = entry.interior
        }
        if !entries.isEmpty { refresh() }
    }

    private func translucent(_ colour: NSColor) -> NSColor {
        let sRGB = colour.usingColorSpace(.sRGB) ?? colour
        return sRGB.withAlphaComponent(sRGB.alphaComponent * 0.25)
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
            let selected = session.selections.count > 1 ? session.selections : [selection]
            let before = dragOriginalGeometry
            let delta = CGSize(width: to.x - from.x, height: to.y - from.y)
            let movedSelections = replaceInkSelections(
                selected,
                using: AffineTransform(translationByX: delta.width, byY: delta.height))
            let after = geometry(for: movedSelections)
            let steps = swapSteps(from: selected, to: movedSelections,
                                  before: before, after: after)
            session.record(selected.count == 1 ? "moving that mark" : "moving those marks",
                           undo: steps.undo, redo: steps.redo)
            refresh()
            return

        case .resize(let handle) where dragMoved:
            guard let selection = session.selection else { return }
            let selected = session.selections.count > 1 ? session.selections : [selection]
            let before = dragOriginalGeometry
            let old = dragOriginalFrame
            // Worked out exactly as `applyLiveDrag` worked it out, handle and
            // all. It used to assume the bottom-right corner and its own
            // arithmetic, so what you let go of was not what you had been
            // dragging: the marks jumped on mouse up.
            let delta = CGSize(width: to.x - from.x, height: to.y - from.y)
            let current: CGRect
            if selected.count > 1 {
                current = scaled(old, handle: handle, by: delta)
            } else if selection.annotation is PDFImageStamp {
                current = clampedFrame(scaled(old, handle: handle, by: delta), to: page)
            } else {
                current = clampedFrame(
                    clampedToText(resized(old, handle: handle, by: delta),
                                  handle: handle, for: selection.annotation),
                    to: page)
            }
            let sx = old.width > 0 ? current.width / old.width : 1
            let sy = old.height > 0 ? current.height / old.height : 1
            let transform = AffineTransform(m11: sx, m12: 0, m21: 0, m22: sy,
                                             tX: current.minX - old.minX * sx,
                                             tY: current.minY - old.minY * sy)
            let resizedSelections = replaceInkSelections(selected, using: transform)
            let after = geometry(for: resizedSelections)
            let label = selected.count == 1 ? "resizing that mark" : "resizing those marks"
            let steps = swapSteps(from: selected, to: resizedSelections,
                                  before: before, after: after)
            session.record(label, undo: steps.undo, redo: steps.redo)
            refresh()
            return

        case .move, .resize:
            return                                   // a click that did not move
        case .pinned:
            return                                   // selected, and staying put
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
            let pages = session.pages
            session.perform("that \(mark.label.lowercased())",
                            undo: {
                                for (annotation, page) in made {
                                    annotation.shouldDisplay = false
                                    pages.remove(annotation, from: page)
                                }
                            },
                            redo: {
                                for (annotation, page) in made {
                                    annotation.shouldDisplay = true
                                    pages.add(annotation, to: page)
                                }
                            })
            refresh()
            return
        }

        switch tool {
        case .lasso:
            guard viewRect.width >= minimumDrag, viewRect.height >= minimumDrag else { return }
            let pageSelection = strokePoints.reduce(into: CGRect.null) { result, point in
                let pagePoint = toPage(point, page)
                result = result.union(CGRect(x: pagePoint.x, y: pagePoint.y,
                                             width: 0, height: 0))
            }
            let selected = page.annotations.compactMap { annotation -> PDFEditSession.Selection? in
                let kind = PDFEditing.kind(of: annotation)
                guard !PDFEditing.isFlag(annotation),
                      kind != "Highlight", kind != "Underline", kind != "StrikeOut",
                      PDFEditing.frame(of: annotation).intersects(pageSelection) else { return nil }
                return PDFEditSession.Selection(annotation: annotation, page: page)
            }
            session.selections = selected
            session.selection = selected.first
            if !selected.isEmpty {
                needsDisplay = true
            }
        case .pen:
            let points = strokePoints.map { toPage($0, page) }
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            session.add(PDFEditing.stroke(path, colour: strokeColour, width: lineWidth, on: page),
                        to: page, label: "that sketch")
            // The pen is still in your hand, so there is nothing to nudge yet:
            // a dashed outline round every stroke as you write is noise, and it
            // would put the last stroke under ⌫.
            session.selection = nil

        case .freeHighlight:
            let points = strokePoints.map { toPage($0, page) }
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            session.add(PDFEditing.highlighterStroke(path, colour: strokeColour,
                                                     width: lineWidth, on: page),
                        to: page, label: "that highlight")
            session.selection = nil

        case .eraser:
            // The sweep is over: put the colours back before taking the marks
            // off, or an undo would hand you a faded copy of what you erased.
            let gone = doomed
            unfade(gone)
            doomed = []
            guard !gone.isEmpty else { return }
            for entry in gone where session.selection?.annotation === entry.annotation {
                session.selection = nil
            }
            let label = gone.count == 1 ? "erasing that mark" : "erasing \(gone.count) marks"
            let pages = session.pages
            session.perform(label,
                            undo: {
                                for entry in gone {
                                    entry.annotation.shouldDisplay = true
                                    pages.add(entry.annotation, to: entry.page)
                                }
                            },
                            redo: {
                                for entry in gone {
                                    entry.annotation.shouldDisplay = false
                                    pages.remove(entry.annotation, from: entry.page)
                                }
                            })

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
        // `attribute(at:)` on an empty attributed string raises -- there is no
        // character 0 to ask about. Committing an empty box is the ordinary
        // case, not an edge one: drawing a text box and then clicking Save,
        // pressing Done, or clicking away all arrive here with nothing typed.
        if attributedText.length > 0,
           let font = attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            annotation.font = font
        }
        // A box settles at the size of what is in it. Anything larger you
        // dragged it to is kept, because making room is a thing people do
        // deliberately; anything smaller is not, because a box smaller than its
        // text does not reflow, it clips.
        let oldBounds = annotation.bounds
        // Measured at the width the box already has, so the words wrap into it
        // rather than stretching it back out to one long line -- which is what
        // used to undo a resize the moment you typed in the box.
        let fitted = PDFEditing.fittedSize(of: attributedText, wrappingAt: oldBounds.width)
        annotation.bounds = CGRect(origin: oldBounds.origin,
                                   size: CGSize(width: max(oldBounds.width, fitted.width),
                                                height: max(oldBounds.height, fitted.height)))
        let wasNew = editingIsNew
        textEditor = nil
        editingAnnotation = nil
        editingIsNew = false
        editor.removeFromSuperview()

        guard let session else { refresh(); return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A text box with nothing in it is invisible on the page but still
            // there to be clicked, dragged, resized and exported -- so it does
            // not get to exist, however it came to be empty.
            if wasNew {
                // Thrown away rather than undone, so ⇧⌘Z cannot bring an empty
                // one back: drawing a box and changing your mind is not an edit.
                session.discardLastStep()
            } else if let page = annotation.page {
                // Emptying a box you already had is how you delete it, and that
                // *is* an edit -- ⌘Z brings the words back.
                session.remove(annotation, from: page)
            }
            refresh()
            return
        }
        // Merged with the step that created the box: drawing it and typing into
        // it was one action, so it should take one ⌘Z.
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
        guard let session, textEditor == nil else { return }
        if session.selections.count > 1,
           let page = session.selections.first?.page,
           let frame = selectionFrame(session.selections, on: page) {
            drawSelectionFrame(frame, page: page)
        } else if let selection = session.selection {
            drawSelectionFrame(PDFEditing.frame(of: selection.annotation), page: selection.page)
        }
    }

    private func drawSelectionFrame(_ pageFrame: CGRect, page: PDFPage) {
        let frame = toView(pageFrame, page)

        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        frame.fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

        let handles: [Handle] = (session?.selections.count ?? 0) > 1
            ? [.bottomRight] : Handle.allCases
        for handle in handles {
            let rect = handleRect(handle, in: frame)
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
        case .lasso:
            guard strokePoints.count > 1 else { return }
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.move(to: strokePoints[0])
            for point in strokePoints.dropFirst() { path.line(to: point) }
            path.close()
            path.stroke()

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

        case .freeHighlight:
            guard strokePoints.count > 1 else { return }
            PDFEditing.highlighterColour(strokeColour).setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth * (pdfView?.scaleFactor ?? 1)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: strokePoints[0])
            for point in strokePoints.dropFirst() { path.line(to: point) }
            path.stroke()

        // The eraser shows itself by the marks going away as you sweep.
        case .select, .eraser:
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
