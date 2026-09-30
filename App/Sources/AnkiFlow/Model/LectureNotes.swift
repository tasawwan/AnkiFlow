import Foundation
import AppKit
import Combine

/// The big-picture notes for one lecture, held as styled text and written to a
/// Markdown file beside the PDF.
///
/// Separate from `LectureDocument` on purpose. Questions and notes have nothing
/// to do with each other: one is exported to Anki and has a merge contract to
/// honour, the other is prose you keep for yourself. Keeping them apart means a
/// note can never make a question file unreadable, and the note file can be
/// deleted, edited elsewhere, or synced by something else without this app
/// caring.
@MainActor
final class LectureNotes: ObservableObject {
    let pdfURL: URL
    let fileURL: URL

    /// The note as the editor holds it. Set by the editor, read by the renderer.
    ///
    /// The prose only. The topic list shares this file but is never part of
    /// this text: it is split off on the way in and written back on the way
    /// out, so the editor shows you what you wrote and nothing else.
    @Published var text: NSAttributedString
    /// What this lecture is trying to teach you, and how well you know each of
    /// them. Held here rather than in the question sidecar because it belongs
    /// with the notes and is meant to be read in the Markdown file itself.
    @Published private(set) var topics: [Topic] = []
    /// The questions the lecture left you with. Same file, second block, under
    /// the topics.
    @Published private(set) var questions: [LectureQuestion] = []
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var loadError: String?
    /// Bumped when the file changed underneath us and `text` was replaced, so
    /// the editor knows to take the new contents. It cannot watch `text` for
    /// that -- `text` also changes on every keystroke, and reloading the view
    /// then would reset the caret with each character typed.
    @Published private(set) var reloadToken = 0
    /// What just happened to the file, for the pane to say out loud. Cleared
    /// when you next type.
    @Published var externalChange: String?

    private var saveTask: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private let textColour: NSColor
    private static let saveDebounce: TimeInterval = 1.2
    /// What was last written, so an autosave that would change nothing doesn't
    /// touch the file's modification date.
    private var lastWritten: String

    /// What this lecture is called: the PDF's own name, and the note's first
    /// line. The one thing about a lecture's notes nobody should have to type.
    var title: String { Self.title(of: pdfURL) }

    static func title(of pdfURL: URL) -> String {
        pdfURL.lectureName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the only thing here is the title this app put there.
    ///
    /// A title nobody typed is not a note. The distinction matters because an
    /// automatic first line would otherwise count as content, and opening a
    /// lecture would leave a `.md` beside every PDF you so much as looked at.
    var isEmpty: Bool {
        let written = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return written.isEmpty || written == title
    }

    /// The body with the lecture's name on top.
    ///
    /// Only when nothing already heads it. A first line of your own is yours --
    /// a note that already opens with a title is already titled, whatever it
    /// says, and a second one above it would be this app writing in your file.
    private static func titled(_ body: String, with title: String) -> String {
        guard !title.isEmpty else { return body }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.hasPrefix("# ") else { return body }
        let rest = body.drop(while: { $0 == "\n" })
        return "# " + title + "\n\n" + rest
    }

    /// The same body with that automatic title taken back off, for asking
    /// whether anything has actually been written. Removes the heading only
    /// when it is word for word the one `titled` would have added.
    private static func untitled(_ body: String, with title: String) -> String {
        guard !title.isEmpty else { return body }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), lines[index].trimmingCharacters(in: .whitespaces) == "# " + title else { return body }
        return lines[(index + 1)...].joined(separator: "\n")
    }

    init(pdfURL: URL, textColour: NSColor) {
        self.pdfURL = pdfURL
        self.fileURL = AnkiIdentity.notesURL(for: pdfURL)
        self.textColour = textColour

        var markdown = ""
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                markdown = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                // Never silently start from empty: that looks like the notes
                // were fine and then get overwritten by the next autosave.
                self.loadError = "Could not read \(fileURL.finderName): \(error.localizedDescription)"
            }
        }
        self.lastWritten = markdown
        var parts = Self.pull(from: markdown)
        // Questions written in the old pane become part of the notes.
        //
        // The pane is gone, and a block nothing shows is work you cannot get
        // at. Folding them into the prose puts them where you would look for
        // them and leaves them as ordinary Markdown -- editable here, readable
        // in any text editor, and no longer a private format.
        if !parts.questions.isEmpty {
            parts.body = Self.fold(questions: parts.questions, into: parts.body)
            parts.questions = []
            needsMigrationSave = true
        }
        self.topics = parts.topics
        self.questions = parts.questions
        // Deliberately not saved. The title appears in the pane the moment the
        // lecture opens, but it reaches the file only when you write something
        // -- opening a lecture is not editing it.
        self.text = RichTextMarkdown.attributedString(
            from: Self.titled(parts.body, with: Self.title(of: pdfURL)),
            textColour: textColour)
        startWatching()
        if needsMigrationSave {
            needsMigrationSave = false
            saveNow()
        } else {
            tidyBlocks(against: markdown)
        }
    }

    private var needsMigrationSave = false

    /// Old lecture questions, written out as a section of the notes.
    ///
    /// One heading, one bullet each, the answer after an em dash and the slides
    /// in brackets -- the shape they were already in on screen, so a lecture you
    /// open after this reads the way it did before, just in the notes rather
    /// than in a pane of its own.
    static func fold(questions: [LectureQuestion], into body: String) -> String {
        let lines = questions.map { question -> String in
            var line = question.answered ? "- [x] " : "- [ ] "
            line += question.text
            let answer = question.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                line += " — " + answer.replacingOccurrences(of: "\n", with: " ")
            }
            let slides = (question.questionSlides + question.answerSlides).sorted()
            if !slides.isEmpty {
                line += " (slide\(slides.count == 1 ? "" : "s") "
                    + slides.map(String.init).joined(separator: ", ") + ")"
            }
            return line
        }
        let section = (["## Lecture questions", ""] + lines).joined(separator: "\n")
        let prose = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return prose.isEmpty ? section : prose + "\n\n" + section
    }

    deinit { watcher?.cancel() }

    // MARK: - Following the file

    /// Notes are a plain file in a folder you own, so the folder is the truth.
    /// Delete the file in Finder and the pane empties; edit it in another app
    /// and the pane picks the change up. The same two-second poll the library
    /// uses, for the same reason: it is cheap enough to run forever and needs no
    /// file-system events to arrive in the right order.
    private func startWatching() {
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.reconcileWithDisk()
            }
        }
    }

    private func reconcileWithDisk() {
        // Never while a save is pending: what is on disk is about to be replaced
        // by what is on screen, and reading it now would fight the typing.
        guard loadError == nil, saveTask == nil else { return }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            guard !lastWritten.isEmpty else { return }
            // The file was deleted from under us. Emptying the pane to match is
            // the honest reading -- deleting a note means you do not want it --
            // and it is said out loud rather than done silently, because the
            // words are gone and you should know it was the deletion that did
            // it.
            lastWritten = ""
            topics = []
            questions = []
            text = RichTextMarkdown.attributedString(from: Self.titled("", with: title),
                                                     textColour: textColour)
            reloadToken += 1
            externalChange = "\(fileURL.finderName) was deleted, so these notes were cleared."
            return
        }

        guard let onDisk = try? String(contentsOf: fileURL, encoding: .utf8),
              onDisk != lastWritten else { return }
        lastWritten = onDisk
        var parts = Self.pull(from: onDisk)
        if !parts.questions.isEmpty {
            parts.body = Self.fold(questions: parts.questions, into: parts.body)
            parts.questions = []
        }
        topics = parts.topics
        questions = parts.questions
        text = RichTextMarkdown.attributedString(from: Self.titled(parts.body, with: title),
                                                 textColour: textColour)
        reloadToken += 1
        externalChange = "Reloaded — \(fileURL.finderName) changed on disk."
        tidyBlocks(against: onDisk)
    }

    /// Swap the styled text without a keystroke having caused it -- used when
    /// the display size changes and the note is re-rendered at new point sizes.
    /// The token is what makes the editor take it: `text` alone changes on every
    /// character typed, so the editor cannot watch that.
    /// Put both lists back to a remembered state. Used by undo, which owns the
    /// history rather than this object -- an edit made from the library scope
    /// happens while this lecture is not even open.
    func replaceLists(topics: [Topic], questions: [LectureQuestion]) {
        self.topics = topics
        self.questions = questions
        scheduleSave()
    }

    func replaceText(_ replacement: NSAttributedString) {
        text = replacement
        reloadToken += 1
    }

    // MARK: - Saving

    func scheduleSave(clearingNotice: Bool = true) {
        guard loadError == nil else { return }
        // A tidy-up the app decided on is not you typing, so it must not wipe
        // the notice saying the file changed underneath you.
        if clearingNotice { externalChange = nil }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard loadError == nil else { return }
        saveTask?.cancel()
        saveTask = nil

        // The same rule the question file keeps: never create a note beside a
        // lecture that has gone. A rename carries the note with it, and the
        // outgoing editor would otherwise write a second one back at the old
        // name. An existing note is still saved, so nothing you typed is lost
        // when it is the PDF that moved out from under you.
        guard FileManager.default.fileExists(atPath: pdfURL.path)
                || FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let body = RichTextMarkdown.markdown(from: text)
        let markdown = assemble(body)
        guard markdown != lastWritten else { return }

        // An emptied note removes its file rather than leaving a blank one
        // behind. A stray empty .md beside every PDF is clutter, and an empty
        // file is indistinguishable from notes you have lost.
        //
        // "Empty" is measured with the automatic title taken off, so a lecture
        // you opened and did not write in has nothing beside it -- and a note
        // you clear back down to its title removes itself, the same as one you
        // clear to nothing.
        let substance = assemble(Self.untitled(body, with: title))
        if substance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only stamped when there was something to remove. A lecture you
            // opened and did not write in has never been saved, and saying it
            // was would be the pane reporting work nobody did.
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            if existed {
                try? FileManager.default.removeItem(at: fileURL)
                lastSavedAt = Date()
            }
            // Left empty so the watcher, seeing no file a moment later, knows
            // this app removed it and stays quiet -- rather than announcing a
            // deletion you performed yourself by clearing the text.
            lastWritten = ""
            return
        }
        do {
            try AtomicWrite.write(Data(markdown.utf8), to: fileURL, hidden: false)
            lastWritten = markdown
            lastSavedAt = Date()
        } catch {
            loadError = "Could not save \(fileURL.finderName): \(error.localizedDescription)"
        }
    }

    /// The Markdown as it stands, for the reading pane.
    var markdown: String { assemble(RichTextMarkdown.markdown(from: text)) }

    /// The two blocks compose: topics first, then questions, then the prose.
    /// `join` with an empty list returns its body untouched, so a file with no
    /// topics and no questions is just the notes.
    private func assemble(_ body: String) -> String {
        TopicBlock.join(topics: topics,
                        body: QuestionBlock.join(questions: questions, body: body))
    }

    private static func pull(from markdown: String)
        -> (topics: [Topic], questions: [LectureQuestion], body: String) {
        let first = TopicBlock.split(markdown)
        let second = QuestionBlock.split(first.body)
        return (first.topics, second.questions, second.body)
    }

    // MARK: - Topics

    /// A topic list typed by hand is in whatever shape it was typed: lines with
    /// no rating, in no order. Showing it tidied on screen while leaving the file
    /// ragged would defeat the reason the list lives in the Markdown at all, so
    /// the file is put back into canonical form -- everything rated, sorted
    /// weakest-first, then alphabetically within a rung.
    ///
    /// Debounced rather than written on the spot, so a burst of edits in another
    /// editor settles before this app answers. Only when there are topics: a
    /// notes file with no block would otherwise be rewritten every time it was
    /// opened, purely to trim its whitespace.
    private func tidyBlocks(against onDisk: String) {
        let topicsRagged = !topics.isEmpty && !TopicBlock.blockIsCanonical(in: onDisk)
        let questionsRagged = !questions.isEmpty && !QuestionBlock.blockIsCanonical(in: onDisk)
        guard topicsRagged || questionsRagged else { return }
        scheduleSave(clearingNotice: false)
    }

    /// New topics go on the end rather than into sorted position, and rating one
    /// does not move it either. The file is written sorted -- that is what the
    /// sorting is for, being readable in the Markdown -- but a row that jumps
    /// out from under the cursor between the first and second click of a rating
    /// makes the panel unusable. The order settles the next time the lecture is
    /// opened.
    func addTopic(_ name: String, type: String = TopicType.fallback) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !topics.contains(where: { $0.id == cleaned.lowercased() }) else { return }
        topics.append(Topic(name: cleaned, comfort: .low, type: type))
        scheduleSave()
    }

    /// Moves one topic to another section. Its name and rating come with it --
    /// this is a re-filing, not a new topic.
    func moveTopic(_ topic: Topic, to type: String) {
        guard let index = topics.firstIndex(where: { $0.id == topic.id }),
              topics[index].type.caseInsensitiveCompare(type) != .orderedSame else { return }
        topics[index].type = type
        scheduleSave()
    }

    /// Empties a section into another. The quick way to clear a type you have
    /// switched off.
    func moveTopics(from source: String, to destination: String) {
        guard source.caseInsensitiveCompare(destination) != .orderedSame else { return }
        var moved = false
        for index in topics.indices
        where topics[index].type.caseInsensitiveCompare(source) == .orderedSame {
            topics[index].type = destination
            moved = true
        }
        if moved { scheduleSave() }
    }

    func cycleComfort(of topic: Topic) {
        guard let index = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        topics[index].comfort = topics[index].comfort.next
        scheduleSave()
    }

    /// Keeps the rating and the row's place. Refuses a name already in the
    /// list, for the same reason the file parser refuses a duplicate: one topic,
    /// one row, one rating.
    @discardableResult
    func renameTopic(_ topic: Topic, to name: String) -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != topic.name,
              let index = topics.firstIndex(where: { $0.id == topic.id }),
              !topics.contains(where: { $0.id == cleaned.lowercased() && $0.id != topic.id })
        else { return false }
        topics[index].name = cleaned
        scheduleSave()
        return true
    }

    /// Put the list back in order, on demand.
    ///
    /// No save: the file is written sorted every time regardless, so this only
    /// catches the panel up with what is already on disk.
    func resortTopics() {
        topics = TopicBlock.sorted(topics)
    }

    // MARK: - Lecture questions

    func addQuestion(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !questions.contains(where: { $0.id == cleaned.lowercased() }) else { return }
        questions.append(LectureQuestion(text: cleaned))
        scheduleSave()
    }

    func toggleAnswered(_ question: LectureQuestion) {
        edit(question) { $0.answered.toggle() }
    }

    func setAnswer(_ answer: String, for question: LectureQuestion) {
        edit(question) { $0.answer = answer }
    }

    /// ⌘E and ⌘R hand over a whole run at once.
    func setSlides(_ pages: [Int], row: ArmedRow, for question: LectureQuestion) {
        let normalised = PageSet.normalise(pages)
        edit(question) {
            if row == .question { $0.questionSlides = normalised } else { $0.answerSlides = normalised }
        }
    }

    func attachSlide(_ page: Int, row: ArmedRow, to question: LectureQuestion) {
        edit(question) {
            if row == .question {
                guard !$0.questionSlides.contains(page) else { return }
                $0.questionSlides = ($0.questionSlides + [page]).sorted()
            } else {
                guard !$0.answerSlides.contains(page) else { return }
                $0.answerSlides = ($0.answerSlides + [page]).sorted()
            }
        }
    }

    func detachSlide(_ page: Int, row: ArmedRow, from question: LectureQuestion) {
        edit(question) {
            if row == .question {
                $0.questionSlides.removeAll { $0 == page }
            } else {
                $0.answerSlides.removeAll { $0 == page }
            }
        }
    }

    func setYield(_ yield: String?, on question: LectureQuestion) {
        edit(question) {
            $0.tags.removeAll(where: TagDefinition.isYield)
            if let yield { $0.tags.append(yield) }
        }
    }

    /// Tags on a draft card work exactly as they do on a real one, and travel
    /// with it when it is promoted.
    func toggleTag(_ tag: String, on question: LectureQuestion) {
        edit(question) {
            if let index = $0.tags.firstIndex(of: tag) {
                $0.tags.remove(at: index)
            } else {
                $0.tags.append(tag)
            }
        }
    }

    @discardableResult
    func renameQuestion(_ question: LectureQuestion, to text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != question.text,
              !questions.contains(where: { $0.id == cleaned.lowercased() && $0.id != question.id })
        else { return false }
        edit(question) { $0.text = cleaned }
        return true
    }

    func removeQuestion(_ question: LectureQuestion) {
        guard questions.contains(where: { $0.id == question.id }) else { return }
        questions.removeAll { $0.id == question.id }
        scheduleSave()
    }

    func removeQuestions(_ doomed: [LectureQuestion]) {
        let ids = Set(doomed.map(\.id))
        guard !ids.isEmpty else { return }
        questions.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Unanswered to the top, on demand -- never as a side effect of ticking one.
    func resortQuestions() {
        questions = QuestionBlock.sorted(questions)
        scheduleSave()
    }

    private func edit(_ question: LectureQuestion, _ change: (inout LectureQuestion) -> Void) {
        guard let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
        change(&questions[index])
        scheduleSave()
    }

    func removeTopic(_ topic: Topic) {
        guard topics.contains(where: { $0.id == topic.id }) else { return }
        topics.removeAll { $0.id == topic.id }
        scheduleSave()
    }
}
