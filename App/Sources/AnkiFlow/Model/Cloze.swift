import Foundation

/// Anki's cloze markup: `{{c1::hidden}}`, or `{{c1::hidden::hint}}`.
///
/// Everything here is pure string work with no Anki dependency, because the app
/// has to answer three questions about a piece of cloze text on its own: how
/// many cards it makes (the exporter writes one card row per ordinal), what each
/// card looks like (the preview), and what the question list should call it.
///
/// Nesting is not supported, deliberately. Anki allows `{{c1::a {{c2::b}}}}`,
/// but the scanner that handles it correctly is several times this size and the
/// feature is vanishingly rare in lecture notes. Text like that still exports —
/// Anki renders it fine — it is only this app's preview and label that flatten
/// it.
enum Cloze {
    /// Every deletion in the text, in the order they appear.
    struct Deletion: Equatable {
        /// The `1` in `{{c1::…}}`.
        var ordinal: Int
        /// What is hidden.
        var answer: String
        /// The optional `::hint`, shown in place of the answer on the front.
        var hint: String?
        /// Where the whole `{{c1::…}}` sits in the original string.
        var range: Range<String.Index>
    }

    /// Matches `{{cN::answer}}` and `{{cN::answer::hint}}`. Non-greedy so two
    /// deletions on one line don't collapse into one.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#,
        options: [.dotMatchesLineSeparators]
    )

    static func deletions(in text: String) -> [Deletion] {
        guard let pattern else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: full).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let ordinalRange = Range(match.range(at: 1), in: text),
                  let ordinal = Int(text[ordinalRange]), ordinal > 0,
                  let answerRange = Range(match.range(at: 2), in: text) else { return nil }
            let hint = Range(match.range(at: 3), in: text).map { String(text[$0]) }
            return Deletion(ordinal: ordinal,
                            answer: String(text[answerRange]),
                            hint: hint,
                            range: whole)
        }
    }

    /// The distinct ordinals present, ascending. This is exactly the set of
    /// cards Anki will generate, which is why the exporter uses it verbatim.
    static func ordinals(in text: String) -> [Int] {
        Array(Set(deletions(in: text).map(\.ordinal))).sorted()
    }

    static func cardCount(in text: String) -> Int { ordinals(in: text).count }

    /// The next number to use. One past the highest in the text rather than the
    /// count, so deleting c2 out of c1/c2/c3 doesn't hand out a number that is
    /// already in use.
    static func nextOrdinal(in text: String) -> Int {
        (ordinals(in: text).max() ?? 0) + 1
    }

    /// The text with all markup removed, leaving what a reader would see if
    /// nothing were hidden. Used for the question list label and the search
    /// index -- searching for a word shouldn't fail because it happens to sit
    /// inside a deletion.
    static func plainText(_ text: String) -> String {
        rewrite(text) { deletion in deletion.answer }
    }

    /// Wraps a selected substring in the next available deletion. Returns the
    /// new text, or nil when the selection is empty or already sits inside one
    /// -- nesting is what that would produce, and it is not supported.
    static func wrap(_ text: String, range: Range<String.Index>, ordinal: Int? = nil) -> String? {
        guard !range.isEmpty else { return nil }
        for deletion in deletions(in: text) where deletion.range.overlaps(range) { return nil }
        let number = ordinal ?? nextOrdinal(in: text)
        var out = text
        out.replaceSubrange(range, with: "{{c\(number)::\(text[range])}}")
        return out
    }

    /// The front of the card testing `ordinal`: that deletion becomes `[...]`
    /// (or its hint), and every other deletion shows its answer -- which is
    /// exactly what Anki's `{{cloze:…}}` does.
    static func front(_ text: String, ordinal: Int) -> String {
        rewrite(text) { deletion in
            guard deletion.ordinal == ordinal else { return deletion.answer }
            if let hint = deletion.hint, !hint.isEmpty { return "[\(hint)]" }
            return "[...]"
        }
    }

    /// The back of that card: everything shown, with the tested deletion marked
    /// so you can see which one it was.
    static func back(_ text: String, ordinal: Int, marker: (String) -> String) -> String {
        rewrite(text) { deletion in
            deletion.ordinal == ordinal ? marker(deletion.answer) : deletion.answer
        }
    }

    /// The markup for a deletion, at whatever card number you ask for.
    static func markup(_ deletion: Deletion, ordinal: Int) -> String {
        if let hint = deletion.hint, !hint.isEmpty {
            return "{{c\(ordinal)::\(deletion.answer)::\(hint)}}"
        }
        return "{{c\(ordinal)::\(deletion.answer)}}"
    }

    /// Move one deletion onto a different card. The index is its position in
    /// `deletions(in:)` -- reading order, which is the order the panel lists
    /// them in, and the only handle a deletion has: two deletions can share an
    /// ordinal and two can hide the same words.
    static func renumber(_ text: String, deletionAt index: Int, to ordinal: Int) -> String {
        rewriteIndexed(text) { position, deletion in
            markup(deletion, ordinal: position == index ? ordinal : deletion.ordinal)
        }
    }

    /// Stop hiding one phrase, leaving the words where they are.
    static func unwrap(_ text: String, deletionAt index: Int) -> String {
        rewriteIndexed(text) { position, deletion in
            position == index ? deletion.answer : markup(deletion, ordinal: deletion.ordinal)
        }
    }

    /// One card each, or all of them on one.
    static func regrouped(_ text: String, separate: Bool) -> String {
        var next = 0
        return rewriteIndexed(text) { _, deletion in
            if separate {
                next += 1
                return markup(deletion, ordinal: next)
            }
            return markup(deletion, ordinal: 1)
        }
    }

    /// Close the gaps so the numbers read 1, 2, 3 rather than 1, 3, 7.
    ///
    /// Cosmetic to Anki, which only cares that ordinals differ -- but the panel
    /// lists them by number, and "Card 7" of three cards is a puzzle.
    static func compacted(_ text: String) -> String {
        var map: [Int: Int] = [:]
        for (index, ordinal) in ordinals(in: text).enumerated() { map[ordinal] = index + 1 }
        return rewriteIndexed(text) { _, deletion in
            markup(deletion, ordinal: map[deletion.ordinal] ?? deletion.ordinal)
        }
    }

    /// Rebuilds the string with each deletion replaced by whatever `body`
    /// returns, told which one it is.
    private static func rewriteIndexed(_ text: String, body: (Int, Deletion) -> String) -> String {
        let found = deletions(in: text)
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for (index, deletion) in found.enumerated() {
            guard deletion.range.lowerBound >= cursor else { continue }
            out += text[cursor..<deletion.range.lowerBound]
            out += body(index, deletion)
            cursor = deletion.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// Rebuilds the string with each deletion replaced by whatever `body`
    /// returns. Walks the matches in order and copies the gaps between them, so
    /// the untouched text is preserved byte for byte.
    private static func rewrite(_ text: String, body: (Deletion) -> String) -> String {
        let found = deletions(in: text)
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for deletion in found {
            guard deletion.range.lowerBound >= cursor else { continue }
            out += text[cursor..<deletion.range.lowerBound]
            out += body(deletion)
            cursor = deletion.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
