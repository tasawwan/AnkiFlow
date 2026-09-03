import Foundation
import CoreGraphics
import CryptoKit

enum QuestionKind: String, Codable {
    case basic
    case slide2slide
    case template
    case occlusion
}

/// One hidden region on an occlusion slide.
///
/// The id is a ULID, assigned once and never reused, because it becomes part of
/// the Anki GUID of the card this mask produces. Numbering masks by their
/// position in the array would look identical and quietly reshuffle review
/// history the first time you deleted one from the middle.
struct Mask: Codable, Equatable, Identifiable {
    var id: String
    var rect: CropRect

    init(rect: CropRect) {
        self.id = ULID.generate()
        self.rect = rect
    }
}

/// How an occlusion question becomes cards.
///
/// Both are rendered here rather than handed to Anki's own image-occlusion note
/// type. That note type is cloze-based and stores its shapes in a field whose
/// format Anki does not document, so building on it would mean depending on an
/// internal detail that can change in a point release. Baked images work on
/// every Anki version and need no note type but the one this app already has.
enum OcclusionMode: String, Codable, CaseIterable, Identifiable {
    /// One card: everything hidden on the front, everything visible on the back.
    case allAtOnce
    /// One card per region. The front hides everything, with the region this
    /// card is asking about marked in a different colour; the back shows
    /// everything, with that same region boxed in that colour.
    case separate

    var id: String { rawValue }

    var label: String {
        switch self {
        // Phrased to follow the word "Reveal:" in the panel, and to describe
        // what studying feels like rather than what the exporter does. The card
        // count underneath already says how many cards it becomes.
        case .allAtOnce: return "All at once"
        case .separate:  return "One at a time"
        }
    }
}

/// What the exporter last wrote for this question. Drives the merge discipline:
/// a note is only updated by Anki when its `mod` is strictly newer than the copy
/// already in the collection, so we track what we last stamped.
struct ExportRecord: Codable, Equatable {
    var contentHash: String
    var mod: Int
}

/// A crop, in normalized page coordinates: fractions of the page's crop box,
/// origin bottom-left to match PDF and Core Graphics.
///
/// Normalized rather than points, deliberately. A rect in points is only
/// meaningful against the page size it was drawn on, so it would quietly point
/// at the wrong region the moment a slide is re-rendered at a different width or
/// the PDF is replaced by a version whose page box differs -- which is exactly
/// what a continuously annotated lecture is.
struct CropRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Clamped on the way in, and never smaller than 2% of the page: a
    /// zero-area crop renders an empty image, which reads as a broken card
    /// rather than as a slip of the mouse.
    init(x: Double, y: Double, width: Double, height: Double) {
        let left = min(max(x, 0), 1)
        let bottom = min(max(y, 0), 1)
        self.x = left
        self.y = bottom
        self.width = min(max(width, 0.02), max(0.02, 1 - left))
        self.height = min(max(height, 0.02), max(0.02, 1 - bottom))
    }

    var isFullPage: Bool {
        x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999
    }

    /// Short, stable and filename-safe. Two different crops of one slide must
    /// never produce the same media filename -- see PageRenderer.
    var fingerprint: String {
        func mil(_ value: Double) -> Int { Int((value * 1000).rounded()) }
        return String(format: "%03d%03d%03d%03d", mil(x), mil(y), mil(width), mil(height))
    }

    /// For the mask list: "38% × 12% at 21%, 64%" is meaningless, so this says
    /// where it is in plain terms instead.
    var summary: String {
        let across = x + width / 2 < 0.4 ? "left" : (x + width / 2 > 0.6 ? "right" : "centre")
        let down = y + height / 2 > 0.6 ? "top" : (y + height / 2 < 0.4 ? "bottom" : "middle")
        return "\(down) \(across)"
    }

    /// Resolved against a page box, which is where the normalization pays off.
    func rect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.origin.x + x * bounds.width,
               y: bounds.origin.y + y * bounds.height,
               width: width * bounds.width,
               height: height * bounds.height)
    }

    /// The inverse: a rect drawn in page space becomes a stored crop.
    init(rect: CGRect, in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else {
            self.init(x: 0, y: 0, width: 1, height: 1)
            return
        }
        self.init(x: Double((rect.origin.x - bounds.origin.x) / bounds.width),
                  y: Double((rect.origin.y - bounds.origin.y) / bounds.height),
                  width: Double(rect.width / bounds.width),
                  height: Double(rect.height / bounds.height))
    }
}

struct Question: Codable, Identifiable, Equatable {
    var qid: String
    var kind: QuestionKind
    var templateId: String?
    var front: String
    var back: String
    var blanks: [String: String]
    /// 1-based PDF page numbers. Front-side slides (Slide2Slide only).
    var questionPages: [Int]
    /// 1-based PDF page numbers. The answer stack.
    var answerPages: [Int]
    /// Per-page crops, keyed by page number. A page with no entry is shown whole.
    ///
    /// Two dictionaries rather than one because Slide2Slide can legitimately
    /// cite the same page on both sides, and a single map keyed by page number
    /// could not tell the front's crop from the back's.
    var questionCrops: [Int: CropRect]
    var answerCrops: [Int: CropRect]
    /// Occlusion only. Order is display order; identity is the mask's id.
    var masks: [Mask]
    var occlusionMode: OcclusionMode
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var export: ExportRecord?
    /// Export records for the extra notes a `.separate` occlusion question
    /// produces, keyed by mask id. `export` covers every other question, which
    /// produces exactly one note.
    var childExports: [String: ExportRecord]

    var id: String { qid }

    enum CodingKeys: String, CodingKey {
        case qid, templateId, front, back, blanks
        case questionPages, answerPages, questionCrops, answerCrops
        case masks, occlusionMode, childExports
        case tags, createdAt, updatedAt, export
        case kind = "type"
    }

    init(kind: QuestionKind, templateId: String? = nil, seedPage: Int? = nil) {
        self.qid = ULID.generate()
        self.kind = kind
        self.templateId = templateId
        self.front = ""
        self.back = ""
        self.blanks = [:]
        self.questionPages = []
        self.answerPages = seedPage.map { [$0] } ?? []
        self.questionCrops = [:]
        self.answerCrops = [:]
        self.masks = []
        self.occlusionMode = .separate
        self.childExports = [:]
        self.tags = []
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.export = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qid = try c.decode(String.self, forKey: .qid)
        kind = try c.decodeIfPresent(QuestionKind.self, forKey: .kind) ?? .basic
        templateId = try c.decodeIfPresent(String.self, forKey: .templateId)
        front = try c.decodeIfPresent(String.self, forKey: .front) ?? ""
        back = try c.decodeIfPresent(String.self, forKey: .back) ?? ""
        blanks = try c.decodeIfPresent([String: String].self, forKey: .blanks) ?? [:]
        questionPages = try c.decodeIfPresent([Int].self, forKey: .questionPages) ?? []
        answerPages = try c.decodeIfPresent([Int].self, forKey: .answerPages) ?? []
        questionCrops = Question.intKeyed(
            try c.decodeIfPresent([String: CropRect].self, forKey: .questionCrops) ?? [:])
        answerCrops = Question.intKeyed(
            try c.decodeIfPresent([String: CropRect].self, forKey: .answerCrops) ?? [:])
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        export = try c.decodeIfPresent(ExportRecord.self, forKey: .export)
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        occlusionMode = try c.decodeIfPresent(OcclusionMode.self, forKey: .occlusionMode) ?? .separate
        childExports = try c.decodeIfPresent([String: ExportRecord].self, forKey: .childExports) ?? [:]
    }

    /// Written by hand rather than synthesized for one reason: Swift encodes a
    /// dictionary with Int keys as a flat [key, value, key, value] array, which
    /// is unreadable in a file people are meant to be able to open. Crops go out
    /// keyed by the page number as a string, and are omitted entirely when
    /// empty -- so a lecture with no crops produces byte-for-byte the sidecar
    /// this app has always written.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(qid, forKey: .qid)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(templateId, forKey: .templateId)
        try c.encode(front, forKey: .front)
        try c.encode(back, forKey: .back)
        try c.encode(blanks, forKey: .blanks)
        try c.encode(questionPages, forKey: .questionPages)
        try c.encode(answerPages, forKey: .answerPages)
        if !questionCrops.isEmpty {
            try c.encode(Question.stringKeyed(questionCrops), forKey: .questionCrops)
        }
        if !answerCrops.isEmpty {
            try c.encode(Question.stringKeyed(answerCrops), forKey: .answerCrops)
        }
        if !masks.isEmpty {
            try c.encode(masks, forKey: .masks)
            try c.encode(occlusionMode, forKey: .occlusionMode)
        }
        if !childExports.isEmpty { try c.encode(childExports, forKey: .childExports) }
        try c.encode(tags, forKey: .tags)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(export, forKey: .export)
    }

    static func stringKeyed(_ crops: [Int: CropRect]) -> [String: CropRect] {
        Dictionary(uniqueKeysWithValues: crops.map { (String($0.key), $0.value) })
    }

    static func intKeyed(_ crops: [String: CropRect]) -> [Int: CropRect] {
        var out: [Int: CropRect] = [:]
        for (key, value) in crops {
            if let page = Int(key) { out[page] = value }
        }
        return out
    }

    // MARK: - Crops

    func crop(page: Int, row: ArmedRow) -> CropRect? {
        row == .question ? questionCrops[page] : answerCrops[page]
    }

    mutating func setCrop(_ crop: CropRect?, page: Int, row: ArmedRow) {
        switch row {
        case .question: questionCrops[page] = crop
        case .answer:   answerCrops[page] = crop
        }
    }

    /// Move every page reference through a remap, dropping any whose slide is
    /// gone. Crops travel with their page; masks travel with the occlusion page,
    /// which is one of these lists.
    /// A page the map says nothing about stays where it is.
    ///
    /// The alternative -- dropping it -- means a mapping that happens to be
    /// short quietly deletes slides from questions with nothing said about it.
    /// Removing a page has to be something the map states, not something it
    /// omits.
    mutating func remapPages(_ map: [Int: Int]) {
        questionPages = PageSet.normalise(questionPages.map { map[$0] ?? $0 })
        answerPages = PageSet.normalise(answerPages.map { map[$0] ?? $0 })
        questionCrops = Dictionary(uniqueKeysWithValues:
            questionCrops.map { page, crop in (map[page] ?? page, crop) })
        answerCrops = Dictionary(uniqueKeysWithValues:
            answerCrops.map { page, crop in (map[page] ?? page, crop) })
    }

    /// Stop citing a slide entirely, on both sides.
    mutating func removePage(_ page: Int) {
        questionPages.removeAll { $0 == page }
        answerPages.removeAll { $0 == page }
        questionCrops[page] = nil
        answerCrops[page] = nil
    }

    /// Drop crops for pages the question no longer cites. Without this a crop
    /// outlives its page, stays in `contentHash`, and re-exports a note that
    /// nothing visible has changed about.
    mutating func pruneCrops() {
        guard !questionCrops.isEmpty || !answerCrops.isEmpty else { return }
        let front = Set(questionPages)
        let back = Set(answerPages)
        questionCrops = questionCrops.filter { front.contains($0.key) }
        answerCrops = answerCrops.filter { back.contains($0.key) }
    }

    // MARK: - Occlusion

    /// The slide an occlusion question masks. Occlusion is inherently one image.
    var occlusionPage: Int? {
        answerPages.first ?? questionPages.first
    }

    /// The notes this question produces. Everything except a `.separate`
    /// occlusion makes exactly one; that makes one per mask, each with its own
    /// GUID so Anki merges and schedules them independently.
    var noteVariants: [(variant: String, mask: Mask?)] {
        guard kind == .occlusion, occlusionMode == .separate, !masks.isEmpty else {
            return [(variant: "", mask: nil)]
        }
        return masks.map { (variant: $0.id, mask: $0) }
    }

    /// The Anki GUID for one produced note. Derived from the question's ULID and
    /// the mask's, so it is the same string on every future export -- which is
    /// the entire basis of the merge.
    func guid(variant: String) -> String {
        variant.isEmpty ? qid : "\(qid)#\(variant)"
    }

    func exportRecord(variant: String) -> ExportRecord? {
        variant.isEmpty ? export : childExports[variant]
    }

    mutating func setExportRecord(_ record: ExportRecord, variant: String) {
        if variant.isEmpty {
            export = record
        } else {
            childExports[variant] = record
        }
    }

    /// Every page this question cites, in order, deduplicated.
    var allPages: [Int] {
        var seen = Set<Int>()
        return (questionPages + answerPages).filter { seen.insert($0).inserted }
    }

    /// True when there is nothing worth exporting yet.
    var isEmpty: Bool {
        front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blanks.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && questionPages.isEmpty
            && answerPages.isEmpty
    }

    /// A short label for the question list.
    func summary(template: Template?) -> String {
        let text: String
        switch kind {
        case .basic, .slide2slide, .occlusion:
            text = front
        case .template:
            text = template.map { $0.render(blanks: blanks).front } ?? front
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if kind == .occlusion, let page = occlusionPage {
            return masks.count == 1
                ? "Slide \(page) · 1 region"
                : "Slide \(page) · \(masks.count) regions"
        }
        // allPages, not questionPages: a Basic question keeps its slides on the
        // answer side, so the old check never fired and every untitled Basic
        // question said "Untitled" even with fifteen slides attached.
        if !allPages.isEmpty { return "Slides \(PageSet.describe(allPages))" }
        return "Untitled question"
    }

    /// Hash of everything that changes the rendered card. Anything not in here
    /// can change freely without provoking an Anki update.
    /// `pdfFingerprint` is what makes an edited PDF -- annotations added, a
    /// slide replaced -- actually reach your cards. Media filenames derive from
    /// the PDF's hash, so if it changes the images change; without the
    /// fingerprint here the exporter would call the note unchanged and Anki
    /// would keep showing the old, now-orphaned images.
    func contentHash(template: Template?, renderVersion: Int, pdfFingerprint: String,
                     variant: String = "") -> String {
        var parts: [String] = [
            "v\(renderVersion)",
            pdfFingerprint,
            kind.rawValue,
            templateId ?? "",
            front,
            back,
            questionPages.map(String.init).joined(separator: ","),
            answerPages.map(String.init).joined(separator: ","),
            // Crops change the picture, so they have to change the hash --
            // otherwise adjusting one leaves `mod` untouched, Anki treats the
            // note as a duplicate, and the card keeps the old image forever.
            Question.cropsFingerprint(questionCrops),
            Question.cropsFingerprint(answerCrops),
            // Every mask affects every card of an occlusion question, because
            // the front hides all of them -- so all of them belong in each
            // card's hash, along with which one this card is asking about.
            Question.masksFingerprint(masks),
            occlusionMode.rawValue,
            variant,
            tags.sorted().joined(separator: ",")
        ]
        for key in blanks.keys.sorted() {
            parts.append("\(key)=\(blanks[key] ?? "")")
        }
        if let template {
            parts.append(template.fingerprint)
        }
        let joined = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Question {
    static func masksFingerprint(_ masks: [Mask]) -> String {
        masks.map { "\($0.id):\($0.rect.fingerprint)" }.joined(separator: ";")
    }

    static func cropsFingerprint(_ crops: [Int: CropRect]) -> String {
        crops.keys.sorted().compactMap { page in
            crops[page].map { "\(page):\($0.fingerprint)" }
        }.joined(separator: ";")
    }
}

/// Helpers for turning page lists into the "12–18, 22" form and back.
enum PageSet {
    static func normalise(_ pages: [Int]) -> [Int] {
        Array(Set(pages.filter { $0 > 0 })).sorted()
    }

    /// "12–18, 22, 30–31"
    static func describe(_ pages: [Int]) -> String {
        let sorted = normalise(pages)
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var runStart = sorted[0]
        var previous = sorted[0]
        for page in sorted.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            parts.append(runStart == previous ? "\(runStart)" : "\(runStart)–\(previous)")
            runStart = page
            previous = page
        }
        parts.append(runStart == previous ? "\(runStart)" : "\(runStart)–\(previous)")
        return parts.joined(separator: ", ")
    }

    /// Accepts "12-18, 22" and "12–18 22" alike. Anything unparseable is ignored
    /// rather than rejected, so typing into the field never blocks you mid-edit.
    static func parse(_ text: String, pageCount: Int) -> [Int] {
        var pages: [Int] = []
        let separators = CharacterSet(charactersIn: ", ;\n\t")
        for chunk in text.components(separatedBy: separators) where !chunk.isEmpty {
            let normalised = chunk.replacingOccurrences(of: "–", with: "-")
                                  .replacingOccurrences(of: "—", with: "-")
            let bounds = normalised.components(separatedBy: "-").compactMap { Int($0) }
            if bounds.count == 1 {
                pages.append(bounds[0])
            } else if bounds.count >= 2 {
                let lower = min(bounds[0], bounds[1])
                let upper = max(bounds[0], bounds[1])
                if upper - lower <= 2000 { pages.append(contentsOf: lower...upper) }
            }
        }
        return normalise(pages).filter { $0 <= pageCount }
    }

    /// The anchor-extend gesture: every page from the anchor to where you are now.
    static func extend(from anchor: Int, to current: Int) -> [Int] {
        let lower = min(anchor, current)
        let upper = max(anchor, current)
        return Array(lower...upper)
    }
}
