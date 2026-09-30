import Foundation

/// A question the lecture left you with. A draft card.
///
/// This is the thing you scribble in the margin while the lecturer is still
/// talking -- the bit that did not land -- and the answer you write once it
/// does. It has everything a card has: both sides, slides on either side, tags.
/// What it does not have is a place in the question file, because it is not
/// finished: it lives in the lecture's notes until you promote it, and then it
/// crosses over whole, with nothing to fill in again.
struct LectureQuestion: Identifiable, Equatable {
    var text: String
    /// Plain text. Deliberately not rich: this sits inside a list row, and a
    /// second styled editor in there would cost more than bold is worth.
    var answer: String
    /// 1-based page numbers shown with the question -- the card's front.
    var questionSlides: [Int]
    /// 1-based page numbers attached to the answer -- the card's back.
    var answerSlides: [Int]
    /// Carried onto the card when this is promoted, so tagging while the
    /// lecture is still running is not work you do twice.
    var tags: [String]
    var answered: Bool

    init(text: String, answer: String = "", questionSlides: [Int] = [],
         answerSlides: [Int] = [], tags: [String] = [], answered: Bool = false) {
        self.text = text
        self.answer = answer
        self.questionSlides = questionSlides
        self.answerSlides = answerSlides
        self.tags = tags
        self.answered = answered
    }

    /// Identity is the question itself, so nothing invisible has to be written
    /// into a file you read in a text editor.
    var id: String { text.lowercased() }

    /// Question slides are not an answer. A slide you attached to the front is
    /// part of the asking, and promoting on the strength of one would make a
    /// card with a blank back.
    var hasAnswer: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !answerSlides.isEmpty
    }

    func slides(_ row: ArmedRow) -> [Int] {
        row == .question ? questionSlides : answerSlides
    }
}

/// Reading and writing the question list, which lives in the lecture's Notes.md
/// under the topics.
///
/// Ordinary GitHub task-list checkboxes, so the file renders real tick boxes in
/// VS Code and on GitHub and can be ticked there. The answer is a blockquote
/// under its question -- which is exactly what the caret in the panel folds, so
/// the app's disclosure and the file's structure are one idea rather than two
/// conventions to keep in step.
enum QuestionBlock {
    static let opener = "<!-- ankiflow:questions -->"
    static let closer = "<!-- /ankiflow:questions -->"
    static let heading = "## Lecture Questions"

    static func split(_ markdown: String) -> (questions: [LectureQuestion], body: String) {
        guard let start = markdown.range(of: opener),
              let end = markdown.range(of: closer,
                                       range: start.upperBound..<markdown.endIndex)
        else { return ([], markdown) }

        let inside = String(markdown[start.upperBound..<end.lowerBound])
        var body = markdown
        body.removeSubrange(start.lowerBound..<end.upperBound)
        return (parse(inside), body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func join(questions: [LectureQuestion], body: String) -> String {
        let prose = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questions.isEmpty else { return prose }

        var lines = [opener, "", heading, ""]
        for question in questions {
            lines.append("- [\(question.answered ? "x" : " ")] \(question.text)")
            for line in question.answer.components(separatedBy: .newlines) {
                lines.append(line.isEmpty ? "  >" : "  > \(line)")
            }
            // `Slides:` unqualified means the answer's, which is what it has
            // always meant -- so a notes file written before questions had a
            // front row still reads correctly.
            if !question.questionSlides.isEmpty {
                lines.append("  > Question slides: "
                             + question.questionSlides.map(String.init).joined(separator: ", "))
            }
            if !question.answerSlides.isEmpty {
                lines.append("  > Slides: "
                             + question.answerSlides.map(String.init).joined(separator: ", "))
            }
            if !question.tags.isEmpty {
                lines.append("  > Tags: " + question.tags.joined(separator: ", "))
            }
        }
        lines.append("")
        lines.append(closer)
        let block = lines.joined(separator: "\n")
        return prose.isEmpty ? block + "\n" : block + "\n\n" + prose + "\n"
    }

    /// Unanswered first, and stable within each half: the order you asked them
    /// in is information, so nothing is alphabetised and nothing moves unless
    /// you press the button.
    static func sorted(_ questions: [LectureQuestion]) -> [LectureQuestion] {
        questions.enumerated()
            .sorted {
                $0.element.answered == $1.element.answered
                    ? $0.offset < $1.offset
                    : !$0.element.answered
            }
            .map(\.element)
    }

    static func parse(_ block: String) -> [LectureQuestion] {
        var found: [LectureQuestion] = []
        var answerLines: [String] = []

        func flushAnswer() {
            guard !found.isEmpty else { answerLines = []; return }
            var text: [String] = []
            for line in answerLines {
                // Question slides first: "Question slides:" would otherwise fall
                // through to the answer row on a looser reading of the prefix.
                if let slides = slideList(in: line, front: true) {
                    found[found.count - 1].questionSlides = slides
                } else if let slides = slideList(in: line, front: false) {
                    found[found.count - 1].answerSlides = slides
                } else if let tags = tagList(in: line) {
                    found[found.count - 1].tags = tags
                } else {
                    text.append(line)
                }
            }
            while text.last?.isEmpty == true { text.removeLast() }
            found[found.count - 1].answer = text.joined(separator: "\n")
            answerLines = []
        }

        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let box = checkbox(in: line) {
                flushAnswer()
                let text = box.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty,
                      !found.contains(where: { $0.id == text.lowercased() }) else { continue }
                found.append(LectureQuestion(text: text, answered: box.ticked))
            } else if line.hasPrefix(">") {
                answerLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                // A bare line under a question is still that question's answer:
                // somebody typed it in another editor without the quote marker,
                // and losing what they wrote would be the worse reading. A bare
                // line before any question is a question with no checkbox.
                if found.isEmpty {
                    var stripped = line
                    for marker in ["- ", "* ", "+ "] where stripped.hasPrefix(marker) {
                        stripped = String(stripped.dropFirst(marker.count))
                        break
                    }
                    let text = stripped.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    found.append(LectureQuestion(text: text))
                } else {
                    answerLines.append(line)
                }
            }
        }
        flushAnswer()
        return found
    }

    static func blockIsCanonical(in markdown: String) -> Bool {
        guard let start = markdown.range(of: opener),
              let end = markdown.range(of: closer,
                                       range: start.upperBound..<markdown.endIndex)
        else { return true }
        let current = String(markdown[start.lowerBound..<end.upperBound])
        let wanted = join(questions: parse(String(markdown[start.upperBound..<end.lowerBound])),
                          body: "")
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
            == wanted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Line shapes

    private static func checkbox(in line: String) -> (ticked: Bool, text: String)? {
        var rest = line
        var isBullet = false
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            rest = String(rest.dropFirst(marker.count))
            isBullet = true
            break
        }
        guard isBullet, rest.count >= 3, rest.hasPrefix("[") else { return nil }
        let mark = rest[rest.index(rest.startIndex, offsetBy: 1)]
        guard rest[rest.index(rest.startIndex, offsetBy: 2)] == "]" else { return nil }
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", String(rest.dropFirst(3)))
    }

    /// `Tags: cardio, high-yield`. Spaces inside a tag become hyphens, because
    /// that is what Anki does with them and a tag that changes shape on export
    /// is a tag you cannot search for.
    private static func tagList(in line: String) -> [String]? {
        let lower = line.lowercased()
        guard lower.hasPrefix("tags:") || lower.hasPrefix("tag:") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var out: [String] = []
        for chunk in line[line.index(after: colon)...].components(separatedBy: ",") {
            let tag = TagDefinition.normalise(chunk)
            if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
        }
        return out.isEmpty ? nil : out
    }

    /// `Slides: 12, 14` or `Slide 12–14`, in any case, with ranges expanded.
    /// `front` reads the `Question slides:` row instead.
    private static func slideList(in line: String, front: Bool) -> [Int]? {
        var line = line
        let lower = line.lowercased()
        if front {
            var stem: String?
            for prefix in ["question slides", "question slide", "front slides", "front slide"]
            where lower.hasPrefix(prefix) {
                stem = String(line.dropFirst(prefix.count))
                break
            }
            guard let stem else { return nil }
            // Put a marker back so the shared tail below has something to cut
            // at, whether the file wrote a colon or just a space.
            line = "Slides" + stem
        } else {
            guard lower.hasPrefix("slides:") || lower.hasPrefix("slide:")
                    || lower.hasPrefix("slides ") || lower.hasPrefix("slide ") else { return nil }
        }
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == " " }) else { return nil }
        let tail = String(line[line.index(after: colon)...])

        var pages: [Int] = []
        for chunk in tail.components(separatedBy: ",") {
            let piece = chunk.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let bounds = piece.components(separatedBy: CharacterSet(charactersIn: "-–—"))
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 500 {
                pages.append(contentsOf: bounds[0]...bounds[1])
            } else if let single = Int(piece) {
                pages.append(single)
            }
        }
        guard !pages.isEmpty else { return nil }
        var seen = Set<Int>()
        return pages.filter { seen.insert($0).inserted }
    }
}
