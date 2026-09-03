import Foundation
import PDFKit
import CryptoKit

/// Short hashes of each page's text, stored beside the questions.
///
/// Page numbers are absolute. Insert one slide into a lecture and every question
/// after it points one slide too early — silently, with nothing in the app or in
/// Anki to notice. That is the one failure here that can quietly cost a semester
/// of cards, and annotating in another app makes it a live risk rather than a
/// theoretical one.
///
/// Recording what each page *said* turns "the page count changed" into "page 14
/// is now page 15", which is a thing the app can fix for you.
enum PageFingerprint {
    /// Whitespace-collapsed, lowercased, hashed to six bytes. Text only: the
    /// point is to recognise a slide again after it has been annotated, and
    /// annotations change the rendering, not the words.
    static func of(_ page: PDFPage) -> String {
        let text = (page.string ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        guard text.count >= 8 else { return "" }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func all(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { index in
            document.page(at: index).map(of) ?? ""
        }
    }

    /// True when enough pages carry text to identify them. A scanned deck with
    /// no text layer can't be realigned this way, and guessing would be worse
    /// than saying nothing.
    static func isUsable(_ prints: [String]) -> Bool {
        guard !prints.isEmpty else { return false }
        let named = prints.filter { !$0.isEmpty }.count
        return Double(named) / Double(prints.count) >= 0.6
    }

    /// Old page number → new page number, 1-based.
    ///
    /// Greedy first-unused match rather than a diff: it handles insertion,
    /// deletion and reordering alike, and a slide whose text changed simply
    /// doesn't appear in the map, which is the honest answer for it.
    static func remap(from old: [String], to new: [String]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var used = Set<Int>()
        for (oldIndex, hash) in old.enumerated() where !hash.isEmpty {
            guard let newIndex = new.indices.first(where: { new[$0] == hash && !used.contains($0) })
            else { continue }
            used.insert(newIndex)
            map[oldIndex + 1] = newIndex + 1
        }
        return map
    }

    /// True when the map actually moves something. An unchanged PDF maps every
    /// page to itself, and there is nothing to tell the user about that.
    static func isShift(_ map: [Int: Int]) -> Bool {
        map.contains { $0.key != $0.value }
    }
}
