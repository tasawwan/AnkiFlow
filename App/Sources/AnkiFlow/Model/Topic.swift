import Foundation

/// How well you know a topic.
///
/// Four rungs. Three cannot separate "I have read it" from "I could teach it",
/// and five is a scale nobody applies to themselves the same way twice.
enum Comfort: String, CaseIterable, Comparable, Codable {
    case low, medium, high, mastered

    var label: String {
        switch self {
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .high:     return "High"
        case .mastered: return "Mastered"
        }
    }

    /// The button walks the rungs and wraps, so a misclick costs three more
    /// clicks rather than a trip into a menu.
    var next: Comfort {
        let rungs = Comfort.allCases
        return rungs[((rungs.firstIndex(of: self) ?? 0) + 1) % rungs.count]
    }

    var rank: Int { Comfort.allCases.firstIndex(of: self) ?? 0 }

    var symbol: String {
        switch self {
        case .low:      return "circle"
        case .medium:   return "circle.lefthalf.filled"
        case .high:     return "circle.fill"
        case .mastered: return "checkmark.circle.fill"
        }
    }

    static func < (a: Comfort, b: Comfort) -> Bool { a.rank < b.rank }
}

/// One thing you are trying to learn from a lecture. A name and how well you
/// know it -- the writing about it goes in the notes, which is why this holds no
/// prose of its own.
struct Topic: Identifiable, Equatable {
    var name: String
    var comfort: Comfort
    /// Which section of the panel this sits in -- "Concepts", "Dx", "Rx", or
    /// anything you have added. A plain string rather than a case, because the
    /// list of types is yours to change and a lecture written under a type you
    /// later switch off still has to say what it said.
    var type: String = TopicType.fallback

    /// Topics are unique by name within a lecture, so the name is the identity.
    /// Case-insensitively: "Preload" and "preload" are the same thing you are
    /// trying to learn, and two rows for it would let their ratings disagree.
    var id: String { name.lowercased() }
}

/// A section of the topics panel: a name, and whether you are still filing
/// things under it.
///
/// Switching one off does not delete anything. Topics already filed under it
/// stay in their notes files and keep their section -- shown as off, with no way
/// to add to it -- until they are moved or deleted, and the section then goes on
/// its own. Hiding them instead would put work somewhere you cannot see it and
/// give you nowhere to deal with it.
struct TopicType: Codable, Identifiable, Equatable {
    var name: String
    var enabled: Bool = true

    var id: String { name.lowercased() }
    var isBuiltIn: Bool {
        TopicType.builtIn.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Where a topic goes when nothing says otherwise: a file written before
    /// types existed, or a line typed by hand above the first sub-heading.
    static let fallback = "Concepts"
    static let builtIn = [fallback, "Dx", "Tx", "Rx"]
    static let defaults = builtIn.map { TopicType(name: $0) }

    /// The configured order, kept in step with settings so the file writer can
    /// reach it without every call site passing it along.
    static var order: [String] = builtIn

    /// One line, no leading hashes, no surrounding space. Unlike a tag, a type
    /// is a heading in your notes file and keeps the capitals you gave it.
    static func tidy(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// Reading and writing the topic list, which lives at the top of the lecture's
/// Notes.md rather than in the question sidecar.
///
/// The file is the point. Open the notes anywhere -- VS Code, a preview pane, a
/// text editor on a phone -- and the topic list is right there above the notes
/// it belongs to, as an ordinary bulleted list sorted weakest-first. The comment
/// markers make the block findable without showing up in any rendered view of
/// the Markdown, and everything between them is parsed forgivingly, so a topic
/// you add by hand in another editor is a topic the app picks up.
enum TopicBlock {
    static let opener = "<!-- ankiflow:topics -->"
    static let closer = "<!-- /ankiflow:topics -->"
    static let heading = "## Topics"

    /// The block and the prose, separated. The prose is what the editor shows;
    /// the block never appears there.
    static func split(_ markdown: String) -> (topics: [Topic], body: String) {
        guard let start = markdown.range(of: opener),
              let end = markdown.range(of: closer,
                                       range: start.upperBound..<markdown.endIndex)
        else { return ([], markdown) }

        let inside = String(markdown[start.upperBound..<end.lowerBound])
        var body = markdown
        body.removeSubrange(start.lowerBound..<end.upperBound)
        return (parse(inside), body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The file as it should be written: the list on top, sorted by how much
    /// work each topic still needs, then the notes.
    /// The order sections are written in: the types you have configured first,
    /// in your order, then any the file carries that you have not -- a type you
    /// switched off, or a heading typed by hand in another editor. Neither is an
    /// error, and neither is dropped.
    static func sections(in topics: [Topic], configured: [String]) -> [String] {
        var out = configured
        for topic in topics where !out.contains(where: { $0.caseInsensitiveCompare(topic.type) == .orderedSame }) {
            out.append(topic.type)
        }
        return out
    }

    static func join(topics: [Topic], body: String,
                     configured: [String] = TopicType.order) -> String {
        let prose = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topics.isEmpty else { return prose }

        var lines = [opener, "", heading]
        for section in sections(in: topics, configured: configured) {
            let inside = sorted(topics.filter {
                $0.type.caseInsensitiveCompare(section) == .orderedSame
            })
            guard !inside.isEmpty else { continue }
            lines.append("")
            lines.append("### \(section)")
            lines.append("")
            for topic in inside {
                lines.append("- \(topic.name) — \(topic.comfort.rawValue)")
            }
        }
        lines.append("")
        lines.append(closer)
        let block = lines.joined(separator: "\n")
        return prose.isEmpty ? block + "\n" : block + "\n\n" + prose + "\n"
    }

    /// Weakest first: the list is a study order, and the thing you have not
    /// learned yet is the thing worth putting at the top of the page.
    static func sorted(_ topics: [Topic]) -> [Topic] {
        topics.sorted {
            $0.comfort == $1.comfort
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.comfort < $1.comfort
        }
    }

    static func parse(_ block: String) -> [Topic] {
        var found: [Topic] = []
        // Anything above the first sub-heading belongs to the default type,
        // which is what every file written before types existed looks like.
        var section = TopicType.fallback
        for rawLine in block.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("###") {
                let name = TopicType.tidy(String(line.drop(while: { $0 == "#" })))
                if !name.isEmpty { section = name }
                continue
            }
            // "## Topics" and anything else at that level is the block's own
            // heading, not a type.
            guard !line.hasPrefix("#") else { continue }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            let parsed = splitComfort(from: line)
            let name = tidy(parsed.name)
            guard !name.isEmpty,
                  !found.contains(where: { $0.id == name.lowercased() }) else { continue }
            found.append(Topic(name: name, comfort: parsed.comfort, type: section))
        }
        return sorted(found)
    }

    /// Reads a lecture's topics without opening the lecture. What the library
    /// view is built from.
    static func topics(inFileAt url: URL) -> [Topic] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return split(text).topics
    }

    /// True when the file's topic block is already exactly what this app would
    /// write: every topic rated, in order.
    ///
    /// The block alone is compared, never the prose. Re-emitting somebody's
    /// notes because a round-trip through the rich-text layer moved a space
    /// would be a silent edit of their writing, and the whole point of keeping
    /// notes in a plain file is that nothing edits them but you.
    static func blockIsCanonical(in markdown: String) -> Bool {
        guard let start = markdown.range(of: opener),
              let end = markdown.range(of: closer,
                                       range: start.upperBound..<markdown.endIndex)
        else { return true }
        let current = String(markdown[start.lowerBound..<end.upperBound])
        let wanted = join(topics: parse(String(markdown[start.upperBound..<end.lowerBound])),
                          body: "")
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
            == wanted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read, change, write -- for a lecture that is not the one on screen.
    /// Rating a topic from the library list has to reach that lecture's file,
    /// and the open lecture is never routed through here: it goes through its
    /// own `LectureNotes`, which owns the file and is watching it.
    static func rate(_ topic: Topic, to comfort: Comfort, inFileAt url: URL) throws {
        try change(topic, inFileAt: url) { $0[$1].comfort = comfort }
    }

    static func rename(_ topic: Topic, to name: String, inFileAt url: URL) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != topic.name else { return }
        try change(topic, inFileAt: url) { topics, index in
            // A rename onto a name already in the list would give one topic two
            // rows with two ratings that can disagree. Left alone rather than
            // merged: which of the two ratings survives is not a call to make on
            // somebody's behalf.
            guard !topics.contains(where: { $0.id == cleaned.lowercased() && $0.id != topic.id })
            else { return }
            topics[index].name = cleaned
        }
    }

    /// Re-files topics in a lecture's notes without opening it.
    ///
    /// Takes the whole set at once rather than one call per topic: each call
    /// rewrites the file, and a lecture with a dozen misfiled topics would
    /// otherwise be a dozen rewrites of the same prose.
    ///
    /// Returns how many actually moved.
    @discardableResult
    static func refile(_ wanted: [String: String], inFileAt url: URL) throws -> Int {
        guard !wanted.isEmpty,
              let existing = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var parts = split(existing)
        var moved = 0
        for (name, type) in wanted {
            guard let index = parts.topics.firstIndex(where: { $0.id == name.lowercased() }),
                  parts.topics[index].type.caseInsensitiveCompare(type) != .orderedSame
            else { continue }
            parts.topics[index].type = type
            moved += 1
        }
        guard moved > 0 else { return 0 }
        let markdown = join(topics: parts.topics, body: parts.body)
        try AtomicWrite.write(Data(markdown.utf8), to: url, hidden: false)
        return moved
    }

    static func remove(_ topic: Topic, inFileAt url: URL) throws {
        try change(topic, inFileAt: url) { $0.remove(at: $1) }
    }

    private static func change(_ topic: Topic, inFileAt url: URL,
                               _ edit: (inout [Topic], Int) -> Void) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parts = split(existing)
        guard let index = parts.topics.firstIndex(where: { $0.id == topic.id }) else { return }
        edit(&parts.topics, index)
        let markdown = join(topics: parts.topics, body: parts.body)
        // Removing the last topic from a lecture that had no prose leaves
        // nothing worth a file, and the same rule holds here as in the editor:
        // an empty .md beside a PDF is clutter, and indistinguishable from notes
        // you have lost.
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try AtomicWrite.write(Data(markdown.utf8), to: url, hidden: false)
    }

    // MARK: - Forgiving reading

    /// A rating on the end of the line if there is one, and the whole line as a
    /// topic name if there is not -- because a line someone typed by hand in
    /// another editor is a topic they have not rated, not a parse error.
    private static func splitComfort(from line: String) -> (name: String, comfort: Comfort) {
        for separator in [" — ", " -- ", " – ", " - "] {
            guard let range = line.range(of: separator, options: .backwards) else { continue }
            let tail = tidy(String(line[range.upperBound...])).lowercased()
            if let comfort = Comfort(rawValue: tail) {
                return (String(line[..<range.lowerBound]), comfort)
            }
        }
        return (line, .low)
    }

    /// Strips the emphasis and code marks someone might have wrapped a name in.
    private static func tidy(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        while let first = out.first, "`*_".contains(first) { out.removeFirst() }
        while let last = out.last, "`*_".contains(last) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
