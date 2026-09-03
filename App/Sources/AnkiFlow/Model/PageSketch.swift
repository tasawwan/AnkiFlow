import Foundation
import PDFKit

/// What the app proposes doing about a PDF whose slides have moved.
struct PageShift {
    let oldPageCount: Int
    let newPageCount: Int
    var moves: [PageSketch.Move]

    /// The ones a person should look at: no text to go on, a weak text match,
    /// or a slide that has gone entirely.
    var uncertain: [PageSketch.Move] { moves.filter { $0.basis.needsConfirmation } }
    var confident: [PageSketch.Move] { moves.filter { !$0.basis.needsConfirmation } }

    var headline: String {
        let moved = moves.filter { $0.newPage != $0.oldPage }.count
        let pages = oldPageCount == newPageCount
            ? "The slides in this PDF have moved"
            : "This PDF now has \(newPageCount) slides instead of \(oldPageCount)"
        return "\(pages) — \(moved) of the slides your questions use \(moved == 1 ? "is" : "are") in a different place."
    }
}

/// A fuzzy fingerprint of what a slide says, and the machinery for working out
/// where each slide went when a PDF changes.
///
/// The first version of this hashed each page's text and compared hashes. That
/// is exactly wrong for the way these files are used: annotating a lecture adds
/// and removes words, so one scribbled note changed the hash completely and the
/// slide looked like a different slide. A sketch of the *words* survives that —
/// add a few, lose a few, and the overlap is still obvious.
enum PageSketch {
    /// How many word-hashes are kept per page. Enough to tell slides apart,
    /// small enough that a 60-page deck adds a few kilobytes to the file.
    static let size = 24

    /// Below this, two slides are different slides. Chosen low: annotation can
    /// take a page a long way, and the alignment below only ever matches pages
    /// in order, so a loose threshold cannot scramble the result.
    static let goodMatch = 0.34

    // MARK: - Building

    /// Lowercased words of three letters or more, hashed to 16 bits, the lowest
    /// `size` of them kept. Keeping the *lowest* hashes rather than the first
    /// words means both sides sample the same part of the space, which is what
    /// makes the overlap a fair estimate of how much text they share.
    static func of(_ page: PDFPage) -> String {
        let words = Set((page.string ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
        guard words.count >= 3 else { return "" }

        let hashes = words.map { word -> UInt16 in
            var value: UInt64 = 1469598103934665603
            for byte in word.utf8 {
                value = (value ^ UInt64(byte)) &* 1099511628211
            }
            return UInt16(truncatingIfNeeded: value >> 17)
        }
        return Set(hashes).sorted().prefix(size)
            .map { String(format: "%04x", $0) }
            .joined()
    }

    static func all(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0).map(of) ?? "" }
    }

    static func tokens(_ sketch: String) -> Set<String> {
        guard !sketch.isEmpty else { return [] }
        return Set(stride(from: 0, to: sketch.count - 3, by: 4).map { offset in
            let start = sketch.index(sketch.startIndex, offsetBy: offset)
            let end = sketch.index(start, offsetBy: 4)
            return String(sketch[start..<end])
        })
    }

    /// Jaccard overlap: shared words over total words. 1 is identical, 0 is
    /// nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = tokens(a), right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        let total = left.union(right).count
        return total == 0 ? 0 : Double(shared) / Double(total)
    }

    // MARK: - Alignment

    /// Where a slide went, and how sure we are.
    enum Basis: Equatable {
        /// Its words matched, at this overlap.
        case text(Double)
        /// It has no readable text, but the slides either side of it both moved
        /// by the same amount, so it moved by that amount too.
        case inferred(offset: Int, agreeing: Int)
        /// No text, and its neighbours disagree — this is the app's best guess
        /// and wants a human.
        case guessed(offset: Int)
        /// Nothing in the new PDF corresponds to it.
        case gone

        var confidence: Double {
            switch self {
            case .text(let overlap):            return min(1, 0.45 + overlap * 0.55)
            case .inferred(_, let agreeing):    return agreeing >= 2 ? 0.8 : 0.6
            case .guessed:                      return 0.3
            case .gone:                         return 0
            }
        }

        var needsConfirmation: Bool {
            switch self {
            case .text(let overlap): return overlap < 0.55
            case .inferred:          return true
            case .guessed, .gone:    return true
            }
        }

        var label: String {
            switch self {
            case .text(let overlap):
                return "text matches (\(Int(overlap * 100))%)"
            case .inferred(let offset, let agreeing):
                return "no text — \(agreeing) neighbouring slides all moved \(signed(offset))"
            case .guessed(let offset):
                return "no text — neighbours disagree, guessing \(signed(offset))"
            case .gone:
                return "no matching slide found"
            }
        }

        private func signed(_ value: Int) -> String {
            value == 0 ? "not at all" : (value > 0 ? "+\(value)" : "\(value)")
        }
    }

    struct Move: Identifiable {
        var id: Int { oldPage }
        let oldPage: Int
        var newPage: Int?
        let basis: Basis
        /// How many of your questions cite this slide. Filled in by the document.
        var questionCount: Int = 0
    }

    /// Old page → new page, in order, with the reasoning attached.
    ///
    /// Order-preserving on purpose: slides get inserted, deleted and edited, but
    /// they do not get shuffled. Insisting the mapping only ever moves forward
    /// is what stops a loose text threshold pairing slide 4 with slide 30.
    static func align(old: [String], new: [String]) -> [Move] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else {
            return (0..<n).map { Move(oldPage: $0 + 1, newPage: nil, basis: .gone) }
        }

        // Needleman–Wunsch over similarity, with a small gap cost so an
        // unmatched page is cheaper than a bad pairing.
        let gap = -0.35
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { score[i][0] = score[i - 1][0] + gap }
        for j in 1...m { score[0][j] = score[0][j - 1] + gap }
        for i in 1...n {
            for j in 1...m {
                let overlap = similarity(old[i - 1], new[j - 1])
                let pair = score[i - 1][j - 1] + (overlap >= goodMatch ? overlap : -0.2)
                score[i][j] = max(pair, max(score[i - 1][j] + gap, score[i][j - 1] + gap))
            }
        }

        var moves = [Move?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            let overlap = similarity(old[i - 1], new[j - 1])
            let pair = score[i - 1][j - 1] + (overlap >= goodMatch ? overlap : -0.2)
            if score[i][j] == pair {
                if overlap >= goodMatch {
                    moves[i - 1] = Move(oldPage: i, newPage: j, basis: .text(overlap))
                }
                i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] + gap {
                i -= 1
            } else {
                j -= 1
            }
        }

        // Slides with no readable text never match anything, so they fall out of
        // the alignment entirely. Their offset comes from the anchored slides
        // around them — which is exactly how you would work it out by hand.
        let anchored: [(page: Int, offset: Int)] = moves.compactMap { move in
            guard let move, let newPage = move.newPage, case .text = move.basis else { return nil }
            return (move.oldPage, newPage - move.oldPage)
        }

        for index in 0..<n where moves[index] == nil {
            let page = index + 1
            let before = anchored.last { $0.page < page }
            let after = anchored.first { $0.page > page }
            let offsets = [before?.offset, after?.offset].compactMap { $0 }

            guard !offsets.isEmpty else {
                moves[index] = Move(oldPage: page, newPage: nil, basis: .gone)
                continue
            }
            if offsets.count == 2, offsets[0] == offsets[1] {
                let target = page + offsets[0]
                moves[index] = Move(oldPage: page, newPage: valid(target, m),
                                    basis: .inferred(offset: offsets[0], agreeing: 2))
            } else if offsets.count == 1 {
                let target = page + offsets[0]
                moves[index] = Move(oldPage: page, newPage: valid(target, m),
                                    basis: .inferred(offset: offsets[0], agreeing: 1))
            } else {
                // Neighbours disagree: the change happened right here. Take the
                // one before, because a slide belongs with what precedes it.
                let target = page + offsets[0]
                moves[index] = Move(oldPage: page, newPage: valid(target, m),
                                    basis: .guessed(offset: offsets[0]))
            }
        }

        return moves.compactMap { $0 }
    }

    private static func valid(_ page: Int, _ count: Int) -> Int? {
        (page >= 1 && page <= count) ? page : nil
    }

    /// True when enough pages carry text for any of this to mean anything.
    static func isUsable(_ sketches: [String]) -> Bool {
        guard !sketches.isEmpty else { return false }
        return sketches.contains { !$0.isEmpty }
    }
}
