import Foundation

/// The undo history for a whole library, kept in `.ankiflow/undo.json`.
///
/// Library-wide rather than per lecture, and on disk rather than in memory:
/// undo should reach back past a lecture switch and past quitting the app,
/// because "I closed it and lost my undo" is the same class of surprise as
/// having no undo at all.
///
/// It is deliberately not in the sidecars. A sidecar describes one lecture's
/// questions; the history of what you did to them is about the session, not the
/// lecture, and writing it there would rewrite every question file on every
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
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(libraryRoot: URL) {
        self.root = libraryRoot
        self.fileURL = LibraryPaths.dotDirectory(inLibrary: libraryRoot)
            .appendingPathComponent("undo.json")
        load()
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
        scheduleSave()
    }

    /// Records a trashing, which has no question snapshot to speak of.
    func recordTrash(label: String, files: [TrashedFile]) {
        guard !files.isEmpty else { return }
        undoStack.append(Step(label: label, lecture: "", before: [], after: [], trashed: files))
        if undoStack.count > depth { undoStack.removeFirst() }
        redoStack.removeAll()
        scheduleSave()
    }

    /// Redoing a trashing puts the files somewhere new, so the step has to learn
    /// the new Trash paths or a second undo would look for files that moved.
    func updateLatestTrash(_ files: [TrashedFile]) {
        guard let index = undoStack.indices.last else { return }
        undoStack[index].trashed = files
        scheduleSave()
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
        scheduleSave()
        return (step, absolute(step.lecture))
    }

    func popRedo() -> (step: Step, lecture: URL)? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        scheduleSave()
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
        scheduleSave()
    }

    // MARK: - Disk

    private struct File: Codable {
        var undo: [Step]
        var redo: [Step]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return }
        undoStack = file.undo
        redoStack = file.redo
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(undo: undoStack, redo: redoStack)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
