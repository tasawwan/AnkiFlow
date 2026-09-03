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
    @Published private(set) var retiredQIDs: [String] = []
    private(set) var document: PDFDocument?

    private var saveTask: Task<Void, Never>?
    private var loadedFileDate: Date?

    var title: String { pdfURL.deletingPathExtension().lastPathComponent }

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
            retiredQIDs = file.retiredQIDs ?? []
            loadedPDFInfo = file.pdf
            loadedFileDate = fileModificationDate()
            loadError = nil

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
                    notice = "\(pdfURL.lastPathComponent) has changed since you last worked on it — same \(pageCount) pages, so your questions still line up. Slides will re-render on the next export."
                } else {
                    notice = "\(pdfURL.lastPathComponent) has changed and now has \(pageCount) pages instead of \(file.pdf.pageCount). Nothing your questions point at seems to have moved, but it's worth a look."
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
            questions: questions,
            lastExportedDeckName: lastExportedDeckName,
            retiredQIDs: retiredQIDs.isEmpty ? nil : retiredQIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        do {
            try AtomicWrite.write(data, to: sidecarURL, hidden: hideFile)
            writeSnapshot(data)
            lastSavedAt = Date()
            loadedFileDate = fileModificationDate()
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    /// A timestamped copy per save, pruned to the last 20. A few KB each.
    private func writeSnapshot(_ data: Data) {
        guard let historyDir = LibraryPaths.historyDirectory(forSidecar: sidecarURL) else { return }
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(pdfURL.deletingPathExtension().lastPathComponent)__\(stamp).json"
        try? data.write(to: historyDir.appendingPathComponent(name))

        let existing = ((try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(pdfURL.deletingPathExtension().lastPathComponent + "__") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if existing.count > 20 {
            for url in existing.prefix(existing.count - 20) {
                try? FileManager.default.removeItem(at: url)
            }
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
    func applyPageShift(_ mapping: [Int: Int], removing removed: [Int] = []) {
        for index in questions.indices {
            questions[index].remapPages(mapping)
            for page in removed { questions[index].removePage(page) }
            questions[index].pruneCrops()
        }
        pendingShift = nil
        notice = "Slide numbers updated to match the new PDF."
        saveNow()
    }

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

    /// Called after the export sheet has told you about them.
    func clearRetired() {
        guard !retiredQIDs.isEmpty else { return }
        retiredQIDs = []
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
