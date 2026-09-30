import Foundation
import AppKit
import PDFKit

/// The card list behind ⌘P, and the machinery to draw its slides.
///
/// It renders through the same `PageRenderer` and the same `CardComposition` the
/// exporter uses, into the same on-disk cache. So the preview cannot drift from
/// the deck, and proofing a lecture warms the cache the next export would have
/// built anyway.
///
/// It holds no scheduling and writes nothing. Reviewing here is for catching a
/// crop that clipped a label or a mask over the wrong structure — Anki does
/// spaced repetition, and two review histories would be worse than one.
@MainActor
final class PreviewSession: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let question: Question
        let masks: [Mask]
        let lecture: String
        let pdfURL: URL
        /// 1 of 6, for a question that makes six cards.
        let ordinal: Int?
        let ordinalTotal: Int?
        /// Which `{{cN::}}` this card tests. Cloze only; nil everywhere else.
        let clozeOrdinal: Int?
    }

    @Published private(set) var items: [Item] = []
    @Published var index = 0
    @Published var revealed = false

    private let renderer: PageRenderer
    private var documents: [URL: (document: PDFDocument, sha: String)] = [:]
    private var images: [CardComposition.ImageSpec: NSImage] = [:]

    init(settings: AppSettings, cacheDirectory: URL) {
        self.renderer = PageRenderer(cacheDirectory: cacheDirectory, settings: settings)
    }

    // MARK: - Building

    /// Jump to the first card of a question, if it is in the deck being previewed.
    ///
    /// The point of ⌘P is usually "does the one I just wrote look right", and
    /// making you scroll past forty cards to find out is the difference between
    /// a proofing tool and a novelty. Returns false when the question isn't in
    /// this scope, so the caller can leave the deck at the start rather than
    /// silently landing somewhere arbitrary.
    @discardableResult
    func jump(toQuestion qid: String) -> Bool {
        guard let position = items.firstIndex(where: { $0.question.qid == qid }) else { return false }
        index = position
        revealed = false
        return true
    }

    func load(lectures: [URL]) {
        var built: [Item] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for pdfURL in lectures {
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            guard let data = try? Data(contentsOf: sidecar),
                  let file = try? decoder.decode(SidecarFile.self, from: data) else { continue }
            let lecture = pdfURL.lectureName

            for question in file.questions where !question.isEmpty {
                // Cloze is the one kind that makes several cards from one note
                // rather than several notes, so it doesn't go through
                // `noteVariants` -- the cards are the ordinals in its text.
                if question.kind == .cloze {
                    let ordinals = question.clozeOrdinals
                    for (offset, ordinal) in ordinals.enumerated() {
                        built.append(Item(
                            id: "\(question.qid)#c\(ordinal)",
                            question: question,
                            masks: [],
                            lecture: lecture,
                            pdfURL: pdfURL,
                            ordinal: ordinals.count > 1 ? offset + 1 : nil,
                            ordinalTotal: ordinals.count > 1 ? ordinals.count : nil,
                            clozeOrdinal: ordinal
                        ))
                    }
                    continue
                }

                let variants = question.noteVariants
                for (offset, variant) in variants.enumerated() {
                    built.append(Item(
                        id: question.guid(variant: variant.variant),
                        question: question,
                        masks: variant.masks,
                        lecture: lecture,
                        pdfURL: pdfURL,
                        ordinal: variants.count > 1 ? offset + 1 : nil,
                        ordinalTotal: variants.count > 1 ? variants.count : nil,
                        clozeOrdinal: nil
                    ))
                }
            }
        }
        items = built
        index = 0
        revealed = false
    }

    func shuffle() {
        items.shuffle()
        index = 0
        revealed = false
    }

    // MARK: - Moving

    var current: Item? { items.indices.contains(index) ? items[index] : nil }

    func advance() {
        guard !items.isEmpty else { return }
        if !revealed { revealed = true; return }
        index = (index + 1) % items.count
        revealed = false
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
        revealed = false
    }

    // MARK: - Drawing

    func composition(for item: Item) -> (front: [CardComposition.ImageSpec], back: [CardComposition.ImageSpec]) {
        CardComposition.images(for: item.question, masks: item.masks)
    }

    /// Renders through the shared cache. Slow the first time a slide is seen,
    /// instant afterwards -- and the file it writes is the one the exporter will
    /// put in the package.
    func image(_ spec: CardComposition.ImageSpec, in pdfURL: URL) -> NSImage? {
        if let cached = images[spec] { return cached }
        guard let context = context(for: pdfURL) else { return nil }
        guard let url = renderer.image(for: context.document, pdfSha256: context.sha,
                                       page: spec.page, crop: spec.crop, masks: spec.masks),
              let image = NSImage(contentsOf: url) else { return nil }
        images[spec] = image
        return image
    }

    private func context(for pdfURL: URL) -> (document: PDFDocument, sha: String)? {
        if let existing = documents[pdfURL] { return existing }
        guard let document = PDFDocument(url: pdfURL) else { return nil }
        let sha = LectureDocument.sha256OfFile(at: pdfURL)
        documents[pdfURL] = (document, sha)
        return (document, sha)
    }

    func text(for item: Item, templates: [Template]) -> (front: String, back: String) {
        let template = templates.first { $0.id == item.question.templateId }
        switch item.question.kind {
        case .cloze:
            // Front: the tested deletion becomes [...], every other one shows
            // its answer -- which is what Anki's {{cloze:…}} does. Back: the
            // same sentence with the tested answer filled into those brackets,
            // so the two sides line up and you can see which one it was.
            let ordinal = item.clozeOrdinal ?? 1
            let front = Cloze.front(item.question.front, ordinal: ordinal)
            var back = Cloze.back(item.question.front, ordinal: ordinal) { "[\($0)]" }
            let explanation = item.question.back.trimmingCharacters(in: .whitespacesAndNewlines)
            if !explanation.isEmpty { back += "\n\n" + explanation }
            return (front, back)
        case .template:
            guard let template else { return (item.question.front, item.question.back) }
            let rendered = template.render(blanks: item.question.blanks)
            return (rendered.front, rendered.back.isEmpty ? item.question.back : rendered.back)
        default:
            return (item.question.front, item.question.back)
        }
    }
}
