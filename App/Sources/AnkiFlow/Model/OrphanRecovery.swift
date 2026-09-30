import Foundation
import PDFKit

/// Question files that have lost their lecture, and the evidence for putting
/// them back.
///
/// Nothing here decides on its own. It gathers candidates, scores them, says
/// *why* it thinks what it thinks, and leaves the choice to you — because a
/// wrong pairing silently attaches a semester of questions to the wrong slides,
/// which is worse than asking.
enum OrphanRecovery {

    /// How a candidate was matched, strongest first. The reason is shown in the
    /// recovery window: "38 of 40 slides match" is something you can judge;
    /// a percentage on its own is not.
    enum Evidence: Comparable {
        case none
        case name(shared: Int)
        case slides(matched: Int, of: Int)
        case identical

        var rank: Int {
            switch self {
            case .none:      return 0
            case .name:      return 1
            case .slides:    return 2
            case .identical: return 3
            }
        }

        var confidence: Double {
            switch self {
            case .identical: return 1
            case .slides(let matched, let total):
                return total > 0 ? Double(matched) / Double(total) : 0
            case .name(let shared): return min(0.5, Double(shared) * 0.15)
            case .none: return 0
            }
        }

        var summary: String {
            switch self {
            case .identical:
                return "Same file — certain"
            case .slides(let matched, let total):
                return "\(matched) of \(total) slides match"
            case .name(let shared):
                return shared == 1 ? "1 word in common with the old name"
                                   : "\(shared) words in common with the old name"
            case .none:
                return "No evidence"
            }
        }

        static func < (lhs: Evidence, rhs: Evidence) -> Bool {
            lhs.rank == rhs.rank ? lhs.confidence < rhs.confidence : lhs.rank < rhs.rank
        }
    }

    struct Candidate: Identifiable, Hashable {
        var id: String { pdfURL.path }
        let pdfURL: URL
        let evidence: Evidence

        var name: String { pdfURL.lectureName }

        static func == (lhs: Candidate, rhs: Candidate) -> Bool { lhs.pdfURL == rhs.pdfURL }
        func hash(into hasher: inout Hasher) { hasher.combine(pdfURL) }
    }

    struct Orphan: Identifiable {
        var id: String { sidecarURL.path }
        let sidecarURL: URL
        /// The lecture this file remembers belonging to.
        let rememberedName: String
        let questionCount: Int
        let pageCount: Int
        let candidates: [Candidate]

        var best: Candidate? { candidates.first }
        var oldName: String {
            sidecarURL.lastPathComponent
                .replacingOccurrences(of: "." + AnkiIdentity.sidecarExtension, with: "")
        }
    }

    // MARK: - Finding

    /// Question files under `root` whose own PDF is gone, with every lecture
    /// that has no question file scored as a possible home.
    static func scan(root: URL, lectures: [URL]) -> [Orphan] {
        let manager = FileManager.default
        let suffix = "." + AnkiIdentity.sidecarExtension
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Lectures with no questions of their own are the only possible homes.
        let available = lectures.filter { pdfURL in
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            return !manager.fileExists(atPath: sidecar.path)
        }
        guard !available.isEmpty else { return [] }

        var orphans: [Orphan] = []
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        for case let url as URL in walker {
            if url.lastPathComponent == LibraryPaths.dotDirectoryName {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(suffix) else { continue }
            // A conflict backup ends in .conflict.ankiflow.json, so it looks
            // like a question file whose PDF is missing. It is the one artefact
            // that exists to preserve overwritten work; adopting it would move
            // it onto an unrelated lecture and consume it.
            guard !url.lastPathComponent.hasSuffix(".conflict" + suffix) else { continue }
            let expectedPDF = URL(fileURLWithPath: String(url.path.dropLast(suffix.count)) + ".pdf")
            guard !manager.fileExists(atPath: expectedPDF.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(SidecarFile.self, from: data) else { continue }
            let live = file.questions.filter { !$0.isEmpty }
            guard !live.isEmpty else { continue }

            let scored = available
                .map { Candidate(pdfURL: $0, evidence: evidence(for: file, pdfURL: $0,
                                                                oldName: expectedPDF)) }
                .sorted { $0.evidence > $1.evidence }

            orphans.append(Orphan(
                sidecarURL: url,
                rememberedName: file.pdf.fileName,
                questionCount: live.count,
                pageCount: file.pdf.pageCount,
                candidates: scored
            ))
        }
        return orphans
    }

    // MARK: - Scoring

    private static func evidence(for file: SidecarFile, pdfURL: URL, oldName: URL) -> Evidence {
        // 1. The same file, byte for byte. A rename alone lands here.
        if !file.pdf.sha256.isEmpty,
           LectureDocument.sha256OfFile(at: pdfURL) == file.pdf.sha256 {
            return .identical
        }

        // 2. The slides themselves. Each page's text was hashed when the
        //    questions were last saved, so this recognises the lecture even
        //    after it has been annotated -- annotation changes how a slide
        //    looks, not what it says.
        if let document = PDFDocument(url: pdfURL) {
            if let stored = file.pdf.pageSketches, PageSketch.isUsable(stored) {
                // Fuzzy, because an annotated slide still says most of what it
                // said before. A slide counts as found if any page of this PDF
                // is a good match for it.
                let current = PageSketch.all(in: document)
                let wanted = stored.filter { !$0.isEmpty }
                if !wanted.isEmpty {
                    let matched = wanted.filter { sketch in
                        current.contains { PageSketch.similarity(sketch, $0) >= PageSketch.goodMatch }
                    }.count
                    if matched > 0 { return .slides(matched: matched, of: wanted.count) }
                }
            } else if let stored = file.pdf.pageFingerprints, PageFingerprint.isUsable(stored) {
                // Files written by an earlier version carry exact hashes.
                let current = Set(PageFingerprint.all(in: document).filter { !$0.isEmpty })
                let wanted = stored.filter { !$0.isEmpty }
                if !wanted.isEmpty {
                    let matched = wanted.filter { current.contains($0) }.count
                    if matched > 0 { return .slides(matched: matched, of: wanted.count) }
                }
            }
        }

        // 3. The name. Weak on its own, which is why it is last and why the
        //    window shows it as words in common rather than as a verdict.
        let shared = words(oldName.lectureName)
            .intersection(words(pdfURL.lectureName))
        if !shared.isEmpty { return .name(shared: shared.count) }

        return .none
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }

    // MARK: - Applying

    /// Renames the question file to sit beside the lecture you chose.
    static func adopt(_ orphan: Orphan, pdfURL: URL) throws {
        let manager = FileManager.default
        let target = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let source = orphan.sidecarURL.standardizedFileURL
        let destination = target.standardizedFileURL
        guard source != destination else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard orphan.candidates.contains(where: {
            $0.pdfURL.standardizedFileURL == pdfURL.standardizedFileURL
        }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard !manager.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.moveItem(at: source, to: destination)
        guard !manager.fileExists(atPath: source.path),
              manager.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        AtomicWrite.setHidden(true, at: target)

        // The notes were written beside the questions and were orphaned by the
        // same rename, so they come along. Best effort: failing to move a note
        // is not a reason to leave the questions stranded, and the note is still
        // sitting under its old name where it can be found by eye.
        // The orphan's own PDF name, reconstructed from its question file, so
        // the note is looked for under the name it was actually written with.
        let strandedPDF = orphan.sidecarURL.deletingPathExtension()
            .deletingPathExtension()
            .appendingPathExtension("pdf")
        let notesSource = AnkiIdentity.notesURL(for: strandedPDF)
        let notesTarget = AnkiIdentity.notesURL(for: pdfURL)
        if manager.fileExists(atPath: notesSource.path),
           !manager.fileExists(atPath: notesTarget.path) {
            try? manager.moveItem(at: notesSource, to: notesTarget)
        }
    }
}
