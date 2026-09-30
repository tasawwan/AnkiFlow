import Foundation

/// Undo for the two structured lists that live in a lecture's notes file.
///
/// **One ledger for both, not one each.** Topics and lecture questions are edited
/// from opposite ends of the window, and a ledger per panel would mean ⌘Z's
/// meaning depended on which of them the app thought was focused -- which is
/// precisely the unpredictability that argues against a single global ledger in
/// the first place. They are one domain: lines in one file, changed by clicking
/// rows. One ledger over both gives "take back the last row I changed", which is
/// what anyone pressing ⌘Z in either panel means.
///
/// It is **not** merged with the question log or the markup stack. Those are
/// different kinds of act on different artefacts, and mixing them is how ⌘Z
/// stops being safe to press.
///
/// Steps are whole snapshots of both lists rather than closures, because a step
/// has to survive the lecture being closed and reopened, and because the file
/// can be edited in another app between doing a thing and undoing it -- which
/// `after` is checked against before anything is written back.
struct NotesLists: Equatable {
    var topics: [Topic]
    var questions: [LectureQuestion]
}

struct NotesUndoStep {
    let label: String
    /// The lecture, by its PDF. The library scope can change topics in a lecture
    /// that is not open, so a step cannot assume it applies to the open one.
    let pdfURL: URL
    let before: NotesLists
    let after: NotesLists
    /// Cards this step created, if it was a promotion. Undo takes them back out,
    /// so moving a question into your cards is one action and one ⌘Z rather than
    /// two halves that can be undone apart from each other.
    let addedQIDs: [String]
}

/// In memory, for this run of the app only.
///
/// Unlike the question log this is deliberately not persisted. The notes file is
/// plain text anyone can edit in any editor between one launch and the next, and
/// replaying a stale step onto a file that has moved on is worse than having
/// nothing to replay.
@MainActor
final class NotesUndoLog {
    private(set) var undoStack: [NotesUndoStep] = []
    private(set) var redoStack: [NotesUndoStep] = []
    private let limit = 40

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func record(_ step: NotesUndoStep) {
        undoStack.append(step)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    func popUndo() -> NotesUndoStep? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step)
        return step
    }

    func popRedo() -> NotesUndoStep? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        return step
    }

    /// A lecture whose file was renamed or trashed takes its history with it,
    /// rather than leaving steps pointing at a path that is no longer there.
    func forget(_ pdfURL: URL) {
        undoStack.removeAll { $0.pdfURL == pdfURL }
        redoStack.removeAll { $0.pdfURL == pdfURL }
    }
}

/// Reading and writing both blocks of a notes file that is not currently open.
///
/// The open lecture always goes through its `LectureNotes`, which owns the file
/// and is watching it; this is for everything the library scope and the undo
/// ledger reach into from outside.
enum NotesFile {
    static func lists(forPDF pdfURL: URL) -> NotesLists {
        let text = (try? String(contentsOf: AnkiIdentity.notesURL(for: pdfURL),
                                encoding: .utf8)) ?? ""
        let topics = TopicBlock.split(text)
        let questions = QuestionBlock.split(topics.body)
        return NotesLists(topics: topics.topics, questions: questions.questions)
    }

    static func write(_ lists: NotesLists, forPDF pdfURL: URL) throws {
        let url = AnkiIdentity.notesURL(for: pdfURL)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let body = QuestionBlock.split(TopicBlock.split(existing).body).body
        let markdown = TopicBlock.join(
            topics: lists.topics,
            body: QuestionBlock.join(questions: lists.questions, body: body))
        // The same rule as everywhere else: nothing left means no file.
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try AtomicWrite.write(Data(markdown.utf8), to: url, hidden: false)
    }
}
