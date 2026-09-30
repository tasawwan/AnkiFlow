import Foundation
import CoreGraphics
import CryptoKit

enum QuestionKind: String, Codable {
    case basic
    case template
    case occlusion
    /// Text with `{{c1::…}}` deletions. Unlike every other kind this makes one
    /// note with several cards -- one per distinct ordinal -- and it is the only
    /// kind exported under the cloze note type. Slides attached to it appear on
    /// the back, as explanation after the answer is revealed.
    case cloze
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
    /// Which card hides this region. Regions sharing a group are hidden and
    /// revealed together, the way cloze blanks sharing an ordinal are.
    ///
    /// Numbers are handed out and never reused or renumbered. A group number is
    /// part of how a card is identified across exports, and closing the gaps
    /// after a delete -- which the cloze list does, because Anki cares about
    /// contiguous ordinals and nothing here does -- would silently re-point
    /// every card after the gap at different regions.
    var group: Int

    init(rect: CropRect, group: Int = 1) {
        self.id = ULID.generate()
        self.rect = rect
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rect = try c.decode(CropRect.self, forKey: .rect)
        // Absent in every file written before grouping existed. `Question`
        // fixes those up from `occlusionMode`, which is what used to carry this.
        group = try c.decodeIfPresent(Int.self, forKey: .group) ?? 0
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
    /// What the written text looked like when this note last went to Anki --
    /// the common ancestor, which is the only thing that makes a three-way
    /// merge possible.
    ///
    /// Without it, "the text here differs from the text in Anki" cannot tell
    /// you *which side moved*, and a sync can only ever guess. With it: their
    /// side differs from the base means Anki changed, my side differs from the
    /// base means the app changed, both means a genuine conflict worth asking
    /// about. One string per record, and it is a hash rather than the text
    /// itself so a sidecar doesn't carry a second copy of every card.
    ///
    /// Optional because a record written before a sync has ever run has no
    /// ancestor to name; those are treated as "no opinion", not as a conflict.
    var textHash: String?
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
    /// 1-based PDF page numbers. The slides shown with the question.
    var questionPages: [Int]
    /// 1-based PDF page numbers. The answer stack.
    var answerPages: [Int]
    /// Per-page crops, keyed by page number. A page with no entry is shown whole.
    ///
    /// Two dictionaries rather than one because a question can legitimately
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

    /// True when this question was decoded from a card type that no longer
    /// exists and was read as Basic instead.
    ///
    /// Not persisted and not in `CodingKeys` -- it lives just long enough for
    /// `LectureDocument` to notice and write the file back in the current shape.
    /// Without it the fallback is silent and permanent: every open would
    /// reinterpret the same stale value, and a file you had been using for
    /// months would still say `slide2slide` in it.
    var wasMigrated = false

    /// Which template's tab this question is sitting in, when the answer cannot
    /// be worked out from the text alone.
    ///
    /// Not persisted, and deliberately so. A template is a lens: a question
    /// built through one is an ordinary Basic card, and which tab it belongs in
    /// is re-derived from its text every time a library is opened. The one case
    /// text cannot answer is a question you have just made and not yet typed
    /// into -- empty text matches nothing -- so this holds the tab you made it
    /// on until there are words to recognise. It lives exactly as long as the
    /// session does, which is exactly as long as it is needed.
    var viewTemplateId: String?

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
        // Slide2Slide was folded into Basic once every card gained both slide
        // rows -- the two had become the same thing. Old question files still
        // say "slide2slide", and decoding one has to keep working: an unknown
        // kind would throw, and throwing here loses the whole lecture's
        // questions rather than one field.
        let storedKind = (try? c.decodeIfPresent(QuestionKind.self, forKey: .kind)).flatMap { $0 }
        kind = storedKind ?? .basic
        // A kind that failed to decode was one this app used to have. Flagged so
        // the document rewrites the file, rather than falling back to Basic
        // again on every open for the rest of the file's life.
        wasMigrated = storedKind == nil && c.contains(.kind)
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
        // A file from before groups existed says only "all at once" or "one at a
        // time". Both are groupings: one group holding everything, or a group
        // each. Written out this way the two old modes keep behaving exactly as
        // they did, and are now just two of the shapes you can make.
        if masks.contains(where: { $0.group == 0 }) {
            for index in masks.indices where masks[index].group == 0 {
                masks[index].group = occlusionMode == .allAtOnce ? 1 : index + 1
            }
        }
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
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: a page the map says
        // nothing about keeps its own number, and that number can be the one
        // some other page was mapped *to*. `uniqueKeysWithValues` traps on the
        // collision -- it crashed the app when a slide with a crop was deleted
        // and the slide after it moved up into its number. Keeping the lower
        // page's crop matches the page lists, which normalise the same way.
        // Sorted before folding, because a Dictionary iterates in hash order:
        // without this "first wins" would mean "whichever the hash happened to
        // hand over first", and two runs could keep different crops.
        questionCrops = Dictionary(
            questionCrops.sorted { $0.key < $1.key }.map { (map[$0.key] ?? $0.key, $0.value) },
            uniquingKeysWith: { first, _ in first })
        answerCrops = Dictionary(
            answerCrops.sorted { $0.key < $1.key }.map { (map[$0.key] ?? $0.key, $0.value) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Stop citing a slide entirely, on both sides. Returns the ids of any
    /// masks dropped along with it, so the caller can retire their cards.
    ///
    /// Masks go whenever the slide they were drawn on goes -- not only when the
    /// question is left with no pages at all. `occlusionPage` is just the first
    /// page the question cites, so a question citing slides 3 and 7 that loses
    /// slide 3 would otherwise keep masks drawn for slide 3 and quietly start
    /// applying them to slide 7, hiding whatever happens to be in those
    /// rectangles there.
    @discardableResult
    mutating func removePage(_ page: Int) -> [String] {
        let wasOcclusionPage = kind == .occlusion && occlusionPage == page
        questionPages.removeAll { $0 == page }
        answerPages.removeAll { $0 == page }
        questionCrops[page] = nil
        answerCrops[page] = nil
        guard wasOcclusionPage, !masks.isEmpty else { return [] }
        let dropped = masks.map(\.id)
        masks = []
        return dropped
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

    // MARK: - Cloze

    /// The ordinals this question's text contains, which is exactly the set of
    /// cards Anki will generate from it.
    var clozeOrdinals: [Int] {
        kind == .cloze ? Cloze.ordinals(in: front) : []
    }

    /// True when a cloze question has text but no `{{c1::…}}` in it yet.
    ///
    /// Worth its own name because it is the one way this app can produce a note
    /// Anki makes *no* cards for: a cloze note with no deletions imports fine
    /// and then sits in the collection invisible. The exporter skips these and
    /// the panel says so rather than letting one leave the building.
    var clozeHasNoDeletions: Bool {
        kind == .cloze && Cloze.ordinals(in: front).isEmpty
    }

    // MARK: - Occlusion

    /// The slide an occlusion question masks. Occlusion is inherently one image.
    var occlusionPage: Int? {
        answerPages.first ?? questionPages.first
    }

    /// The notes this question produces. Everything except a `.separate`
    /// occlusion makes exactly one; that makes one per mask, each with its own
    /// GUID so Anki merges and schedules them independently.
    /// The regions on each card, in group order.
    var maskGroups: [[Mask]] {
        guard kind == .occlusion, !masks.isEmpty else { return [] }
        var order: [Int] = []
        for mask in masks where !order.contains(mask.group) { order.append(mask.group) }
        return order.map { group in masks.filter { $0.group == group } }
    }

    /// The notes this question produces. Everything except an occlusion makes
    /// exactly one; an occlusion makes one per group, each with its own GUID so
    /// Anki merges and schedules them independently.
    ///
    /// A group's variant is its **first region's id**, not its group number.
    /// That keeps every card ever exported one-region-at-a-time exactly where it
    /// is -- its group holds only that region, so the variant is the same string
    /// it always was -- and it means adding a second region to a card keeps that
    /// card's review history rather than retiring it and starting again.
    var noteVariants: [(variant: String, masks: [Mask])] {
        guard kind == .occlusion, !masks.isEmpty else { return [(variant: "", masks: [])] }
        let groups = maskGroups
        // One group covering everything is the old "all at once", and that card
        // was exported with an empty variant. `occlusionMode` is what tells the
        // two single-group cases apart -- everything on one card, versus a
        // question that only ever had one region -- and it is kept in step for
        // exactly this, so both keep the GUID they already have.
        if groups.count == 1, occlusionMode == .allAtOnce {
            return [(variant: "", masks: groups[0])]
        }
        return groups.map { (variant: $0.first?.id ?? "", masks: $0) }
    }

    /// True when the regions are spread over more than one card.
    var isGrouped: Bool { maskGroups.count > 1 }

    /// One group holding everything -- the old "all at once".
    var isOneCard: Bool { maskGroups.count == 1 && masks.count > 1 }

    /// A region per card -- the old "one at a time".
    var isOnePerCard: Bool { !masks.isEmpty && maskGroups.count == masks.count }

    /// The next group number to hand out. One past the highest in use, so a
    /// number is never reused by a different set of regions.
    var nextMaskGroup: Int { (masks.map(\.group).max() ?? 0) + 1 }

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

    /// No words on it yet.
    ///
    /// Distinct from `isEmpty`, which also counts slides. A card you have
    /// attached a slide to but not typed into is not empty -- it is worth
    /// keeping -- but there is still no text for a template to recognise, and
    /// asking `isEmpty` that question put a half-made card out of its own tab
    /// the moment you pressed ⌘T.
    var hasNoText: Bool {
        front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case .basic, .occlusion:
            text = front
        case .cloze:
            // The markup would dominate a one-line label, so the list shows the
            // sentence as it reads with nothing hidden.
            text = Cloze.plainText(front)
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
        // A revision scoped to one kind of card.
        //
        // The library-wide `renderVersion` is the general tool for "the drawing
        // changed, re-render everything", and it is too big a hammer here: the
        // all-at-once answer gained boxes around the regions it had covered, and
        // nothing else in the library draws differently. Bumping the library
        // version would re-render and re-export every card in it to fix a
        // handful. This changes the hash for exactly the cards whose picture
        // changed. Bump the number if that drawing changes again.
        // `!masks.isEmpty` matters: with no masks both sides render as the bare
        // slide, the filenames are unchanged, and the card is byte-identical --
        // so there is nothing to re-export and no reason to say there is.
        if kind == .occlusion, occlusionMode == .allAtOnce, !masks.isEmpty {
            parts.append("allAtOnce-r2")
        }
        // Only when the grouping is something the two old modes could not
        // express. A region per card and everything on one card both hash
        // exactly as they always did, so nothing written before groups existed
        // re-exports for having been read by a version that understands them.
        if kind == .occlusion, isGrouped, !isOnePerCard {
            parts.append("groups:" + masks.map { "\($0.id):\($0.group)" }.joined(separator: ";"))
        }
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
    /// The written text alone -- what a person types, and what a person can
    /// also type into Anki. Deliberately excludes everything generated from the
    /// PDF: slides, crops, masks and media filenames have no counterpart in the
    /// Anki editor, so including them would report a conflict every time a
    /// lecture was re-annotated.
    ///
    /// Whitespace is trimmed on both sides of the comparison because Anki's
    /// editor adds and removes it freely, and a card is not "edited in Anki"
    /// for having gained a trailing newline.
    static func textFingerprint(front: String, back: String, tags: [String]) -> String {
        let parts = [
            front.trimmingCharacters(in: .whitespacesAndNewlines),
            back.trimmingCharacters(in: .whitespacesAndNewlines),
            tags.map { $0.lowercased() }.sorted().joined(separator: ",")
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var textFingerprint: String {
        Question.textFingerprint(front: front, back: back, tags: tags)
    }

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
