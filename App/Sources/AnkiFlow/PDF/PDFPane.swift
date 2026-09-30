import SwiftUI
import PDFKit
import AppKit
import QuartzCore

/// Owns the single PDFView instance so the viewer and the thumbnail strip can
/// both talk to it. PDFThumbnailView drives its host directly, so they have to
/// share the same object rather than each making their own.
@MainActor
final class PDFViewBox: ObservableObject {
    let view: PDFView = {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }()
    weak var editOverlay: PDFEditOverlayView?

    func toggleFontTrait(_ trait: NSFontTraitMask) -> Bool {
        editOverlay?.toggleFontTrait(trait) ?? false
    }

    func toggleUnderline() -> Bool {
        editOverlay?.toggleUnderline() ?? false
    }
}

/// The PDF viewer. Two-way bound to the current page so ⌘↓ / ⌘↑ can drive it
/// from anywhere in the app -- including while the cursor sits in a text field,
/// which is the single most important binding in the product.
struct PDFPane: NSViewRepresentable {
    @Environment(\.palette) private var palette
    let box: PDFViewBox
    let document: PDFDocument?
    /// Changes when the lecture is re-read from disk, which is how this tells a
    /// reload of the same lecture from opening a different one. Opening a
    /// different lecture should start at the top; a reload should not.
    var reloadToken: Int = 0
    @Binding var currentPage: Int   // 1-based
    /// Slides already attached to the row ⌘T is aimed at, so the page badges can
    /// fill those in. Passed through rather than read from `AppState`: this view
    /// is used by the Pencil window too, and it takes everything it draws from
    /// its arguments.
    var armedPages: Set<Int> = []
    /// The committed crop for a page on the armed row, or nil for the whole slide.
    var cropForPage: (Int) -> CropRect? = { _ in nil }
    /// Occlusion masks on this page, drawn so you can see what you have hidden.
    var masksForPage: (Int) -> [Mask] = { _ in [] }
    /// The region the pointer is over, and the group it belongs to. Both come
    /// from outside so a hover started in the question panel lights the same
    /// rectangle as a hover started on the slide.
    var hoveredMaskID: String?
    var hoveredMaskGroup: Int?
    var uncoveredPages: Set<Int> = []
    var isCropping = false
    var onHoverMask: (String?) -> Void = { _ in }
    /// A region that was dragged or resized on the slide.
    var onMaskChanged: (String, CropRect) -> Void = { _, _ in }
    var onCrop: (Int, CropRect) -> Void = { _, _ in }
    /// The live editing session, or nil when not editing.
    var session: PDFEditSession?
    /// The tool in hand, or nil. Nil keeps the edit overlay invisible to the
    /// mouse, so the pane behaves exactly as it did before that feature.
    var editTool: PDFEditing.Tool?
    var strokeColour: NSColor = .systemYellow
    var fillColour: NSColor?
    var editLineWidth: Double = 2
    var editFontSize: Double = 14
    var editBold = false
    var editItalic = false
    var editUnderline = false
    var findAnnotationHighlight: (PDFPage, CGRect)?
    var onToolUsed: () -> Void = { }
    var onMessage: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        let view = box.view
        view.clipsToBounds = true
        view.backgroundColor = NSColor(palette.field)
        // Dark mode is a lightbox: the page carries a shadow so it reads as the
        // only lit object. Light mode is paper on paper, so it doesn't.
        view.pageShadowsEnabled = palette.pageShadowRadius > 0
        view.document = document
        context.coordinator.attach(to: view)

        // The PDFView is shared with the thumbnail strip, so it may already be
        // parented if SwiftUI rebuilds this representable.
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)

        let overlay = CropOverlayView()
        overlay.pdfView = view
        overlay.startObservingScroll()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        context.coordinator.overlay = overlay

        // Above the crop overlay, and inert until a tool is picked up. Order
        // matters: with no tool both overlays pass the mouse through, with a
        // tool this one takes it, and ⌥-crop keeps working in between.
        let editOverlay = PDFEditOverlayView()
        editOverlay.pdfView = view
        editOverlay.startObservingScroll()
        editOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editOverlay)
        context.coordinator.editOverlay = editOverlay
        box.editOverlay = editOverlay

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            editOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            editOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = box.view
        view.backgroundColor = NSColor(palette.field)
        view.pageShadowsEnabled = palette.pageShadowRadius > 0

        if let overlay = context.coordinator.overlay {
            overlay.accent = NSColor(palette.amber)
            overlay.currentPage = currentPage
            overlay.armedPages = armedPages
            overlay.cropForPage = cropForPage
            overlay.masksForPage = masksForPage
            overlay.hoveredMaskID = hoveredMaskID
            overlay.hoveredMaskGroup = hoveredMaskGroup
            overlay.uncoveredPages = uncoveredPages
            overlay.isCropping = isCropping
            overlay.onHoverMask = onHoverMask
            overlay.onMaskChanged = onMaskChanged
            overlay.onCommit = onCrop
            overlay.needsDisplay = true
        }
        if let editOverlay = context.coordinator.editOverlay {
            // Leaving editing has to take the text editor down with it, or a
            // half-typed note is left floating over a pane that is no longer in
            // edit mode.
            editOverlay.isCropping = isCropping
            if editTool == nil && editOverlay.tool != nil { editOverlay.commitTextEditing() }
            if editOverlay.tool != editTool { editOverlay.clearTextSelection() }
            editOverlay.suppressTextAnnotations(true)
            editOverlay.session = session
            editOverlay.tool = editTool
            editOverlay.strokeColour = strokeColour
            editOverlay.fillColour = fillColour
            editOverlay.lineWidth = CGFloat(editLineWidth)
            editOverlay.fontSize = CGFloat(editFontSize)
            editOverlay.fontBold = editBold
            editOverlay.fontItalic = editItalic
            editOverlay.fontUnderline = editUnderline
            editOverlay.findAnnotationHighlight = findAnnotationHighlight
            editOverlay.onToolUsed = onToolUsed
            editOverlay.onMessage = onMessage
            // The cursor is part of knowing which tool is in your hand.
            editOverlay.window?.invalidateCursorRects(for: editOverlay)
            editOverlay.needsDisplay = true
        }
        container.clipsToBounds = true
        view.clipsToBounds = true
        if view.document !== document {
            // A reload swaps in a new PDFDocument for the same lecture, and
            // PDFKit starts a new document at the top. Where you were reading is
            // kept across the swap: the destination's page object belongs to the
            // document being thrown away, so it is remembered as an index and a
            // point and rebuilt against the new one.
            // The token moves only on a reload, so a document swap with the
            // same token is a different lecture and belongs at the top.
            let resuming = reloadToken != context.coordinator.reloadToken
            let mark = resuming ? view.readingPosition() : nil
            if resuming {
                // Swapped behind a held frame. PDFKit relayouts on assignment
                // and paints the top of the new document before `go(to:)` puts
                // it back, which is one frame of the wrong slide -- small, but
                // it reads as a flicker and it happens every time you annotate
                // on the iPad. Holding the last drawn frame over the swap and
                // fading it out means the page you are reading simply becomes
                // the newer version of itself.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let freeze = view.snapshotLayer()
                view.document = document
                context.coordinator.lastReportedPage = 0
                if let mark { view.restoreReadingPosition(mark) }
                view.layoutSubtreeIfNeeded()
                CATransaction.commit()
                freeze?.fadeOutAndRemove()
            } else {
                view.document = document
                context.coordinator.lastReportedPage = 0
            }
        }
        context.coordinator.reloadToken = reloadToken
        guard let document else { return }

        let index = currentPage - 1
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
        // Only drive the view when the page came from somewhere else: ⌘↓, the
        // page menu, clicking a slide chip, restoring where you left off.
        //
        // When the number came *from* the view because you scrolled, scrolling
        // to it is worse than pointless. The report is asynchronous -- it has to
        // be, or it would mutate observed state inside a SwiftUI update -- so
        // between your scroll and the binding catching up there is a window
        // where `currentPage` still holds the page you left. Any redraw landing
        // in that window used to call `go(to:)` and haul the document back, and
        // because scrolling produces a redraw of its own that fight could keep
        // going: the pane pinned itself to the slide you started on and would
        // not let you reach another.
        if !context.coordinator.reportInFlight {
            if view.currentPage !== page {
                context.coordinator.suppressCallback = true
                view.go(to: page)
                context.coordinator.suppressCallback = false
            }
            // The view is on `currentPage` now, however it got there, so that is
            // the last page number anybody has reported.
            //
            // Leaving this holding an older one is what made ⌘T attach the wrong
            // slide. Jump from 7 to 12 by clicking a chip and the jump is
            // suppressed, so `lastReportedPage` stays 7; scroll back to 7 and the
            // report is thrown away as a duplicate of a page you are no longer
            // recorded as having left. The binding stays on 12, nothing on screen
            // says so, and the next ⌘T attaches 12 -- the slide you jumped away
            // from -- rather than the one you are looking at.
            context.coordinator.lastReportedPage = currentPage
        }
        // Redraw the existing layout without rebuilding it. Re-layout changes
        // the scroll geometry and can jerk the document while marking it up.
        view.setNeedsDisplay(view.bounds)
        if let documentView = view.documentView {
            documentView.setNeedsDisplay(documentView.bounds)
        }
        context.coordinator.editOverlay?.needsDisplay = true
    }

    final class Coordinator: NSObject {
        @Binding var currentPage: Int
        /// True from the moment the view reports a scroll until the binding has
        /// taken the new value.
        var reportInFlight = false
        var suppressCallback = false
        var lastReportedPage = 0
        var reloadToken = 0
        weak var overlay: CropOverlayView?
        weak var editOverlay: PDFEditOverlayView?
        private weak var view: PDFView?

        init(currentPage: Binding<Int>) {
            _currentPage = currentPage
        }

        func attach(to view: PDFView) {
            guard self.view !== view else { return }
            self.view = view
            // Not filtered on a document. Reloading the lecture replaces the
            // one the pane is showing, and an observer pinned to the old object
            // simply stops hearing anything -- which showed up as undo doing
            // nothing visible after the file had synced in from elsewhere.
            NotificationCenter.default.removeObserver(
                self, name: .pdfEditSessionDidChange, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(editSessionChanged(_:)),
                name: .pdfEditSessionDidChange,
                object: nil
            )
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc private func editSessionChanged(_ note: Notification) {
            guard let view else { return }
            view.setNeedsDisplay(view.bounds)
            view.documentView?.setNeedsDisplay(view.documentView?.bounds ?? .zero)
            editOverlay?.needsDisplay = true
        }

        @objc private func pageChanged(_ note: Notification) {
            guard !suppressCallback,
                  let view,
                  let document = view.document,
                  let page = view.currentPage else { return }
            let number = document.index(for: page) + 1
            guard number != lastReportedPage else { return }
            lastReportedPage = number
            // Held until the binding has caught up, so `updateNSView` knows the
            // disagreement between the view and the binding is the view being
            // ahead rather than someone asking for a different page.
            reportInFlight = true
            // Scrolling fires this often; hop to the next runloop so we never
            // mutate observed state during a SwiftUI view update.
            DispatchQueue.main.async { [weak self] in
                self?.currentPage = number
                self?.reportInFlight = false
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// A horizontal filmstrip of page thumbnails. Secondary to the keyboard path --
/// it exists for the awkward cases, not the common one.
struct ThumbnailStrip: NSViewRepresentable {
    @Environment(\.palette) private var palette
    let box: PDFViewBox
    @Binding var currentPage: Int
    var showFlaggedOnly = false
    var showUncoveredOnly = false
    /// Slides no question cites. Marked in the strip and, when the filter is
    /// on, the only ones in it.
    var uncoveredPages: Set<Int> = []
    var onMove: (Int, Int) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(palette.field)
        let gallery = ThumbnailGalleryView()
        scroll.documentView = gallery
        configure(gallery)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        view.backgroundColor = NSColor(palette.field)
        if let gallery = view.documentView as? ThumbnailGalleryView {
            configure(gallery)
        }
    }

    private func configure(_ view: ThumbnailGalleryView) {
        view.document = box.view.document
        view.currentPage = currentPage
        view.showFlaggedOnly = showFlaggedOnly
        view.showUncoveredOnly = showUncoveredOnly
        view.uncoveredPages = uncoveredPages
        view.onSelect = { page in currentPage = page }
        view.onMove = onMove
        view.needsLayout = true
        view.needsDisplay = true
        let total = box.view.document?.pageCount ?? 0
        let count: Int
        if showUncoveredOnly {
            count = uncoveredPages.count
        } else if showFlaggedOnly {
            count = (box.view.document.map { document in
                (0..<document.pageCount).filter { index in
                    document.page(at: index)?.annotations.contains(where: PDFEditing.isFlag) == true
                }.count
            } ?? 0)
        } else {
            count = total
        }
        view.frame = NSRect(x: 0, y: 0,
                            width: max(10 + CGFloat(count) * 74, view.superview?.bounds.width ?? 0),
                            height: 92)
        view.superview?.needsDisplay = true
    }
}

/// A compact, horizontal gallery whose thumbnails can be reordered directly.
final class ThumbnailGalleryView: NSView {
    var document: PDFDocument? { didSet { needsDisplay = true } }
    var currentPage = 1 { didSet { needsDisplay = true } }
    var showFlaggedOnly = false { didSet { needsDisplay = true } }
    var showUncoveredOnly = false { didSet { needsDisplay = true } }
    var uncoveredPages: Set<Int> = [] { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?

    private let thumbnailSize = NSSize(width: 64, height: 72)
    private let gap: CGFloat = 10
    private var dragPage: Int?
    private var dragPoint: NSPoint?

    private var displayedPages: [Int] {
        guard let document, document.pageCount > 0 else { return [] }
        if showUncoveredOnly { return uncoveredPages.sorted() }
        if !showFlaggedOnly { return Array(1...document.pageCount) }
        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index),
                  page.annotations.contains(where: PDFEditing.isFlag) else { return nil }
            return index + 1
        }

    }

    private func pageRect(_ index: Int) -> NSRect {
        let x = 10 + CGFloat(index) * (thumbnailSize.width + gap)
        return NSRect(x: x, y: 10, width: thumbnailSize.width, height: thumbnailSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        for (index, number) in displayedPages.enumerated() {
            let rect = pageRect(index)
            if number == currentPage {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                rect.insetBy(dx: -4, dy: -4).fill()
            }
            if let thumbnail = document.page(at: number - 1)?.thumbnail(of: thumbnailSize, for: .cropBox) {
                thumbnail.draw(in: rect)
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect).stroke()
            let label = "\(number)" as NSString
            label.draw(at: NSPoint(x: rect.minX, y: 1),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                        .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard document != nil else { return }
        let pages = displayedPages
        let sourceIndex = pages.indices.first { pageRect($0).contains(point) }
        let source = sourceIndex.map { pages[$0] }
        guard let source, let sourceIndex, let window else { return }
        dragPage = source
        dragPoint = point
        var last = event
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            last = next
            if next.type == .leftMouseUp { break }
        }
        let end = convert(last.locationInWindow, from: nil)
        let targetIndex = pages.indices.min {
            abs(pageRect($0).midX - end.x) < abs(pageRect($1).midX - end.x)
        } ?? sourceIndex
        let target = pages[targetIndex]
        let moved = abs(end.x - (dragPoint?.x ?? end.x)) > 4
        dragPage = nil
        dragPoint = nil
        if moved && target != source {
            onMove?(source, target)
        } else {
            onSelect?(source)
        }
    }
}

/// Draws and captures crop rectangles over the PDF. Hold ⌥ and drag.
///
/// It never touches the `PDFDocument`. PDFKit will happily hold a `.square`
/// annotation and draw it in page space for free, which is tempting — but the
/// renderer reads that same document, so the crop box would be baked into the
/// exported card image. A sibling view cannot leak into anything, and the PDFs
/// here are being edited by another app in another window; read-only is the only
/// safe posture.
extension NSView {
    /// A picture of what is on screen right now, laid over the view.
    ///
    /// Cheaper and more reliable than trying to make PDFKit relayout without
    /// painting: whatever it does underneath happens behind this.
    func snapshotLayer() -> CALayer? {
        guard bounds.width > 1, bounds.height > 1,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        guard let image = representation.cgImage else { return nil }

        let layer = CALayer()
        layer.frame = bounds
        layer.contents = image
        layer.contentsScale = window?.backingScaleFactor ?? 2
        wantsLayer = true
        self.layer?.addSublayer(layer)
        return layer
    }
}

extension CALayer {
    /// A short cross-fade, then gone. Short enough not to feel like an
    /// animation, long enough that nothing snaps.
    func fadeOutAndRemove(duration: CFTimeInterval = 0.18) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.removeFromSuperlayer()
        }
    }
}

extension PDFView {
    /// Where you are reading, in terms that survive the document being replaced.
    func readingPosition() -> (page: Int, point: CGPoint)? {
        guard let document, let destination = currentDestination,
              let page = destination.page else { return nil }
        return (document.index(for: page), destination.point)
    }

    func restoreReadingPosition(_ mark: (page: Int, point: CGPoint)) {
        guard let document, mark.page >= 0, mark.page < document.pageCount,
              let page = document.page(at: mark.page) else { return }
        go(to: PDFDestination(page: page, at: mark.point))
    }
}

final class CropOverlayView: NSView {
    weak var pdfView: PDFView?
    var accent: NSColor = .systemOrange
    /// The slide ⌘T and ⌘E are aimed at, and the slides already attached to the
    /// row they are aimed at. Every page is numbered; see `drawPageNumber` for
    /// what the three states mean.
    var currentPage: Int = 1
    var armedPages: Set<Int> = []
    /// Both are re-set from SwiftUI on every update, so they never hold a stale
    /// question or a stale armed row.
    var cropForPage: ((Int) -> CropRect?)?
    var masksForPage: ((Int) -> [Mask])?
    var hoveredMaskID: String?
    var hoveredMaskGroup: Int?
    var uncoveredPages: Set<Int> = []
    var onHoverMask: ((String?) -> Void)?
    var onMaskChanged: ((String, CropRect) -> Void)?
    var onCommit: ((Int, CropRect) -> Void)?

    private var observing = false
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var dragPage: PDFPage?
    /// The region being moved or resized, and where it is right now.
    private var maskDrag: (hit: MaskHit, rect: NSRect)?

    /// Drags shorter than this are a click that slipped, not a crop.
    private let minimumDrag: CGFloat = 8

    /// Masks and crop dimming are drawn in view coordinates, so they have to be
    /// redrawn whenever the page moves under them. PDFKit scrolls its own
    /// content without telling anyone, which is why they lagged behind: nothing
    /// marked this view dirty until some unrelated event did.
    ///
    /// The scroll view is found by search rather than by a property, because
    /// PDFView does not expose the one it wraps.
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
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scroller = subview as? NSScrollView { return scroller }
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    @objc private func contentMoved() {
        needsDisplay = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Invisible to the mouse unless ⌥ is down, so scrolling, text selection and
    /// every other PDF interaction reach the PDFView untouched. This is why
    /// cropping needs no mode to enter and no mode to leave.
    /// Set while the crop control in the chip row is lit: the next drag is a
    /// crop, with no modifier to hold and no mode to leave.
    var isCropping = false { didSet { window?.invalidateCursorRects(for: self) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isCropping || NSEvent.modifierFlags.contains(.option) {
            return super.hitTest(point)
        }
        // A region drawn on the slide is an object you are meant to be able to
        // grab, and requiring a modifier to touch something you can see is the
        // kind of rule nobody remembers. So the overlay also takes the mouse
        // over a region and its grips -- which exist only while an occlusion
        // question is in front of you, so every other page behaves as before.
        let local = superview.map { convert(point, from: $0) } ?? point
        return maskHit(at: local) == nil ? nil : self
    }

    // MARK: - Hovering a region

    /// A tracking area rather than `hitTest`, deliberately. This view is
    /// invisible to the mouse unless ⌥ is down -- that is what lets scrolling
    /// and text selection reach the PDFView untouched -- and tracking areas are
    /// delivered regardless of hit testing, so the hover costs that nothing.
    override func resetCursorRects() {
        super.resetCursorRects()
        if isCropping { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = maskID(at: point)
        if found != hoveredMaskID { onHoverMask?(found) }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredMaskID != nil { onHoverMask?(nil) }
    }

    private func maskID(at point: NSPoint) -> String? {
        maskHit(at: point)?.id
    }

    /// Which region the pointer is on, and by what part of it.
    ///
    /// Topmost first: regions are drawn in order, so a later one sits over an
    /// earlier one and should be the one you are pointing at. Grips are tested
    /// before bodies for the same reason -- a corner grip overhangs its own
    /// rectangle, and the corner is the more specific thing to have aimed at.
    private func maskHit(at point: NSPoint) -> MaskHit? {
        guard let pdfView, let document = pdfView.document, dragStart == nil else { return nil }
        for page in pdfView.visiblePages {
            let number = document.index(for: page) + 1
            let pageBox = page.bounds(for: .cropBox)
            for mask in (masksForPage?(number) ?? []).reversed() {
                let rect = convert(pdfView.convert(mask.rect.rect(in: pageBox), from: page),
                                   from: pdfView)
                for (grip, box) in Self.grips(for: rect) where box.contains(point) {
                    return MaskHit(id: mask.id, grip: grip, page: page, rect: rect)
                }
                if rect.contains(point) {
                    return MaskHit(id: mask.id, grip: .body, page: page, rect: rect)
                }
            }
        }
        return nil
    }

    struct MaskHit {
        let id: String
        let grip: MaskGrip
        let page: PDFPage
        let rect: NSRect
    }

    enum MaskGrip { case body, nw, n, ne, e, se, s, sw, w }

    private static let gripSize: CGFloat = 10

    /// The eight handles, in view coordinates. Returned even for a region too
    /// small to hold them comfortably -- overlapping grips on a tiny region are
    /// still better than a region you cannot resize.
    static func grips(for rect: NSRect) -> [(MaskGrip, NSRect)] {
        let size = gripSize
        func box(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
        }
        return [
            (.sw, box(rect.minX, rect.minY)), (.s, box(rect.midX, rect.minY)),
            (.se, box(rect.maxX, rect.minY)), (.w, box(rect.minX, rect.midY)),
            (.e,  box(rect.maxX, rect.midY)), (.nw, box(rect.minX, rect.maxY)),
            (.n,  box(rect.midX, rect.maxY)), (.ne, box(rect.maxX, rect.maxY))
        ]
    }

    static func resized(_ rect: NSRect, grip: MaskGrip, dx: CGFloat, dy: CGFloat) -> NSRect {
        if grip == .body { return rect.offsetBy(dx: dx, dy: dy) }
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch grip {
        case .nw: minX += dx; maxY += dy
        case .n:               maxY += dy
        case .ne: maxX += dx;  maxY += dy
        case .e:  maxX += dx
        case .se: maxX += dx;  minY += dy
        case .s:               minY += dy
        case .sw: minX += dx;  minY += dy
        case .w:  minX += dx
        case .body: break
        }
        // Normalised, so dragging a grip past the opposite edge flips the
        // rectangle rather than inverting it into nothing.
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: - The drag

    /// Tracks the whole drag in a loop rather than waiting for `mouseDragged`
    /// callbacks.
    ///
    /// Those callbacks were not arriving — PDFKit's own tracking swallows them —
    /// so the rectangle stayed zero-sized and nothing dimmed, while the crop
    /// still committed because `mouseUp` read its own event. Pulling the events
    /// off the queue here is the older AppKit idiom and doesn't depend on
    /// anything else in the hierarchy behaving.
    override func mouseDown(with event: NSEvent) {
        guard let pdfView, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = maskHit(at: point) {
            dragMask(hit, from: point, in: window)
            return
        }
        let inPDF = convert(point, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: true) else { return }
        dragPage = page
        dragStart = point
        dragEnd = point
        needsDisplay = true

        var last = event
        tracking: while true {
            // `break`, not `continue`: a nil event with nothing to wait for
            // would spin this loop at full tilt with no way out.
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break tracking }
            last = next
            dragEnd = convert(next.locationInWindow, from: nil)
            // Draw now: this loop is running instead of the normal event cycle,
            // so a deferred redraw would not happen until the drag ended.
            needsDisplay = true
            displayIfNeeded()
            if next.type == .leftMouseUp { break tracking }
        }
        finishDrag(with: last)
    }

    /// Moving or resizing a region. Same hand-rolled tracking loop as the crop
    /// drag, and for the same reason: PDFKit swallows `mouseDragged`.
    private func dragMask(_ hit: MaskHit, from start: NSPoint, in window: NSWindow) {
        maskDrag = (hit: hit, rect: hit.rect)
        var last: NSEvent?
        tracking: while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break tracking }
            last = next
            let now = convert(next.locationInWindow, from: nil)
            maskDrag?.rect = Self.resized(hit.rect, grip: hit.grip,
                                          dx: now.x - start.x, dy: now.y - start.y)
            needsDisplay = true
            displayIfNeeded()
            if next.type == .leftMouseUp { break tracking }
        }

        let final = maskDrag?.rect
        maskDrag = nil
        needsDisplay = true
        guard last != nil, let final, let pdfView,
              final != hit.rect,
              final.width > 1, final.height > 1 else { return }

        // View space → PDFView space → the page's own space, then normalised
        // against the crop box -- the same route the crop drag takes.
        let inPDF = convert(final, to: pdfView)
        let inPage = pdfView.convert(inPDF, to: hit.page)
        let crop = CropRect(rect: inPage, in: hit.page.bounds(for: .cropBox))
        onMaskChanged?(hit.id, crop)
    }

    private func finishDrag(with event: NSEvent) {
        defer {
            dragStart = nil
            dragEnd = nil
            dragPage = nil
            needsDisplay = true
        }
        guard let pdfView, let document = pdfView.document,
              let page = dragPage, let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let viewRect = rect(from: start, to: end)
        guard viewRect.width >= minimumDrag, viewRect.height >= minimumDrag else { return }

        // View space → PDFView space → this page's own space. PDFKit does the
        // zoom and scroll maths, which is the entire reason this is 15 lines
        // rather than 150.
        let a = pdfView.convert(convert(start, to: pdfView), to: page)
        let b = pdfView.convert(convert(end, to: pdfView), to: page)
        let pageRect = rect(from: a, to: b)
        let bounds = page.bounds(for: .cropBox)
        let crop = CropRect(rect: pageRect, in: bounds)

        onCommit?(document.index(for: page) + 1, crop)
    }

    // MARK: - Drawing

    /// A number in the top-right corner of every visible page. Three states:
    ///
    /// - **Filled** — already attached to the row ⌘T is aimed at. These are the
    ///   slides on the card, which is the thing worth being able to see without
    ///   reading the chip row.
    /// - **Outlined** — where you are standing. Not on the card yet; this is the
    ///   one ⌘T would add.
    /// - **Quiet** — everything else.
    ///
    /// Every page carries a badge rather than only the interesting ones, because
    /// a lone badge tells you *a* slide matters without telling you it is this
    /// one, and the numbers earn their place anyway when a figure runs over
    /// three slides. Colour is what separates them.
    ///
    /// **On the palette.** These colours are chosen against the page, not
    /// against the app. Studio keeps slides light so a lecture reads like a
    /// lightbox, so the badge sits on a pale surface in both themes and takes
    /// fixed page-relative inks; using the chrome's own ink would put a
    /// near-white number on a white slide the moment you switched to dark. The
    /// one theme value it does take is the accent, so the armed colour is the
    /// same amber the slide rows and the crop tool use.
    private func drawPageNumber(_ number: Int, on page: PDFPage,
                                isAttached: Bool, isCurrent: Bool,
                                isUncovered: Bool = false) {
        guard let pdfView else { return }
        let frame = convert(pdfView.convert(page.bounds(for: .cropBox), from: page),
                            from: pdfView)
        // Too small to land on, and on a thumbnail-sized page it would cover the
        // slide rather than label it.
        guard frame.width > 90, frame.height > 60 else { return }

        let emphasis = isAttached || isCurrent
        let ink: NSColor
        if isAttached {
            ink = NSColor(red: 0.114, green: 0.106, blue: 0.086, alpha: 1)
        } else if isCurrent {
            ink = accent.blended(withFraction: 0.45, of: .black) ?? accent
        } else {
            ink = NSColor(red: 0.42, green: 0.39, blue: 0.35, alpha: 0.9)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5,
                                                    weight: emphasis ? .semibold : .medium),
            .foregroundColor: ink
        ]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        let padding = NSSize(width: 7, height: 3)
        let pill = NSRect(x: frame.maxX - 9 - size.width - padding.width * 2,
                          y: frame.maxY - 9 - size.height - padding.height * 2,
                          width: size.width + padding.width * 2,
                          height: size.height + padding.height * 2)

        let shape = NSBezierPath(roundedRect: pill, xRadius: 4.5, yRadius: 4.5)
        (isAttached ? accent : NSColor.white.withAlphaComponent(0.78)).setFill()
        shape.fill()
        if isAttached {
            (accent.blended(withFraction: 0.3, of: .black) ?? accent).setStroke()
            shape.lineWidth = 1
        } else if isCurrent {
            accent.setStroke()
            shape.lineWidth = 1.5
        } else {
            NSColor.black.withAlphaComponent(0.14).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()

        // Where you are standing, on top of whatever else the badge is saying.
        //
        // Attached and current used to be indistinguishable from attached: both
        // drew the filled amber pill, so on a card whose slides you were
        // scrolling through, nothing on screen said which one you were looking
        // at. The ring sits outside the pill rather than changing it, so the
        // two facts stay separate -- the fill is still "this slide is on the
        // card", the ring is still "you are here".
        if isCurrent {
            let ring = NSBezierPath(roundedRect: pill.insetBy(dx: -3, dy: -3),
                                    xRadius: 7, yRadius: 7)
            ring.lineWidth = 1.5
            (isAttached
             ? NSColor(red: 0.114, green: 0.106, blue: 0.086, alpha: 0.85)
             : accent).setStroke()
            ring.stroke()
        }

        text.draw(at: NSPoint(x: pill.minX + padding.width, y: pill.minY + padding.height),
                  withAttributes: attributes)

        // A slide no question mentions. Beside the number rather than on it,
        // because it is a fact about your questions, not about the slide -- and
        // it has to be legible next to both states of the badge.
        if isUncovered {
            let size: CGFloat = 7
            let dot = NSRect(x: pill.minX - size - 5,
                             y: pill.midY - size / 2, width: size, height: size)
            NSColor(red: 0.710, green: 0.329, blue: 0.369, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let document = pdfView.document else { return }

        if let start = dragStart, let end = dragEnd {
            let live = rect(from: start, to: end)
            if live.width >= minimumDrag, live.height >= minimumDrag {
                // Dim everything outside the rectangle: the universal crop
                // affordance, and it needs no label. Drawn as four bands rather
                // than a fill punched through with .destinationOut, which
                // depends on the backing store having an alpha channel.
                NSColor.black.withAlphaComponent(0.45).setFill()
                for band in bounds.bands(around: live) { band.fill() }
                accent.setStroke()
                let path = NSBezierPath(rect: live)
                path.lineWidth = 1.5
                path.stroke()
            }
            return
        }

        for page in pdfView.visiblePages {
            let number = document.index(for: page) + 1
            let pageBox = page.bounds(for: .cropBox)
            drawPageNumber(number, on: page,
                           isAttached: armedPages.contains(number),
                           isCurrent: number == currentPage,
                           isUncovered: uncoveredPages.contains(number))

            func toView(_ rect: CropRect) -> NSRect {
                convert(pdfView.convert(rect.rect(in: pageBox), from: page), from: pdfView)
            }

            // Highlights, before anything this app draws on top of the slide.
            // PDFKit has been told not to draw them in its own pass; see
            // PDFEditing. It still draws them -- here, into a multiplying
            // context, so the shape is whatever the annotation says it is.
            let pageRect = convert(pdfView.convert(pageBox, from: page), from: pdfView)
            if pageBox.width > 0, pageBox.height > 0 {
                PDFEditing.drawHighlights(on: page) { context in
                    context.translateBy(x: pageRect.minX, y: pageRect.minY)
                    context.scaleBy(x: pageRect.width / pageBox.width,
                                    y: pageRect.height / pageBox.height)
                    context.translateBy(x: -pageBox.minX, y: -pageBox.minY)
                }
            }

            // Occlusion masks: filled, because a mask you can see through is a
            // mask you cannot judge. This is roughly what the card will look
            // like, which is the only way to know you have covered the label.
            for mask in masksForPage?(number) ?? [] {
                // Mid-drag, the region follows the mouse rather than the model:
                // the model only learns about it on mouse-up, and a rectangle
                // that stays put while you drag it reads as a dead control.
                let rect = maskDrag?.hit.id == mask.id
                    ? (maskDrag?.rect ?? toView(mask.rect))
                    : toView(mask.rect)
                // Three states, because with regions grouped into cards there
                // are three things worth telling apart: the one under the
                // pointer, the ones that will be revealed alongside it, and
                // everything else.
                let isHovered = mask.id == hoveredMaskID
                let sharesCard = !isHovered && hoveredMaskGroup != nil
                    && mask.group == hoveredMaskGroup
                let navy = NSColor(red: 0.118, green: 0.165, blue: 0.275, alpha: 0.88)
                let fill: NSColor
                if isHovered {
                    fill = accent.withAlphaComponent(0.88)
                } else if sharesCard {
                    // Halfway to the resting colour: clearly related to the
                    // hovered one without competing with it.
                    fill = accent.blended(withFraction: 0.55, of: navy)?
                        .withAlphaComponent(0.88) ?? navy
                } else {
                    fill = navy
                }
                fill.setFill()
                rect.fill()
                (isHovered || sharesCard ? NSColor.white : accent).setStroke()
                let outline = NSBezierPath(rect: rect)
                outline.lineWidth = isHovered ? 2.5 : 1.5
                outline.stroke()

                // Handles, on the one you are pointing at only. Showing eight
                // of them on every region would bury the slide under furniture;
                // showing them on the one under the mouse is enough to say the
                // thing can be grabbed.
                if isHovered || maskDrag?.hit.id == mask.id {
                    for (_, box) in Self.grips(for: rect) {
                        NSColor.white.setFill()
                        let knob = NSBezierPath(ovalIn: box.insetBy(dx: 1.5, dy: 1.5))
                        knob.fill()
                        accent.blended(withFraction: 0.35, of: .black)?.setStroke()
                        knob.lineWidth = 1
                        knob.stroke()
                    }
                }
            }

            // Committed crops: the same dimming as the drag, at a fraction of
            // the strength. Strong enough to see what the card will contain
            // without looking anything up, light enough to still read the slide
            // you are writing about.
            //
            // Dimmed within the page, not the whole pane -- the crop belongs to
            // one slide, and greying the neighbouring slides would say something
            // untrue about them.
            if let crop = cropForPage?(number), !crop.isFullPage {
                let cropRect = toView(crop)
                let pageRect = convert(pdfView.convert(pageBox, from: page), from: pdfView)
                NSColor.black.withAlphaComponent(0.20).setFill()
                for band in pageRect.bands(around: cropRect) { band.fill() }
                accent.withAlphaComponent(0.9).setStroke()
                let path = NSBezierPath(rect: cropRect)
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension NSRect {
    /// The four bands of this rect that lie outside `hole`.
    func bands(around hole: NSRect) -> [NSRect] {
        let clipped = hole.intersection(self)
        guard !clipped.isEmpty else { return [self] }
        return [
            NSRect(x: minX, y: clipped.maxY, width: width, height: maxY - clipped.maxY),
            NSRect(x: minX, y: minY, width: width, height: clipped.minY - minY),
            NSRect(x: minX, y: clipped.minY, width: clipped.minX - minX, height: clipped.height),
            NSRect(x: clipped.maxX, y: clipped.minY, width: maxX - clipped.maxX, height: clipped.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
