import Foundation
import PDFKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Renders PDF pages to card-sized images.
///
/// Filenames are deterministic -- same PDF, same page, same settings gives the
/// same name every time. That means media deduplicates automatically when six
/// questions cite the same slide, re-exports never pile up orphan copies in the
/// collection, and a name collision with another deck is effectively impossible.
struct PageRenderer {
    let cacheDirectory: URL
    let settings: LibrarySettings

    /// WebP encoding is not available on every macOS version, so ask rather than assume.
    static let webPSupported: Bool = {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(UTType.webP.identifier)
    }()

    var resolvedFormat: ImageFormat {
        switch settings.imageFormat {
        case .auto: return Self.webPSupported ? .webp : .jpeg
        default:    return settings.imageFormat
        }
    }

    var fileExtension: String {
        switch resolvedFormat {
        case .webp: return "webp"
        case .png:  return "png"
        default:    return "jpg"
        }
    }

    private var contentType: CFString {
        switch resolvedFormat {
        case .webp: return UTType.webP.identifier as CFString
        case .png:  return UTType.png.identifier as CFString
        default:    return UTType.jpeg.identifier as CFString
        }
    }

    /// `af_<pdf sha prefix>_p0012_w1600.webp`, or with a crop,
    /// `af_<pdf sha prefix>_p0012_c125250500400_w1600.webp`.
    ///
    /// The crop has to be in the name. Without it the cropped and uncropped
    /// renders of one slide share a filename, the cache hands back whichever
    /// was written first, and the card silently shows the wrong picture -- with
    /// no error anywhere, because from the cache's point of view nothing is
    /// wrong. Two different crops of one slide collide the same way.
    func mediaFileName(pdfSha256: String, page: Int, crop: CropRect? = nil,
                       masks: MaskPaint? = nil) -> String {
        let prefix = String(pdfSha256.prefix(8))
        let paddedPage = String(format: "%04d", page)
        var cropPart = ""
        if let crop, !crop.isFullPage { cropPart = "_c\(crop.fingerprint)" }
        var maskPart = ""
        if let masks, !masks.isEmpty { maskPart = "_m\(masks.fingerprint)" }
        // renderVersion is in the name as well as in the content hash. Without
        // it, changing a rendering setting that leaves the width and format
        // alone rewrites every note while the cache keeps serving the old
        // picture -- the cards change and the images don't.
        return "af_\(prefix)_p\(paddedPage)\(cropPart)\(maskPart)"
            + "_w\(settings.imageWidth)v\(settings.renderVersion).\(fileExtension)"
    }

    /// What to paint over a page before it becomes a card image.
    ///
    /// This is how occlusion works here: the masks are burned into the picture
    /// rather than described to Anki. Anki's own image-occlusion note type is
    /// cloze-based and stores shapes in an undocumented field format, so an
    /// exporter built on it would depend on an internal detail. A painted
    /// rectangle works on every version of Anki, forever.
    struct MaskPaint: Hashable {
        /// Filled opaque: hidden.
        var hidden: [CropRect] = []
        /// Filled opaque in the accent colour: hidden, and this is the region
        /// the card is asking about.
        var target: CropRect?
        /// Stroked, not filled: visible, and these are the regions the card
        /// asked about. One for a card testing a single region; all of them on
        /// the back of an all-at-once card, where the answer is "here is what
        /// was covered" and the boxes are what say where.
        var outlined: [CropRect] = []

        var isEmpty: Bool { hidden.isEmpty && target == nil && outlined.isEmpty }

        /// Every distinct combination of masks is a distinct image and must be a
        /// distinct filename -- six cards off one slide are six different
        /// pictures that would otherwise all be called the same thing.
        var fingerprint: String {
            var parts = hidden.map(\.fingerprint)
            parts.append("t" + (target?.fingerprint ?? "-"))
            // Spelled so that none and one produce exactly the strings the
            // single-rect version produced. Cards that were already right keep
            // their filenames, and only the all-at-once backs -- the ones whose
            // picture actually changed -- get new ones.
            parts.append("o" + (outlined.isEmpty
                                ? "-"
                                : outlined.map(\.fingerprint).joined(separator: "+")))
            let digest = SHA256.hash(data: Data(parts.joined(separator: ",").utf8))
            return digest.prefix(5).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Returns the URL of the rendered image, rendering it only if the cache
    /// does not already hold it. `page` is 1-based.
    @discardableResult
    func image(for document: PDFDocument, pdfSha256: String, page: Int,
               crop: CropRect? = nil, masks: MaskPaint? = nil) -> URL? {
        let name = mediaFileName(pdfSha256: pdfSha256, page: page, crop: crop, masks: masks)
        let destination = cacheDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return nil }
        guard let data = render(page: pdfPage, crop: crop, masks: masks) else { return nil }

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// #1E2A46 -- the app's own navy. A mask should read as something placed
    /// deliberately, not as a printing fault.
    private static let maskFill = CGColor(red: 0.118, green: 0.165, blue: 0.275, alpha: 1)
    /// #E0A03A -- amber, which in this app means "this is the bit that matters".
    private static let targetFill = CGColor(red: 0.878, green: 0.627, blue: 0.227, alpha: 1)

    private func render(page: PDFPage, crop: CropRect?, masks: MaskPaint? = nil) -> Data? {
        let box = PDFDisplayBox.cropBox
        let pageBounds = page.bounds(for: box)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        // The region actually drawn. Resolving the normalized crop here, against
        // this page's box, is what lets a stored crop survive a different render
        // width or a slightly different page size.
        let bounds = crop.map { $0.rect(in: pageBounds) } ?? pageBounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // A crop still fills the card's width, so it is drawn at a higher
        // effective resolution rather than upscaled -- the page is vector art,
        // so this costs nothing and a cropped detail comes out sharper.
        let scale = CGFloat(settings.imageWidth) / bounds.width
        let pixelWidth = settings.imageWidth
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        // Slides are drawn on white: a transparent background turns black on
        // Anki's dark theme, which is unreadable for most lecture slides.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        let flags = page.annotations.filter { annotation in
            PDFEditing.isFlag(annotation)
        }
        flags.forEach { $0.shouldDisplay = false }
        defer { flags.forEach { $0.shouldDisplay = true } }
        page.draw(with: box, to: context)

        if let masks, !masks.isEmpty {
            // Painted inside the same transform the page was drawn with, in page
            // coordinates -- so a mask lands exactly where it was dragged, at any
            // render width, and stays correct even when a crop is applied too.
            context.setFillColor(Self.maskFill)
            for rect in masks.hidden {
                context.fill(rect.rect(in: pageBounds))
            }
            if let target = masks.target {
                context.setFillColor(Self.targetFill)
                context.fill(target.rect(in: pageBounds))
            }
            if !masks.outlined.isEmpty {
                context.setStrokeColor(Self.targetFill)
                context.setLineWidth(max(2, pageBounds.width * 0.006))
                for rect in masks.outlined {
                    context.stroke(rect.rect(in: pageBounds))
                }
            }
        }
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, contentType, 1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if resolvedFormat == .jpeg || resolvedFormat == .webp {
            options[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func cacheSizeInBytes() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
