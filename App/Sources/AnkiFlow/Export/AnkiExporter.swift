import Foundation
import PDFKit
import CryptoKit

/// Everything the exporter needs about one lecture, gathered on the main actor
/// before the work starts.
struct LecturePlan {
    let pdfURL: URL
    let pdfSha256: String
    let deckName: String
    let pathTag: String
    let sourceLabel: String
    let document: PDFDocument
    var questions: [Question]
    /// Where this lecture went last time, from its own sidecar.
    let previousDeckName: String?
    /// Questions deleted from this lecture since it was last exported.
    let retiredQIDs: [String]
}

/// Writes an .apkg.
///
/// The merge behaviour this implements was verified against the real Anki
/// library (26.08.1) rather than inferred from documentation. Three findings
/// shape the code:
///
/// 1. Anki matches notes on GUID and preserves the card's scheduling when it
///    updates one. So the question's permanent QID is used as the GUID verbatim.
/// 2. A note is only updated when its `mod` is **strictly newer** than the copy
///    already in the collection. Equal timestamps are silently classified as
///    duplicates and skipped -- and their new media is skipped with them, which
///    shows up as a card with a missing image. Hence `stampModification`.
/// 3. Changing the note type breaks updates outright. Hence the frozen field
///    list in AnkiIdentity, and the single card template.
@MainActor
struct AnkiExporter {
    let libraryRoot: URL
    let settings: LibrarySettings
    let templates: [Template]

    /// Returns the summary plus the lectures with their export records updated,
    /// so the caller can persist them.
    func export(plans: [LecturePlan], to destination: URL) throws -> (ExportSummary, [LecturePlan]) {
        var summary = ExportSummary()
        var updatedPlans: [LecturePlan] = []

        let renderer = PageRenderer(
            cacheDirectory: LibraryPaths.cacheDirectory(inLibrary: libraryRoot),
            settings: settings
        )

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ankiflow-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let databaseURL = workDirectory.appendingPathComponent("collection.anki2")
        let database = try SQLiteDB(path: databaseURL.path)
        try createSchema(database)

        var deckIDs: [String: Int64] = ["1": 1]
        var decksJSON: [String: Any] = ["1": defaultDeckJSON()]
        var mediaFiles: [String: URL] = [:]      // media filename -> source on disk
        var noteCounter = Int64(Date().timeIntervalSince1970 * 1000)
        var cardPosition = 0
        let now = Int(Date().timeIntervalSince1970)

        for originalPlan in plans {
            var plan = originalPlan
            let deckID = Self.deckID(for: plan.deckName)
            deckIDs[String(deckID)] = deckID
            decksJSON[String(deckID)] = deckJSON(id: deckID, name: plan.deckName)
            summary.deckCount += 1

            for index in plan.questions.indices {
                var question = plan.questions[index]
                guard !question.isEmpty else { continue }

                let template = templateLookup(question.templateId)

                // One question is usually one note. A `.separate` occlusion
                // question makes one note per mask, each with its own GUID, so
                // Anki schedules and merges them independently.
                for (variant, mask) in question.noteVariants {
                let hash = question.contentHash(
                    template: template,
                    renderVersion: settings.renderVersion,
                    pdfFingerprint: String(plan.pdfSha256.prefix(8)),
                    variant: variant
                )

                // --- the merge discipline, findings 2 and 3 above -------------
                let previous = question.exportRecord(variant: variant)
                let modification: Int
                if let previous, previous.contentHash == hash {
                    // Unchanged. Re-stamp the same mod so Anki correctly skips it.
                    modification = previous.mod
                    summary.unchangedNotes += 1
                } else {
                    // Changed, or new. Guarantee strictly newer than last time --
                    // `now` alone is not enough when two exports land in the same
                    // second, which is exactly the case that fails silently.
                    modification = max(now, (previous?.mod ?? 0) + 1)
                    if previous == nil { summary.newNotes += 1 } else { summary.changedNotes += 1 }
                }
                question.setExportRecord(ExportRecord(contentHash: hash, mod: modification),
                                         variant: variant)
                plan.questions[index] = question
                // --------------------------------------------------------------

                // Render every cited page, reusing the cache.
                // Composition lives in one place so the preview shows exactly
                // what gets exported -- see CardComposition.
                let composition = CardComposition.images(for: question, mask: mask)
                var frontImages: [String] = []
                var backImages: [String] = []
                for spec in composition.front {
                    if let name = attach(page: spec.page, crop: spec.crop, masks: spec.masks,
                                         plan: plan, renderer: renderer, into: &mediaFiles) {
                        frontImages.append(name)
                    }
                }
                for spec in composition.back {
                    if let name = attach(page: spec.page, crop: spec.crop, masks: spec.masks,
                                         plan: plan, renderer: renderer, into: &mediaFiles) {
                        backImages.append(name)
                    }
                }

                let rendered = renderText(question: question, template: template)
                let sourceText = "\(plan.sourceLabel) · \(pagesLabel(question))"
                let guid = question.guid(variant: variant)

                let fields = [
                    rendered.front,
                    imageStack(frontImages),
                    rendered.back,
                    imageStack(backImages),
                    searchText(for: question, plan: plan),
                    escapeHTML(sourceText),
                    guid
                ]

                var tags = question.tags
                tags.append(plan.pathTag)
                // Anki stores tags space-delimited with leading and trailing
                // spaces. `tags` always has the path tag, so it is never empty.
                let tagString = " " + tags.map { $0.replacingOccurrences(of: " ", with: "-") }
                    .joined(separator: " ") + " "

                let sortField = stripHTML(fields[0])
                noteCounter += 1
                let noteID = noteCounter

                try database.run(
                    "INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    [
                        .int(noteID),
                        .text(guid),                               // GUID: the merge key
                        .int(AnkiIdentity.noteTypeID),
                        .int(Int64(modification)),
                        .int(-1),
                        .text(tagString),
                        .text(fields.joined(separator: "\u{1F}")),
                        .text(sortField),
                        .int(Int64(Self.checksum(sortField))),
                        .int(0),
                        .text("")
                    ]
                )

                cardPosition += 1
                try database.run(
                    "INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    [
                        .int(noteID + 1), .int(noteID), .int(deckID), .int(0),
                        .int(Int64(modification)), .int(-1),
                        .int(0), .int(0), .int(Int64(cardPosition)),
                        .int(0), .int(0), .int(0), .int(0), .int(0),
                        .int(0), .int(0), .int(0), .text("")
                    ]
                )
                }
            }

            let lectureName = plan.pdfURL.deletingPathExtension().lastPathComponent
            if let previous = plan.previousDeckName, previous != plan.deckName {
                summary.moved.append((lecture: lectureName, from: previous, to: plan.deckName))
            }
            for qid in plan.retiredQIDs {
                summary.retired.append((qid: qid, lecture: lectureName))
            }
            updatedPlans.append(plan)
        }

        try writeCollectionRow(database, decks: decksJSON)
        database.close()

        // --- assemble the package ---------------------------------------------
        var zip = ZipWriter()
        zip.add(name: "collection.anki2", data: try Data(contentsOf: databaseURL))

        var mediaMap: [String: String] = [:]
        for (offset, name) in mediaFiles.keys.sorted().enumerated() {
            guard let source = mediaFiles[name], let data = try? Data(contentsOf: source) else { continue }
            mediaMap[String(offset)] = name
            zip.add(name: String(offset), data: data)
        }
        summary.mediaFiles = mediaMap.count

        let mediaJSON = try JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys])
        zip.add(name: "media", data: mediaJSON)

        try AtomicWrite.write(zip.finish(), to: destination)
        summary.packageURL = destination

        return (summary, updatedPlans)
    }

    // MARK: - Card content

    private func templateLookup(_ id: String?) -> Template? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    private func renderText(question: Question, template: Template?) -> (front: String, back: String) {
        switch question.kind {
        case .basic, .slide2slide:
            return (paragraphs(question.front), paragraphs(question.back))
        case .occlusion:
            // The image is the question; any text is an optional prompt above it.
            return (paragraphs(question.front), paragraphs(question.back))
        case .template:
            guard let template else { return (paragraphs(question.front), paragraphs(question.back)) }
            let rendered = template.render(blanks: question.blanks)
            let back = rendered.back.isEmpty ? question.back : rendered.back
            return (paragraphs(rendered.front), paragraphs(back))
        }
    }

    /// A plain vertical stack of images -- no JavaScript, no carousel. Renders
    /// identically on desktop, AnkiMobile, AnkiDroid and AnkiWeb, and
    /// "scroll through the slides" is then just scrolling.
    private func imageStack(_ names: [String]) -> String {
        names.map { "<img src=\"\($0)\">" }.joined(separator: "\n")
    }

    private func attach(page: Int, crop: CropRect?, masks: PageRenderer.MaskPaint? = nil,
                        plan: LecturePlan, renderer: PageRenderer,
                        into media: inout [String: URL]) -> String? {
        let name = renderer.mediaFileName(pdfSha256: plan.pdfSha256, page: page,
                                          crop: crop, masks: masks)
        if media[name] != nil { return name }            // already cited by another question
        guard let url = renderer.image(for: plan.document, pdfSha256: plan.pdfSha256,
                                       page: page, crop: crop, masks: masks) else {
            return nil
        }
        media[name] = url
        return name
    }

    /// The text layer of the cited slides, dropped into the Extra field.
    ///
    /// The card template does not render `{{Extra}}`, and that is the point:
    /// Anki's browser searches every field whether the template shows it or
    /// not. So cards look exactly as they did, and searching "complement
    /// cascade" now finds the card whose *slide* says it even when the question
    /// does not.
    ///
    /// Capped per page and overall. Slide text is small next to a 150 KB image,
    /// but a PDF with a dense appendix page can carry thousands of words, and
    /// nothing about the tenth paragraph helps you find a card.
    private func searchText(for question: Question, plan: LecturePlan) -> String {
        let perPageLimit = 600
        var budget = 2000
        var chunks: [String] = []

        for page in question.allPages {
            guard budget > 0, page >= 1, page <= plan.document.pageCount,
                  let pdfPage = plan.document.page(at: page - 1) else { continue }

            // A crop says "this part of the slide matters", so index that part.
            let crop = question.answerCrops[page] ?? question.questionCrops[page]
            let raw: String?
            if let crop, !crop.isFullPage {
                raw = pdfPage.selection(for: crop.rect(in: pdfPage.bounds(for: .cropBox)))?.string
            } else {
                raw = pdfPage.string
            }

            guard var text = raw else { continue }
            text = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            if text.count > perPageLimit { text = String(text.prefix(perPageLimit)) }
            if text.count > budget { text = String(text.prefix(budget)) }
            budget -= text.count
            chunks.append(text)
        }
        return escapeHTML(chunks.joined(separator: " "))
    }

    private func pagesLabel(_ question: Question) -> String {
        let front = PageSet.describe(question.questionPages)
        let back = PageSet.describe(question.answerPages)
        if front.isEmpty { return "pp. \(back)" }
        if back.isEmpty { return "pp. \(front)" }
        return "pp. \(front) → \(back)"
    }

    private func paragraphs(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return escapeHTML(trimmed).replacingOccurrences(of: "\n", with: "<br>")
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Collection database

    private func createSchema(_ database: SQLiteDB) throws {
        try database.execute("""
        CREATE TABLE col (
            id integer primary key, crt integer not null, mod integer not null,
            scm integer not null, ver integer not null, dty integer not null,
            usn integer not null, ls integer not null, conf text not null,
            models text not null, decks text not null, dconf text not null, tags text not null
        );
        CREATE TABLE notes (
            id integer primary key, guid text not null, mid integer not null,
            mod integer not null, usn integer not null, tags text not null,
            flds text not null, sfld integer not null, csum integer not null,
            flags integer not null, data text not null
        );
        CREATE TABLE cards (
            id integer primary key, nid integer not null, did integer not null,
            ord integer not null, mod integer not null, usn integer not null,
            type integer not null, queue integer not null, due integer not null,
            ivl integer not null, factor integer not null, reps integer not null,
            lapses integer not null, left integer not null, odue integer not null,
            odid integer not null, flags integer not null, data text not null
        );
        CREATE TABLE revlog (
            id integer primary key, cid integer not null, usn integer not null,
            ease integer not null, ivl integer not null, lastIvl integer not null,
            factor integer not null, time integer not null, type integer not null
        );
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
        """)
    }

    private func writeCollectionRow(_ database: SQLiteDB, decks: [String: Any]) throws {
        let models: [String: Any] = [String(AnkiIdentity.noteTypeID): noteTypeJSON()]
        let configuration: [String: Any] = [
            "activeDecks": [1], "addToCur": true, "collapseTime": 1200, "curDeck": 1,
            "curModel": String(AnkiIdentity.noteTypeID), "dueCounts": true, "estTimes": true,
            "newBury": true, "newSpread": 0, "nextPos": 1, "sortBackwards": false,
            "sortType": "noteFld", "timeLim": 0
        ]
        let deckConfiguration: [String: Any] = ["1": defaultDeckConfigJSON()]

        func json(_ object: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        let now = Int64(Date().timeIntervalSince1970)
        try database.run(
            "INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                .int(1), .int(now), .int(now * 1000), .int(now * 1000 - 100),
                .int(11), .int(0), .int(0), .int(0),
                .text(try json(configuration)),
                .text(try json(models)),
                .text(try json(decks)),
                .text(try json(deckConfiguration)),
                .text("{}")
            ]
        )
    }

    /// The frozen note type. Seven fields, one card template, forever.
    private func noteTypeJSON() -> [String: Any] {
        let fields = AnkiIdentity.fields.enumerated().map { index, name -> [String: Any] in
            ["name": name, "ord": index, "sticky": false, "rtl": false,
             "font": "Helvetica", "size": 20, "media": []]
        }
        let front = """
        <div class="q">{{Front}}</div>
        {{FrontMedia}}
        """
        let back = """
        {{FrontSide}}
        <hr id="answer">
        <div class="a">{{Back}}</div>
        {{BackMedia}}
        <div class="src">{{Source}}</div>
        """
        return [
            "id": String(AnkiIdentity.noteTypeID),
            "name": AnkiIdentity.noteTypeName,
            "type": 0,
            "mod": Int(Date().timeIntervalSince1970),
            "usn": -1,
            "sortf": 0,
            "did": 1,
            "tmpls": [[
                "name": "Card 1", "ord": 0, "qfmt": front, "afmt": back,
                "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0
            ]],
            "flds": fields,
            "css": cardCSS,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "latexsvg": false,
            "req": [[0, "any", [0, 1]]],
            "tags": [],
            "vers": []
        ]
    }

    private var cardCSS: String {
        """
        .card {
          font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
          font-size: 19px;
          line-height: 1.5;
          text-align: left;
          color: #1E2A46;
          background: #F4F2EC;
          padding: 18px 16px 28px;
        }
        .nightMode .card, .card.nightMode { color: #E7E9ED; background: #101318; }
        .q { font-size: 21px; font-weight: 600; }
        .a { margin: 10px 0; }
        img {
          max-width: 100%;
          height: auto;
          display: block;
          margin: 12px auto;
          border-radius: 6px;
          background: #fff;
        }
        hr#answer { border: none; border-top: 1px solid #B9BFCC; margin: 18px 0; }
        .src {
          margin-top: 22px;
          font-size: 12px;
          color: #8A93A6;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        """
    }

    private func defaultDeckJSON() -> [String: Any] {
        deckJSON(id: 1, name: "Default")
    }

    private func deckJSON(id: Int64, name: String) -> [String: Any] {
        [
            "id": id, "name": name, "mod": Int(Date().timeIntervalSince1970),
            "usn": -1, "collapsed": false, "desc": "", "dyn": 0, "conf": 1,
            "extendNew": 10, "extendRev": 50,
            "lrnToday": [0, 0], "newToday": [0, 0], "revToday": [0, 0], "timeToday": [0, 0]
        ]
    }

    private func defaultDeckConfigJSON() -> [String: Any] {
        [
            "id": 1, "name": "Default", "mod": 0, "usn": 0,
            "maxTaken": 60, "timer": 0, "autoplay": true, "replayq": true,
            "new": ["bury": true, "delays": [1, 10], "initialFactor": 2500,
                    "ints": [1, 4, 7], "order": 1, "perDay": 20, "separate": true],
            "rev": ["bury": true, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1,
                    "maxIvl": 36500, "minSpace": 1, "perDay": 200],
            "lapse": ["delays": [10], "leechAction": 0, "leechFails": 8, "minInt": 1, "mult": 0]
        ]
    }

    // MARK: - Identifiers

    /// Stable across exports, derived from the deck name. Anki matches decks by
    /// name, so this only needs to be consistent, not meaningful.
    static func deckID(for name: String) -> Int64 {
        let digest = SHA256.hash(data: Data(name.utf8))
        let bytes = Array(digest.prefix(8))
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        // Keep clear of 1 (the Default deck) and inside a comfortable range.
        return Int64(value % 2_000_000_000) + 100_000
    }

    /// Anki's dupe-detection checksum: the first 8 hex digits of the SHA-1 of
    /// the sort field, read as an integer.
    static func checksum(_ sortField: String) -> UInt32 {
        let digest = Insecure.SHA1.hash(data: Data(sortField.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return UInt32(hex.prefix(8), radix: 16) ?? 0
    }
}
