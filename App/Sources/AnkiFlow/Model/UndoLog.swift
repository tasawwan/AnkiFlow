import Foundation

/// The undo history for a whole library, for as long as the app is running.
///
/// Library-wide rather than per lecture, so undo reaches back past a lecture
/// switch -- but **not** past quitting. It used to be written to
/// `.ankiflow/undo.json` and reloaded at launch, and that was the wrong call:
/// pressing Undo on a freshly opened app and having a change from three days
/// ago come back is a worse surprise than having nothing to undo. Every stack
/// in this app is now session-scoped, which makes one rule instead of four:
/// closing the app is a clean slate.
///
/// What that costs is the ability to take back a deletion you only notice the
/// next day, and the answer to that is not undo. Lectures are trashed to the
/// system Trash and come back from there; a question file is plain readable
/// JSON; and orphan recovery reunites a sidecar with its PDF. Undo is for the
/// mistake you notice while you are still working.
///
/// It is deliberately not in the sidecars either. A sidecar describes one
/// lecture's questions; the history of what you did to them is about the
/// session, and writing it there would rewrite every question file on every
/// keystroke-sized action.
@MainActor
final class UndoLog: ObservableObject {

    /// A file this app put in the Trash, and where it came from.
    struct TrashedFile: Codable {
        /// Absolute — the Trash is outside the library.
        var inTrash: String
        var original: String
    }

    struct Step: Codable, Identifiable {
        var id = UUID()
        /// What was done, phrased to follow "Undo".
        var label: String
        /// The lecture, relative to the library root, so the log survives the
        /// whole library being moved.
        var lecture: String
        /// The questions as they were *before* the change.
        var before: [Question]
        /// And after, so redo has something to put back.
        var after: [Question]
        /// Set instead of the question snapshots when the step moved files to
        /// the Trash. Undo puts them back where they were.
        var trashed: [TrashedFile]?
        var at: Date = Date()
    }

    @Published private(set) var undoStack: [Step] = []
    @Published private(set) var redoStack: [Step] = []

    /// Enough to cover a working session without the file becoming a burden.
    private let depth = 40
    private let root: URL

    init(libraryRoot: URL) {
        self.root = libraryRoot
    }

    // MARK: - Recording

    func record(label: String, lecture: URL, before: [Question], after: [Question]) {
        guard before != after else { return }
        undoStack.append(Step(label: label,
                              lecture: relative(lecture),
                              before: before,
                              after: after))
        if undoStack.count > depth { undoStack.removeFirst() }
        // A new action ends the redo branch, the same as every other editor.
        redoStack.removeAll()
    }

    /// Records a trashing, which has no question snapshot to speak of.
    func recordTrash(label: String, files: [TrashedFile]) {
        guard !files.isEmpty else { return }
        undoStack.append(Step(label: label, lecture: "", before: [], after: [], trashed: files))
        if undoStack.count > depth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Redoing a trashing puts the files somewhere new, so the step has to learn
    /// the new Trash paths or a second undo would look for files that moved.
    func updateLatestTrash(_ files: [TrashedFile]) {
        guard let index = undoStack.indices.last else { return }
        undoStack[index].trashed = files
    }

    // MARK: - Moving through it

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// Returns the step and the lecture it applies to; the caller does the work,
    /// because only it knows how to open a lecture and swap its questions.
    func popUndo() -> (step: Step, lecture: URL)? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step)
        if redoStack.count > depth { redoStack.removeFirst() }
        return (step, absolute(step.lecture))
    }

    func popRedo() -> (step: Step, lecture: URL)? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        return (step, absolute(step.lecture))
    }

    // MARK: - Paths

    private func relative(_ url: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count,
              Array(parts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }

    private func absolute(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// A lecture that was renamed under us takes its history with it.
    func relocate(from old: URL, to new: URL) {
        let oldPath = relative(old)
        let newPath = relative(new)
        for index in undoStack.indices where undoStack[index].lecture == oldPath {
            undoStack[index].lecture = newPath
        }
        for index in redoStack.indices where redoStack[index].lecture == oldPath {
            redoStack[index].lecture = newPath
        }
    }

    // MARK: - Disk
}
