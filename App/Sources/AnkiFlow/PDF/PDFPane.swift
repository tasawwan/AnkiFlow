import SwiftUI
import PDFKit
import AppKit

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
}

/// The PDF viewer. Two-way bound to the current page so ⌘↓ / ⌘↑ can drive it
/// from anywhere in the app -- including while the cursor sits in a text field,
/// which is the single most important binding in the product.
struct PDFPane: NSViewRepresentable {
    @Environment(\.palette) private var palette
    let box: PDFViewBox
    let document: PDFDocument?
    @Binding var currentPage: Int   // 1-based
    /// The committed crop for a page on the armed row, or nil for the whole slide.
    var cropForPage: (Int) -> CropRect? = { _ in nil }
    /// Occlusion masks on this page, drawn so you can see what you have hidden.
    var masksForPage: (Int) -> [CropRect] = { _ in [] }
    var onCrop: (Int, CropRect) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = box.view
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

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = box.view
        view.backgroundColor = NSColor(palette.field)
        view.pageShadowsEnabled = palette.pageShadowRadius > 0

        if let overlay = context.coordinator.overlay {
            overlay.accent = NSColor(palette.amber)
            overlay.cropForPage = cropForPage
            overlay.masksForPage = masksForPage
            overlay.onCommit = onCrop
            overlay.needsDisplay = true
        }
        if view.document !== document {
            view.document = document
            context.coordinator.lastReportedPage = 0
        }
        guard let document else { return }

        let index = currentPage - 1
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
        if view.currentPage !== page {
            context.coordinator.suppressCallback = true
            view.go(to: page)
            context.coordinator.suppressCallback = false
        }
    }

    final class Coordinator: NSObject {
        @Binding var currentPage: Int
        var suppressCallback = false
        var lastReportedPage = 0
        weak var overlay: CropOverlayView?
        private weak var view: PDFView?

        init(currentPage: Binding<Int>) {
            _currentPage = currentPage
        }

        func attach(to view: PDFView) {
            guard self.view !== view else { return }
            self.view = view
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc private func pageChanged(_ note: Notification) {
            guard !suppressCallback,
                  let view,
                  let document = view.document,
                  let page = view.currentPage else { return }
            let number = document.index(for: page) + 1
            guard number != lastReportedPage else { return }
            lastReportedPage = number
            // Scrolling fires this often; hop to the next runloop so we never
            // mutate observed state during a SwiftUI view update.
            DispatchQueue.main.async { [weak self] in
                self?.currentPage = number
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

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = NSSize(width: 60, height: 80)
        // macOS has no `layoutMode`; a wide column count plus the short frame
        // ContentView gives this view produces the horizontal strip.
        view.maximumNumberOfColumns = 512
        view.backgroundColor = NSColor(palette.field)
        view.pdfView = box.view
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        view.backgroundColor = NSColor(palette.field)
        view.pdfView = box.view
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
final class CropOverlayView: NSView {
    weak var pdfView: PDFView?
    var accent: NSColor = .systemOrange
    /// Both are re-set from SwiftUI on every update, so they never hold a stale
    /// question or a stale armed row.
    var cropForPage: ((Int) -> CropRect?)?
    var masksForPage: ((Int) -> [CropRect])?
    var onCommit: ((Int, CropRect) -> Void)?

    private var observing = false
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var dragPage: PDFPage?

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
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSEvent.modifierFlags.contains(.option) else { return nil }
        return super.hitTest(point)
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

            func toView(_ rect: CropRect) -> NSRect {
                convert(pdfView.convert(rect.rect(in: pageBox), from: page), from: pdfView)
            }

            // Occlusion masks: filled, because a mask you can see through is a
            // mask you cannot judge. This is roughly what the card will look
            // like, which is the only way to know you have covered the label.
            for mask in masksForPage?(number) ?? [] {
                let rect = toView(mask)
                NSColor(red: 0.118, green: 0.165, blue: 0.275, alpha: 0.88).setFill()
                rect.fill()
                accent.setStroke()
                let outline = NSBezierPath(rect: rect)
                outline.lineWidth = 1.5
                outline.stroke()
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
