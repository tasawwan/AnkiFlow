import Foundation
import CryptoKit
import PDFKit

/// The on-disk shape of a sidecar file. Pretty-printed with sorted keys so a
/// one-line change shows as a one-line diff.
struct SidecarFile: Codable {
    struct PDFInfo: Codable {
        var fileName: String
        var pageCount: Int
        var sha256: String
        /// Exact per-page text hashes. Superseded by `pageSketches`; still read
        /// so files written by earlier versions keep working.
        var pageFingerprints: [String]?
        /// A fuzzy sketch of each page's words, in page order. What lets the app
        /// notice that a slide was inserted rather than silently letting every
        /// question after it point one slide too early — and, unlike an exact
        /// hash, what lets it still recognise a slide you have annotated since.
        var pageSketches: [String]?
    }

    var schemaVersion: Int
    var pdf: PDFInfo
    var deckNameOverride: String?
    var questions: [Question]
    /// The deck this lecture last exported to. If the lecture has since moved
    /// folders, this is how we know.
    var lastExportedDeckName: String?
    /// You have decided this lecture is learned.
    ///
    /// In the sidecar rather than the notes file because it is a fact about
    /// your progress, not a line of your writing -- the notes file is yours and
    /// nothing but what you typed belongs in it. It overrules everything the
    /// app can work out on its own: Anki knowing about every card is evidence,
    /// and you saying so is the answer.
    var reviewed: Bool?
    /// Questions that were exported and have since been deleted. Anki has no
    /// concept of an upstream deletion, so their cards are still sitting in
    /// your collection and we have to be able to name them.
    var retiredQIDs: [String]?
}

/// One lecture: a PDF and the questions written against it.
///
/// Autosaves. There is no unsaved state and no save dialog -- see the design
/// doc, section 5. Writes are coalesced 1.5s after the last edit and forced on
/// commit, lecture switch, resign-active and quit.
@MainActor
final class LectureDocument: ObservableObject {
    static let currentSchemaVersion = 1
    static let saveDebounce: TimeInterval = 1.5

    let pdfURL: URL
    let sidecarURL: URL
    /// Needed so a moved PDF can find the questions it left behind.
    private let libraryRoot: URL?
    /// Whether the sidecar carries Finder's hidden flag.
    var hideFile: Bool = true

    @Published var questions: [Question] = [] { didSet { scheduleSave() } }
    @Published private(set) var pageCount: Int = 0
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var loadError: String?
    /// Set when questions were recovered from a sidecar left behind by a move.
    @Published private(set) var notice: String?

    /// Read and understood. The notice says what changed about the PDF since you
    /// last worked on it, which is worth reading once and not worth keeping on
    /// screen for the rest of the session.
    func dismissNotice() { notice = nil }
    /// Set when the PDF's pages have moved under the questions. Held rather than
    /// applied: renumbering somebody's whole question bank is not something to
    /// do without asking, and the alternative -- doing nothing -- is worse.
    /// Set when the slides have moved under the questions. Held, not applied.
    @Published private(set) var pendingShift: PageShift?
    /// The PDF description as it was on disk when this lecture was loaded.
    /// Written back unchanged while a renumbering offer is outstanding.
    private var loadedPDFInfo: SidecarFile.PDFInfo?

    private(set) var pdfSha256: String = ""
    private(set) var deckNameOverride: String?
    @Published private(set) var lastExportedDeckName: String?
    @Published private(set) var reviewed = false
    @Published private(set) var retiredQIDs: [String] = []
    private(set) var document: PDFDocument?

    private var saveTask: Task<Void, Never>?
    private var loadedFileDate: Date?

    var title: String { pdfURL.lectureName }

    init(pdfURL: URL, libraryRoot: URL? = nil) {
        self.pdfURL = pdfURL
        self.libraryRoot = libraryRoot
        self.sidecarURL = pdfURL
            .deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        load()
    }

    // MARK: - Loading

    private func load() {
        document = PDFDocument(url: pdfURL)
        // Highlights are drawn by us from here on -- see PDFEditing.
        PDFEditing.takeOverHighlights(in: document)
        pageCount = document?.pageCount ?? 0
        pdfSha256 = Self.sha256OfFile(at: pdfURL)

        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            // No sidecar here. The PDF may simply have been moved in Finder,
            // leaving its questions behind -- go and look for them.
            // No questions beside this PDF. That may be a lecture you haven't
            // written any for yet, or a file that lost them in a rename -- the
            // library scan decides which, and offers recovery if so.
            return
        }
        do {
            let data = try Data(contentsOf: sidecarURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SidecarFile.self, from: data)
            questions = file.questions
            deckNameOverride = file.deckNameOverride
            lastExportedDeckName = file.lastExportedDeckName
            reviewed = file.reviewed ?? false
            retiredQIDs = file.retiredQIDs ?? []
            loadedPDFInfo = file.pdf
            loadedFileDate = fileModificationDate()
            loadError = nil

            // A question written under a card type this app no longer has was
            // read as Basic. Write the file back now, in the current shape, so
            // that reading happens once rather than on every open forever. The
            // modification date was just taken, so this cannot trip the
            // edited-underneath-us guard in `saveNow`.
            if questions.contains(where: \.wasMigrated) {
                for index in questions.indices { questions[index].wasMigrated = false }
                saveNow()
            }

            // The PDF was edited in place -- annotations added, say. The
            // questions still point at the right page numbers, but every slide
            // image has to be re-rendered, and the exporter has to be told the
            // cards changed. Bumping the recorded hash does both: media
            // filenames are derived from it, and it feeds the content hash.
            // The page check runs whenever we have fingerprints to compare, not
            // only when the file's hash changed: a recovered question file can
            // arrive next to a lecture whose slides have moved, and a rename
            // leaves the hash identical while telling us nothing.
            detectPageShift(against: file.pdf)

            if !file.pdf.sha256.isEmpty, file.pdf.sha256 != pdfSha256, pendingShift == nil {
                if file.pdf.pageCount == pageCount {
                    notice = "\(pdfURL.finderName) has changed since you last worked on it — same \(pageCount) pages, so your questions still line up. Slides will re-render on the next export."
                } else {
                    notice = "\(pdfURL.finderName) has changed and now has \(pageCount) pages instead of \(file.pdf.pageCount). Nothing your questions point at seems to have moved, but it's worth a look."
                }
                saveNow()
            }
        } catch {
            // Never silently start from empty: that would look like the questions
            // were fine and then get overwritten by the next autosave.
            loadError = "Could not read \(sidecarURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // Recovery used to happen here, silently, when you opened a PDF with no
    // questions beside it: it copied an orphaned file's questions into a new one
    // and deleted the original. That left a second copy on disk whenever the
    // copy succeeded and the delete didn't, guessed with heuristics nobody had
    // agreed to, and gave you no say. It now lives in OrphanRecovery, which
    // renames the file rather than duplicating it, and asks first.

    private func fileModificationDate() -> Date? {
        let values = try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    // MARK: - Saving

    private func scheduleSave() {
        guard loadError == nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Force an immediate write. Safe to call when nothing changed.
    func saveNow() {
        guard loadError == nil else { return }
        saveTask?.cancel()
        saveTask = nil

        // Never *create* a question file for a lecture that is not there.
        //
        // Renaming or moving a lecture takes its question file with it, and the
        // still-open document -- which is holding the old path -- is then asked
        // to save on its way out. Writing at that moment puts a fresh sidecar
        // back at a name with no PDF beside it: an orphan the app made itself,
        // out of a rename that had worked perfectly.
        //
        // An existing file is still written. A PDF that disappeared from under
        // an open lecture -- renamed in the Finder, moved by a sync -- leaves
        // its question file behind, and that one has to go on taking your edits
        // or the questions you just typed are the thing that gets lost.
        let manager = FileManager.default
        guard manager.fileExists(atPath: pdfURL.path)
                || manager.fileExists(atPath: sidecarURL.path) else { return }

        // Someone edited the file underneath us. Keep ours, park theirs beside it.
        if let loadedFileDate, let onDisk = fileModificationDate(), onDisk > loadedFileDate.addingTimeInterval(0.5) {
            let conflictURL = pdfURL
                .deletingPathExtension()
                .appendingPathExtension("conflict")
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            try? FileManager.default.removeItem(at: conflictURL)
            try? FileManager.default.copyItem(at: sidecarURL, to: conflictURL)
        }

        // A lecture with no questions gets no file. Writing one would litter
        // the library with sidecars for every PDF you happened to open, and
        // deleting the last question should leave no trace behind either.
        guard questions.contains(where: { !$0.isEmpty }) || !retiredQIDs.isEmpty else {
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try? FileManager.default.removeItem(at: sidecarURL)
                // Tidy up leftovers from the version that wrote these.
                try? FileManager.default.removeItem(at: sidecarURL.appendingPathExtension("bak"))
                lastSavedAt = Date()
            }
            return
        }

        let file = SidecarFile(
            schemaVersion: Self.currentSchemaVersion,
            // While a renumbering offer is outstanding, the *old* page hashes
            // are the only record of where the questions used to point. Saving
            // the new ones would answer the question for you -- and answer it
            // wrong: decline the offer, and nothing could ever detect the shift
            // again. So the evidence is preserved until the offer is settled.
            pdf: pendingShift != nil
                ? (loadedPDFInfo ?? .init(fileName: pdfURL.lastPathComponent,
                                          pageCount: pageCount,
                                          sha256: pdfSha256,
                                          pageFingerprints: nil,
                                          pageSketches: currentSketches()))
                : .init(fileName: pdfURL.lastPathComponent,
                        pageCount: pageCount,
                        sha256: pdfSha256,
                        pageFingerprints: nil,
                        pageSketches: currentSketches()),
            deckNameOverride: deckNameOverride,
            // Empty ones never reach the file.
            //
            // Opening a template's tab gives you its shape to type into, and
            // that shape is a view: until there are words in it there is no
            // card, and writing one would leave a blank entry in your question
            // file for every tab you looked at. It is filtered here rather than
            // refused earlier so the card you are part-way through still exists
            // in memory to be typed into -- it simply is not yours until it
            // says something.
            questions: questions.filter { !$0.isEmpty },
            lastExportedDeckName: lastExportedDeckName,
            reviewed: reviewed ? true : nil,
            retiredQIDs: retiredQIDs.isEmpty ? nil : retiredQIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        do {
            try AtomicWrite.write(data, to: sidecarURL, hidden: hideFile)
            lastSavedAt = Date()
            loadedFileDate = fileModificationDate()
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: - Page shifts

    private func currentSketches() -> [String]? {
        guard let document else { return nil }
        let sketches = PageSketch.all(in: document)
        return PageSketch.isUsable(sketches) ? sketches : nil
    }

    /// Compares what each page said last time with what it says now. Only
    /// reports a shift when pages actually moved -- an annotated slide keeps its
    /// words, so annotating alone produces no map and no noise.
    /// Compares what each slide used to say with what the PDF says now.
    ///
    /// Publishes a *proposal*, never a change. Renumbering someone's whole
    /// question bank on a guess is worse than the bug it fixes, and the slides
    /// that can't be matched by text are exactly the ones a person should look
    /// at — so those are surfaced with their reasoning rather than applied.
    /// Re-reads the PDF because the file on disk changed underneath us.
    ///
    /// For the lecture you annotated somewhere else and let sync back: a file
    /// AnkiFlow did not write, arriving while it is open. The sketches of the
    /// document being replaced are taken *before* the swap, so the same
    /// machinery that catches a slide inserted between sessions catches one
    /// inserted while you were looking at it -- and your questions are offered
    /// the shift rather than quietly pointing a slide too early.
    ///
    /// Returns false, changing nothing, if the file cannot be parsed. A cloud
    /// folder writes a file in pieces, so "half a PDF" is a state you will
    /// genuinely see, and replacing a working document with it would be worse
    /// than waiting for the next write.
    /// What a reload could not carry across, for the app to say out loud.
    struct ReplayResult {
        var replayed = 0
        var stranded = 0
        /// Everything an open editing session needs to carry on against the
        /// document that has just replaced the one it was holding. Nil when a
        /// mark could not be brought across as itself, which is the one case
        /// where the session's undo history can no longer be trusted and has
        /// to be thrown away instead.
        var rebase: Rebase?
    }

    /// The handover from the replaced document to its replacement.
    struct Rebase {
        let document: PDFDocument
        let moves: [(old: PDFPage, new: PDFPage)]
        let baseline: PDFEditSession.Baseline
    }

    private(set) var lastReplay = ReplayResult()

    @discardableResult
    func reloadPDFFromDisk(replaying pending: PDFEditSession.PendingMarks? = nil) -> Bool {
        guard let fresh = PDFDocument(url: pdfURL), fresh.pageCount > 0 else { return false }
        let before = SidecarFile.PDFInfo(fileName: pdfURL.lastPathComponent,
                                         pageCount: pageCount,
                                         sha256: pdfSha256,
                                         pageFingerprints: nil,
                                         pageSketches: currentSketches())
        // Your unsaved marks, put back on top of the newer lecture.
        //
        // Mapped through the page sketches rather than by number: a slide added
        // on the other device shifts everything after it, and replaying by
        // index would put your highlight on the wrong slide -- silently, which
        // is the worst way for this to be wrong.
        lastReplay = ReplayResult()
        if let pending {
            // Snapshotted here, in the one moment it exists: the new file as it
            // came off the disk, before any of your marks go back on top of it.
            // That is what "unsaved work" will mean from now on.
            let baseline = PDFEditSession.Baseline(of: fresh)
            let mapping = PageSketch.align(old: before.pageSketches ?? [],
                                           new: PageSketch.all(in: fresh))
            var toNew: [Int: Int] = [:]
            for move in mapping {
                if let new = move.newPage { toNew[move.oldPage] = new }
            }
            // Straight through when the sketches had nothing to say -- an
            // image-only lecture has no text to match on, and the page numbers
            // are then the best evidence there is.
            func target(for old: Int) -> PDFPage? {
                guard let number = toNew[old] ?? (toNew.isEmpty ? old : nil),
                      number >= 1, number <= fresh.pageCount else { return nil }
                return fresh.page(at: number - 1)
            }

            // Every mark is *moved*, not copied, so that the undo steps holding
            // it go on holding the right object. An annotation is listed by the
            // page it sits on, which is why it has to come off the old one
            // before it can go on the new.
            var identityHeld = true
            for entry in pending.added {
                guard let page = target(for: entry.page) else {
                    // Nowhere to put it. The step that made it still points at a
                    // page this document does not have, so undoing it finds
                    // nothing and changes nothing -- which is right.
                    lastReplay.stranded += 1
                    continue
                }
                entry.annotation.page?.removeAnnotation(entry.annotation)
                page.addAnnotation(entry.annotation)
                if page.annotations.contains(where: { $0 === entry.annotation }) {
                    lastReplay.replayed += 1
                } else if let copy = PDFEditing.copy(entry.annotation) {
                    // PDFKit would not take the object across. The mark is kept
                    // -- losing your markup is the one unacceptable outcome --
                    // but it is no longer the object the history holds, so the
                    // history goes.
                    page.addAnnotation(copy)
                    lastReplay.replayed += 1
                    identityHeld = false
                } else {
                    lastReplay.stranded += 1
                    identityHeld = false
                }
            }

            // Marks you deleted go on being deleted. Matched on kind and place
            // because the object itself belongs to the document being replaced.
            for entry in pending.removed {
                guard let page = target(for: entry.page) else { continue }
                let match = page.annotations.first {
                    ($0.type ?? "") == entry.type
                        && abs($0.bounds.midX - entry.bounds.midX) < 1
                        && abs($0.bounds.midY - entry.bounds.midY) < 1
                }
                if let match { page.removeAnnotation(match) }
            }

            // Where every page went, not only the marked ones: a step can refer
            // to a page whose marks are all exactly as they were on disk -- a
            // deletion you have already undone, say -- and redoing it still has
            // to reach the right slide.
            if identityHeld, let old = document {
                var moves: [(old: PDFPage, new: PDFPage)] = []
                for number in 1...max(old.pageCount, 1) {
                    guard let from = old.page(at: number - 1),
                          let to = target(for: number) else { continue }
                    moves.append((old: from, new: to))
                }
                lastReplay.rebase = Rebase(document: fresh, moves: moves,
                                           baseline: baseline)
            }
        }

        document = fresh
        PDFEditing.takeOverHighlights(in: fresh)
        pageCount = fresh.pageCount
        pdfSha256 = Self.sha256OfFile(at: pdfURL)
        detectPageShift(against: before)
        // Slide images come from the hash, so the new hash is what makes the
        // re-rendered pictures reach your cards on the next export.
        saveNow()
        return true
    }

    private func detectPageShift(against info: SidecarFile.PDFInfo) {
        pendingShift = nil
        guard let document else { return }

        // Sketches when we have them; the old exact hashes when the file was
        // written by an earlier version.
        let stored = info.pageSketches ?? info.pageFingerprints
        guard let stored, PageSketch.isUsable(stored) else { return }

        let current: [String]
        if info.pageSketches != nil {
            current = PageSketch.all(in: document)
        } else {
            current = PageFingerprint.all(in: document)
        }
        guard PageSketch.isUsable(current) else { return }

        let moves = PageSketch.align(old: stored, new: current)
        guard moves.contains(where: { $0.newPage != $0.oldPage }) else { return }

        // Only slides your questions actually cite are worth raising.
        let cited = Set(questions.flatMap(\.allPages))
        let relevant = moves.filter { cited.contains($0.oldPage) }
        guard relevant.contains(where: { $0.newPage != $0.oldPage }) else { return }

        pendingShift = PageShift(
            oldPageCount: info.pageCount,
            newPageCount: pageCount,
            moves: relevant.map { move in
                var copy = move
                copy.questionCount = questions.filter { $0.allPages.contains(move.oldPage) }.count
                return copy
            }
        )
    }

    /// Applies the mapping the user settled on.
    ///
    /// Removal happens **before** the remap, and the order is not incidental.
    /// `removed` is a list of *old* page numbers, and the mapping deliberately
    /// leaves those numbers out so surviving pages can fall through to their own
    /// number. Renumber first and the old number now belongs to whichever slide
    /// moved up into it -- so deleting slide 3 stripped slide 4 out of every
    /// question that cited it, and left the question that cited slide 3 alone.
    func applyPageShift(_ mapping: [Int: Int], removing removed: [Int] = []) {
        for index in questions.indices {
            for page in removed { dropPage(page, fromQuestionAt: index) }
            questions[index].remapPages(mapping)
            questions[index].pruneCrops()
        }
        pendingShift = nil
        notice = "Slide numbers updated to match the new PDF."
        saveNow()
    }

    // MARK: - Editing the PDF itself

    /// Save an edit made to the lecture PDF, and bring the questions with it.
    ///
    /// This is the counterpart to `detectPageShift`. That one exists because a
    /// PDF edited in another app arrives with no explanation and the app has to
    /// infer what moved. Here the app *made* the change, so the mapping is exact:
    /// questions are renumbered outright, with nothing to confirm and no notice
    /// to dismiss.
    ///
    /// Three things have to happen together or the next launch looks like
    /// somebody tampered with the file:
    ///
    /// 1. The document is written to disk.
    /// 2. The recorded hash and sketches are refreshed, so the file's new state
    ///    *is* the remembered state and no "this has changed" notice fires.
    /// 3. Questions follow the pages -- renumbered, dropped, or with their crops
    ///    re-expressed against a new page box.
    /// Raised instead of overwriting a lecture that changed underneath us.
    struct StaleWrite: LocalizedError {
        let fileName: String
        var errorDescription: String? {
            "\(fileName) changed on disk since it was opened — probably synced back from another device. Nothing was written. Let it reload, then save again."
        }
    }

    func applyPDFEdit(_ change: PDFEditing.Change) throws {
        guard let document else { return }
        // Never write over a newer file.
        //
        // Every write to the PDF is something you asked for -- ⌘S, a page move,
        // a flag -- so the app is not editing your lecture behind your back.
        // But "you asked for it" is not enough on its own: if the iPad's copy
        // landed a second ago, saving would put the version this app has been
        // holding on top of it and lose whatever you did over there. The hash
        // taken at load is what says whether that has happened.
        if !pdfSha256.isEmpty, Self.sha256OfFile(at: pdfURL) != pdfSha256 {
            throw StaleWrite(fileName: pdfURL.lastPathComponent)
        }
        // Pasted pictures become part of the page on the way out, so once they
        // are written the live document and the file no longer agree: the file
        // has the picture in its content, the document still has the stamp that
        // drew it. Saving again from here would write the same picture twice.
        let burnedPictures = PDFEditing.hasImageStamps(document)
        try PDFEditing.save(document, to: pdfURL)

        // Order matters, and it is the reverse of the obvious one.
        //
        // `removed` is in the numbering *before* the edit and `boxChanges` is in
        // the numbering *after* it, so the questions have to be walked through
        // three stages: drop the pages that are gone while their old numbers
        // still mean something, renumber what is left, and only then convert
        // crops against boxes keyed by the new numbers.
        for index in questions.indices {
            for page in change.removed { dropPage(page, fromQuestionAt: index) }
        }
        if !change.remap.isEmpty {
            for index in questions.indices { questions[index].remapPages(change.remap) }
        }
        for index in questions.indices {
            for (page, boxes) in change.boxChanges {
                if let crop = questions[index].questionCrops[page] {
                    questions[index].questionCrops[page] = crop.converted(from: boxes.old, to: boxes.new)
                }
                if let crop = questions[index].answerCrops[page] {
                    questions[index].answerCrops[page] = crop.converted(from: boxes.old, to: boxes.new)
                }
                // Masks belong to one slide, and that slide is the question's
                // occlusion page.
                if questions[index].occlusionPage == page {
                    for maskIndex in questions[index].masks.indices {
                        questions[index].masks[maskIndex].rect =
                            questions[index].masks[maskIndex].rect.converted(from: boxes.old, to: boxes.new)
                    }
                }
            }
        }
        if change.touchesNumbering {
            for index in questions.indices { questions[index].pruneCrops() }
        }

        // Reloaded from disk only when pages moved. That is the case where the
        // in-memory document and the questions have to be re-read together, and
        // `pageCount` publishing the change is what gets the new document onto
        // the screen. For a pen stroke or a trim the live document already *is*
        // what was written, and re-parsing a 200-page lecture on every stroke
        // would throw away the scroll position for nothing.
        if change.touchesNumbering || burnedPictures {
            self.document = PDFDocument(url: pdfURL)
            PDFEditing.takeOverHighlights(in: self.document)
            pageCount = self.document?.pageCount ?? pageCount
        }
        pdfSha256 = Self.sha256OfFile(at: pdfURL)
        pendingShift = nil
        loadedPDFInfo = nil
        notice = nil
        saveNow()
    }

    /// Remove a slide from one question, retiring the cards that go with it.
    ///
    /// Deleting a mask by hand retires its card, and so does deleting a
    /// question. Deleting the *slide* the masks were drawn on has to do the
    /// same, or those cards stay in Anki with nothing here that remembers them
    /// and nothing in the export sheet offering to clean them up.
    ///
    /// Takes an index and writes the question back rather than taking it
    /// `inout`: `retire` is a method on this same object, and calling one while
    /// holding an exclusive `inout` borrow of `questions` is the kind of thing
    /// that works until it doesn't.
    private func dropPage(_ page: Int, fromQuestionAt index: Int) {
        var question = questions[index]
        let dropped = question.removePage(page)
        for maskID in dropped where question.childExports[maskID] != nil {
            retire(qid: question.guid(variant: maskID))
            question.childExports[maskID] = nil
        }
        questions[index] = question
    }

    /// The live document, for the edit menu to operate on.
    var editableDocument: PDFDocument? { document }

    // MARK: - Editing

    func add(_ question: Question) {
        questions.append(question)
    }

    func update(_ question: Question) {
        guard let index = questions.firstIndex(where: { $0.qid == question.qid }) else { return }
        var updated = question
        updated.updatedAt = Date()
        questions[index] = updated
    }

    /// Record that something already exported no longer exists here. Used for
    /// deleted questions and for deleted occlusion masks, which are cards too.
    func retire(qid: String) {
        guard !retiredQIDs.contains(qid) else { return }
        retiredQIDs.append(qid)
    }

    /// Every Anki note this question has actually produced. A separate-mode
    /// occlusion question makes one per mask, each with its own GUID -- retiring
    /// only the bare qid would leave those cards in Anki with nothing pointing
    /// at them.
    private func exportedGuids(of question: Question) -> [String] {
        var out: [String] = []
        if question.export != nil { out.append(question.qid) }
        for maskID in question.childExports.keys.sorted() {
            out.append(question.guid(variant: maskID))
        }
        return out
    }

    func delete(qid: String) {
        // Only a question Anki already knows about leaves a card behind.
        if let question = questions.first(where: { $0.qid == qid }) {
            for guid in exportedGuids(of: question) where !retiredQIDs.contains(guid) {
                retiredQIDs.append(guid)
            }
        }
        // `questions` has a didSet that schedules the save.
        questions.removeAll { $0.qid == qid }
    }

    /// Puts the questions in slide order, in the file.
    ///
    /// Sorted by the first slide on the question side, then the first on the
    /// answer side -- which for a lecture you worked through front to back is
    /// the order you wrote them in anyway, and for one you came back to is the
    /// order you will read them in.
    ///
    /// A question with no slides does not move. It keeps the index it is at
    /// while the anchored ones are sorted into the remaining positions around
    /// it, so a written-only card stays next to the ones it was written beside
    /// instead of being swept to the end where it means nothing. That is the
    /// whole subtlety here: sorting a list that only some members have a key
    /// for, without inventing a key for the rest.
    ///
    /// Returns true if anything moved.
    @discardableResult
    func sortQuestionsBySlides() -> Bool {
        let anchored = questions.indices.filter { !questions[$0].allPages.isEmpty }
        guard anchored.count > 1 else { return false }

        let sorted = anchored.map { questions[$0] }.sorted { a, b in
            let aq = a.questionPages.min() ?? Int.max
            let bq = b.questionPages.min() ?? Int.max
            if aq != bq { return aq < bq }
            let aa = a.answerPages.min() ?? Int.max
            let ba = b.answerPages.min() ?? Int.max
            return aa < ba
        }

        var rebuilt = questions
        for (slot, question) in zip(anchored, sorted) { rebuilt[slot] = question }
        guard rebuilt.map(\.qid) != questions.map(\.qid) else { return false }
        questions = rebuilt
        saveNow()
        return true
    }

    /// Removes a question without retiring it.
    ///
    /// For deletions that came *from* Anki. `delete(qid:)` records a tombstone
    /// so the next export can offer to remove the card -- exactly wrong here,
    /// where the card is already gone and the tombstone would offer to delete
    /// something that does not exist.
    func forget(qid: String) {
        questions.removeAll { $0.qid == qid }
    }

    /// Called after the export sheet has told you about them.
    func clearRetired() {
        guard !retiredQIDs.isEmpty else { return }
        retiredQIDs = []
        saveNow()
    }

    func setReviewed(_ value: Bool) {
        guard reviewed != value else { return }
        reviewed = value
        saveNow()
    }

    func recordExport(deckName: String) {
        lastExportedDeckName = deckName
    }

    /// Also clears `childExports`, or an occlusion question would keep claiming
    /// its per-mask cards were already exported.
    func forgetExportHistory() {
        lastExportedDeckName = nil
        retiredQIDs = []
        for index in questions.indices {
            questions[index].export = nil
            questions[index].childExports = [:]
        }
        saveNow()
    }

    func question(qid: String?) -> Question? {
        guard let qid else { return nil }
        return questions.first { $0.qid == qid }
    }

    // MARK: - Hashing

    /// `nonisolated`: it reads a file and returns a string, touching no state on
    /// this class, so there is no reason for it to require the main actor --
    /// and orphan matching hashes candidate PDFs from outside it.
    nonisolated static func sha256OfFile(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
