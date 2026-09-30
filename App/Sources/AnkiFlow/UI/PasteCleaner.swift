import AppKit

/// Pasting text copied out of a PDF.
///
/// A PDF has no paragraphs. Every visual line is its own line of text, so
/// copying three lines of a slide and pasting them gives you three lines --
/// with the wrap positions of a document you are no longer looking at, baked
/// into a card you will read on a phone. `pasteAsPlainText:` does not help:
/// it drops fonts and colours, which was never the problem, and keeps every
/// line break, which always was.
///
/// So this rewrites the text rather than the styling, and pastes through the
/// ordinary `paste:` action -- which every text view answers, including
/// SwiftUI's own, where the AppKit responder action silently did nothing.
enum PasteCleaner {
    /// Cleans the clipboard, pastes, and puts the clipboard back as it was.
    ///
    /// Restoring matters: the next thing you paste is as likely to be going
    /// somewhere else, and a command that quietly rewrites the clipboard is a
    /// command you stop trusting.
    static func pasteReflowed() {
        let pasteboard = NSPasteboard.general
        guard let original = pasteboard.string(forType: .string) else { return }
        let cleaned = reflow(original)

        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)

        // After the paste has been handled, not in the same breath as it: some
        // text views take the pasteboard on the next pass of the run loop.
        DispatchQueue.main.async {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
        }
    }

    /// Joins the lines a PDF wrapped, and keeps the ones a person meant.
    ///
    /// The rule is that a blank line is a paragraph and a single newline is a
    /// wrap -- true of every PDF and of most things copied from the web. Two
    /// exceptions earn their keep: a line that begins with a bullet or a number
    /// is a list item, and a line after one ending in a colon is the start of
    /// the list it introduces. Joining either of those turns a readable list
    /// into a run-on sentence.
    static func reflow(_ text: String) -> String {
        var working = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Soft hyphens: invisible, and they survive the copy.
            .replacingOccurrences(of: "\u{00AD}", with: "")

        // A word split across a line break by the typesetter. Only between two
        // word characters, so "self-\nassembly" is not silently welded shut...
        // which it is, but a real compound hyphen at a line end is rare and a
        // typeset break is not.
        working = working.replacingOccurrences(
            of: "(\\w)-\\n(\\w)", with: "$1$2", options: .regularExpression)

        let paragraphs = working.components(separatedBy: .newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })

        var out: [String] = []
        for paragraph in paragraphs {
            var joined = ""
            for raw in paragraph {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if joined.isEmpty {
                    joined = line
                } else if isListItem(line) || joined.hasSuffix(":") {
                    joined += "\n" + line
                } else {
                    joined += " " + line
                }
            }
            if !joined.isEmpty { out.append(joined) }
        }

        return out.joined(separator: "\n\n")
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: "^([•◦▪–—\\-\\*·]|\\(?\\d+[\\.\\)]|[a-z]\\))\\s+",
                   options: .regularExpression) != nil
    }
}
