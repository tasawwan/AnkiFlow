import Foundation
import AppKit

/// Turns the notes editor's styled text into a Markdown file, and back.
///
/// The editor offers exactly what Markdown can hold, and nothing else: headings,
/// bold, italic, strikethrough, bullets, links, and underline as the one `<u>`
/// tag every renderer honours.
///
/// An earlier version wrote colour, point size and typeface as inline
/// `<span style="…">`. It round-tripped, and it was wrong. Markdown has no
/// notion of 18pt or blue, so the file filled with HTML that only this app could
/// have produced -- and the reason notes live beside the PDFs as plain `.md` is
/// that they should read well in Obsidian, on a phone, in TextEdit, in ten
/// years. Making text bigger has a Markdown answer already: it is a heading.
///
/// The rule this file keeps: if the format cannot say it, the editor does not
/// offer it. A button that silently loses your formatting on save is worse than
/// no button.
enum RichTextMarkdown {

    // MARK: - Attributes

    /// The editor's defaults, and what "no formatting" means when reading a file.
    ///
    /// Set for reading, not for fitting: notes are prose you write in long
    /// stretches and come back to, so they get a size you would accept in a text
    /// editor rather than the smaller one the app's chrome uses.
    /// How big body text is drawn in the editor.
    ///
    /// A display setting, not a document one -- Markdown has no way to record a
    /// point size, so this is never written to the file and every note opens at
    /// whatever size you last chose. Starts at 17 rather than the 13pt macOS
    /// uses for body text: these are notes taken during a lecture and read back
    /// while tired, not a settings panel. Mutable because the heading sizes and the
    /// heading *detection* on the way back out are both defined relative to it,
    /// so reader and writer have to agree on one number.
    static var baseSize: CGFloat = {
        let stored = CGFloat(UserDefaults.standard.double(forKey: "notesTextSize"))
        return sizeRange.contains(stored) ? stored : 17
    }()
    static let sizeRange: ClosedRange<CGFloat> = 11...26
    static var baseFont: NSFont { .systemFont(ofSize: baseSize) }

    /// The same text at a new base size, re-fonted in place.
    ///
    /// Deliberately *not* a round trip through Markdown. Changing how big your
    /// notes look is a view setting, and routing it through the reader and the
    /// writer would put every character of your writing through a conversion
    /// twice for a change that is only ever about points on screen -- a
    /// conversion this app has already had one bug in. Nothing here parses
    /// anything: each run keeps its font, its traits and its heading level, and
    /// only the point size moves.
    ///
    /// Sizes are rebuilt from the heading level rather than multiplied by a
    /// ratio, because a heading is `base + 9`, not `base × 1.5`. Scaling
    /// proportionally would drift the offsets until `headingLevel(of:)` stopped
    /// recognising them, and *that* would reach the file -- a heading saved as
    /// body text.
    static func rescaled(_ text: NSAttributedString, from old: CGFloat) -> NSAttributedString {
        guard text.length > 0, old > 0 else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.beginEditing()
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            // Which rung this run was on, by how far above the old base it sat.
            let offset = font.pointSize - old
            let rung = [CGFloat(9), 5, 2, 0].min {
                abs($0 - offset) < abs($1 - offset)
            } ?? 0
            let resized = NSFontManager.shared.convert(font, toSize: baseSize + rung)
            out.addAttribute(.font, value: resized, range: range)
        }
        out.endEditing()
        return out
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 9
        case 2: return baseSize + 5
        case 3: return baseSize + 2
        default: return baseSize
        }
    }

    // MARK: - Taking text in from elsewhere

    /// A leading bullet or number the source wrote into the text itself.
    ///
    /// Em and en dashes are deliberately not here: a paragraph that opens with
    /// one is a sentence, not a list, and turning it into a bullet would be the
    /// paste rewriting your prose.
    private static let pastedMarker = try? NSRegularExpression(
        pattern: "^[ \\t\\u00A0]*(?:[\\u2022\\u2023\\u25AA\\u25E6\\u00B7\\u25CB]|[-*+]|\\d+[.)])[ \\t\\u00A0]+")

    /// Pasted text, reduced to the things this format can actually record.
    ///
    /// The editor writes Markdown, and Markdown has room for exactly what the
    /// toolbar offers: three heading levels, bold, italic, underline,
    /// strikethrough, links and bullets. Everything a web page or a Word
    /// document also carries -- colours, typefaces, shading, tables, images,
    /// arbitrary point sizes -- has nowhere to go.
    ///
    /// So it is converted on the way *in*, where you can see it happen and undo
    /// it, rather than quietly dropped on the way out to the file. A paste that
    /// looks right in the editor and saves as something else is the failure
    /// this avoids.
    ///
    /// Heading level is read against the source's own body size, not this
    /// app's: a web page's 16pt heading is a heading even though it is smaller
    /// than the 17pt these notes are written at.
    static func normalised(_ text: NSAttributedString, textColour: NSColor) -> NSAttributedString {
        guard text.length > 0 else { return NSAttributedString() }
        let body = dominantSize(in: text)
        let source = text.string as NSString
        let out = NSMutableAttributedString()
        let plain = styled(level: 0, traits: [], textColour: textColour)

        var location = 0
        var first = true
        while location < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            location = max(NSMaxRange(paragraph), location + 1)

            // The break is written here rather than kept from the source, so a
            // line separator and a paragraph mark come out the same.
            if !first { out.append(NSAttributedString(string: "\n", attributes: plain)) }
            first = false

            var content = paragraph
            while content.length > 0,
                  let last = Unicode.Scalar(source.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(last) {
                content.length -= 1
            }
            guard content.length > 0 else { continue }

            let opening = text.attributes(at: content.location, effectiveRange: nil)
            let level = headingRung(for: opening[.font] as? NSFont, body: body)
            let style = opening[.paragraphStyle] as? NSParagraphStyle

            // A list is either declared in the paragraph style, which is what
            // HTML gives, or written into the text as a character, which is what
            // plain text and most editors give.
            var listLevel: Int?
            if let lists = style?.textLists, !lists.isEmpty { listLevel = lists.count - 1 }
            var start = content.location
            let line = source.substring(with: content)
            if let match = pastedMarker?.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let marker = (line as NSString).substring(with: match.range)
                if listLevel == nil {
                    listLevel = marker.reduce(0) { depth, character in
                        depth + (character == "\t" ? 4 : character == " " ? 1 : 0)
                    } / 4
                }
                start += match.range.length
            }
            if let listLevel {
                out.append(NSAttributedString(
                    string: String(repeating: " ", count: max(0, listLevel) * 4)
                        + (max(0, listLevel).isMultiple(of: 2) ? "\u{2022} " : "- "),
                    attributes: plain))
            }

            let rest = NSRange(location: start, length: NSMaxRange(content) - start)
            guard rest.length > 0 else { continue }
            text.enumerateAttributes(in: rest, options: []) { attributes, range, _ in
                // An image, a table cell marker or a soft line break inside a
                // paragraph: nothing Markdown can hold, so it does not survive.
                let piece = source.substring(with: range)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\u{2028}", with: " ")
                    .replacingOccurrences(of: "\u{0009}", with: " ")
                guard !piece.isEmpty else { return }
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                var built = styled(level: level, traits: traits, textColour: textColour)
                if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                    built[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                    built[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = attributes[.link] { built[.link] = link }
                out.append(NSAttributedString(string: piece, attributes: built))
            }
        }
        return out
    }

    /// The size most of the text is set in -- the source's idea of body.
    private static func dominantSize(in text: NSAttributedString) -> CGFloat {
        var tally: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            guard let font = value as? NSFont else { return }
            tally[font.pointSize, default: 0] += range.length
        }
        return tally.max { $0.value < $1.value }?.key ?? baseSize
    }

    /// Which heading rung a run belongs on, by the same test `headingLevel`
    /// applies on the way out -- measured against `body` rather than `baseSize`,
    /// so it reads a foreign document on that document's terms.
    private static func headingRung(for font: NSFont?, body: CGFloat) -> Int {
        guard let font, font.fontDescriptor.symbolicTraits.contains(.bold) else { return 0 }
        switch font.pointSize {
        case let size where size >= body + 7: return 1
        case let size where size >= body + 4: return 2
        case let size where size >= body + 2: return 3
        default: return 0
        }
    }

    /// One run, rebuilt out of the only ingredients this editor has.
    private static func styled(level: Int, traits: NSFontDescriptor.SymbolicTraits,
                               textColour: NSColor) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: headingSize(level))
        if level > 0 || traits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return [.font: font, .foregroundColor: textColour]
    }

    // MARK: - Writing

    static func markdown(from text: NSAttributedString) -> String {
        var out: [String] = []
        let whole = NSRange(location: 0, length: text.length)
        let plain = text.string as NSString

        // Paragraph by paragraph: block structure (headings, lists) is a
        // property of the line, inline styling a property of a run inside it.
        plain.enumerateSubstrings(in: whole, options: [.byParagraphs]) { _, range, _, _ in
            let paragraph = text.attributedSubstring(from: range)
            out.append(line(from: paragraph))
        }
        // A blank line after every block. Markdown joins adjacent lines into one
        // paragraph, so without this two paragraphs you typed separately come
        // back as one -- except between consecutive list items, where adjacency
        // is what keeps them one list.
        var result: [String] = []
        for (index, line) in out.enumerated() {
            if line.isEmpty && result.last?.isEmpty == true { continue }
            result.append(line)
            guard !line.isEmpty else { continue }
            let bothList = line.range(of: #"^\s*-\s"#, options: .regularExpression) != nil
                && index + 1 < out.count
                && out[index + 1].range(of: #"^\s*-\s"#, options: .regularExpression) != nil
            if !bothList { result.append("") }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private static func line(from paragraph: NSAttributedString) -> String {
        let raw = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        var prefix = ""
        var body = paragraph
        // A heading is a paragraph whose whole run is larger than the base and
        // bold -- which is exactly what the Heading buttons produce.
        if let size = headingLevel(of: paragraph) {
            prefix = String(repeating: "#", count: size) + " "
        }
        if let (marker, rest) = listMarker(of: paragraph) {
            prefix = marker
            body = rest
        }
        return prefix + inline(from: body)
    }

    /// 1, 2 or 3 for a heading paragraph; nil for body text.
    private static func headingLevel(of paragraph: NSAttributedString) -> Int? {
        guard paragraph.length > 0 else { return nil }
        let attributes = paragraph.attributes(at: 0, effectiveRange: nil)
        guard let font = attributes[.font] as? NSFont,
              font.fontDescriptor.symbolicTraits.contains(.bold) else { return nil }
        switch font.pointSize {
        case let size where size >= baseSize + 7: return 1
        case let size where size >= baseSize + 4: return 2
        case let size where size >= baseSize + 2: return 3
        default: return nil
        }
    }

    /// Splits a leading bullet or number off a paragraph, so the marker is not
    /// written twice when the text already contains it.
    private static func listMarker(of paragraph: NSAttributedString) -> (String, NSAttributedString)? {
        let text = paragraph.string
        guard let match = text.range(of: #"^([ \t]*)(?:•|[-*+]) "#, options: .regularExpression) else {
            return nil
        }
        let marker = String(text[..<match.upperBound])
        let indentation = marker.dropLast(2)
        let level = indentation.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        } / 4
        let markdownMarker = level.isMultiple(of: 2) ? "* " : "- "
        let rest = paragraph.attributedSubstring(
            from: NSRange(location: marker.count, length: paragraph.length - marker.count))
        return (String(repeating: " ", count: level * 4) + markdownMarker, rest)
    }

    /// One paragraph's runs, each wrapped in whatever markup it needs.
    private static func inline(from paragraph: NSAttributedString) -> String {
        var out = ""
        let whole = NSRange(location: 0, length: paragraph.length)
        paragraph.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            var piece = (paragraph.string as NSString).substring(with: range)
            guard !piece.isEmpty else { return }

            // Spaces are lifted out and put back around the markup: "**bold **"
            // is not bold in Markdown, because the closing marker has to sit
            // against a non-space character.
            let leading = String(piece.prefix { $0 == " " })
            let trailing = String(piece.reversed().prefix { $0 == " " })
            piece = String(piece.dropFirst(leading.count).dropLast(trailing.count))
            guard !piece.isEmpty else { out += leading + trailing; return }

            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let isHeading = headingLevel(of: paragraph) != nil

            if attributes[.underlineStyle] != nil {
                piece = "<u>\(piece)</u>"
            }
            if attributes[.strikethroughStyle] != nil {
                piece = "~~\(piece)~~"
            }
            // A heading is already bold by definition; writing ** inside a #
            // line would show the asterisks.
            if traits.contains(.bold), !isHeading {
                piece = "**\(piece)**"
            }
            if traits.contains(.italic) {
                piece = "*\(piece)*"
            }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? String(describing: link)
                piece = "[\(piece)](\(url))"
            }
            out += leading + piece + trailing
        }
        return out
    }

    // MARK: - Reading

    /// Parses a note file back into styled text.
    ///
    /// Hand-written rather than `NSAttributedString(markdown:)`, which drops the
    /// inline HTML this writes -- underline, colour and size would be lost on
    /// every open, which is a worse bug than any it would save.
    static func attributedString(from markdown: String, textColour: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, raw) in lines.enumerated() {
            var line = raw
            var size = baseSize
            var bold = false
            var listPrefix = ""
            var isBullet = false

            if let hashes = line.range(of: "^#{1,6} ", options: .regularExpression) {
                let level = line.distance(from: line.startIndex, to: hashes.upperBound) - 1
                line = String(line[hashes.upperBound...])
                bold = true
                size = headingSize(min(level, 3))
            } else if let marker = line.range(of: "^[ \\t]*[-*+] ",
                                              options: .regularExpression) {
                // The indentation is *inside* the match. The pattern is anchored
                // to the start of the line, so `lowerBound` is always zero and
                // slicing up to it produced an empty prefix -- which meant every
                // bullet read back from a file came home flat and, because the
                // marker was only written when that prefix was non-empty, with
                // no bullet on it at all. Nesting typed into the editor survived
                // until the first reload and then quietly went away.
                listPrefix = String(line[marker].dropLast(2))
                line = String(line[marker.upperBound...])
                isBullet = true
            }

            let base: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: textColour
            ]
            if isBullet {
                let level = listPrefix.reduce(0) { count, character in
                    count + (character == "\t" ? 4 : 1)
                } / 4
                let marker = level.isMultiple(of: 2) ? "• " : "- "
                out.append(NSAttributedString(
                    string: String(repeating: " ", count: level * 4) + marker,
                    attributes: base
                ))
            }
            out.append(parseInline(line, base: base, textColour: textColour))
            if index < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return out
    }

    /// Walks one line, peeling off the markers this file knows how to write.
    private static func parseInline(_ line: String, base: [NSAttributedString.Key: Any],
                                    textColour: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var rest = Substring(line)
        var pending = ""

        func flush() {
            guard !pending.isEmpty else { return }
            out.append(NSAttributedString(string: pending, attributes: base))
            pending = ""
        }

        /// Everything between `open` and the next `close`, or nil.
        func take(_ open: String, _ close: String, from text: Substring) -> (inner: Substring, after: Substring)? {
            guard text.hasPrefix(open) else { return nil }
            let body = text.dropFirst(open.count)
            guard let end = body.range(of: close) else { return nil }
            return (body[body.startIndex..<end.lowerBound], body[end.upperBound...])
        }

        while !rest.isEmpty {
            // Links first: their label can contain any of the others.
            if rest.hasPrefix("["), let close = rest.range(of: "]("),
               let end = rest[close.upperBound...].firstIndex(of: ")") {
                flush()
                let label = rest[rest.index(after: rest.startIndex)..<close.lowerBound]
                let target = rest[close.upperBound..<end]
                var attributes = base
                attributes[.link] = URL(string: String(target)) ?? String(target)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = NSColor.linkColor
                out.append(parseInline(String(label), base: attributes, textColour: textColour))
                rest = rest[rest.index(after: end)...]
                continue
            }
            if let (inner, after) = take("<u>", "</u>", from: rest) {
                flush()
                var attributes = base
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                out.append(parseInline(String(inner), base: attributes, textColour: textColour))
                rest = after
                continue
            }
            if let (inner, after) = take("~~", "~~", from: rest) {
                flush()
                var attributes = base
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                out.append(parseInline(String(inner), base: attributes, textColour: textColour))
                rest = after
                continue
            }
            if let (inner, after) = take("**", "**", from: rest) {
                flush()
                out.append(parseInline(String(inner),
                                       base: withTrait(.bold, in: base), textColour: textColour))
                rest = after
                continue
            }
            if rest.hasPrefix("*"), let (inner, after) = take("*", "*", from: rest) {
                flush()
                out.append(parseInline(String(inner),
                                       base: withTrait(.italic, in: base), textColour: textColour))
                rest = after
                continue
            }
            pending.append(rest.removeFirst())
        }
        flush()
        return out
    }

    private static func withTrait(_ trait: NSFontDescriptor.SymbolicTraits,
                                  in attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var out = attributes
        let font = (attributes[.font] as? NSFont) ?? baseFont
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(trait)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        out[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        return out
    }
}
