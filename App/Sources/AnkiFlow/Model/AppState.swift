import Foundation
import SwiftUI
import AppKit
import PDFKit
import Combine

/// Which card type the right panel is showing. One type per window -- never a
/// Basic question and a Slide2Slide in the same list.
enum PanelType: Hashable {
    case basic
    case slide2slide
    case occlusion
    case template(String)

    var kind: QuestionKind {
        switch self {
        case .basic:       return .basic
        case .slide2slide: return .slide2slide
        case .occlusion:   return .occlusion
        case .template:    return .template
        }
    }

    var templateId: String? {
        if case .template(let id) = self { return id }
        return nil
    }

    func matches(_ question: Question) -> Bool {
        switch self {
        case .basic:              return question.kind == .basic
        case .slide2slide:        return question.kind == .slide2slide
        case .occlusion:          return question.kind == .occlusion
        case .template(let id):   return question.kind == .template && question.templateId == id
        }
    }
}

/// Which chip row ⌘E and ⌘D are arming, in Slide2Slide.
enum ArmedRow {
    case question
    case answer
}

@MainActor
final class AppState: ObservableObject {
    @Published var library: Library?
    @Published var document: LectureDocument?
    @Published var currentPage: Int = 1
    @Published var panelType: PanelType = .basic
    @Published var focusedQID: String?
    @Published var armedRow: ArmedRow = .answer
    @Published var anchorPage: Int = 1
    @Published var showSidebar = true
    @Published var showThumbnails = false
    @Published var showExportSheet = false
    @Published var editingTemplate: Template?
    @Published var statusMessage: String?
    @Published var revealBackField = false

    /// Editorial in light, Studio in dark, following macOS unless pinned.
    @Published var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    let templates = TemplateStore()

    // `var`, not `let`: the update alerts bind to `$state.updates.showResult`,
    // and SwiftUI's dynamic-member binding can only reach a property through a
    // *writable* key path. A `let` makes the key path read-only and the binding
    // fails to compile.
    var updates = UpdateChecker()
    var sourceUpdate = SourceUpdater()

    /// `LectureDocument` and `Library` publish their own changes. Views observe
    /// AppState, so without these AppState never re-renders when a question or
    /// a setting changes -- the tag really did get written, the checkbox just
    /// never redrew. Forwarding makes every observer of AppState see them.
    private var documentObserver: AnyCancellable?
    private var libraryObserver: AnyCancellable?
    private var templatesObserver: AnyCancellable?
    private var updatesObserver: AnyCancellable?
    private var sourceUpdateObserver: AnyCancellable?

    init() {
        templatesObserver = templates.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Without these two the alerts never appear: flipping `showResult` on
        // the checker publishes on the *checker*, and the menu-bar scene is
        // observing AppState.
        updatesObserver = updates.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sourceUpdateObserver = sourceUpdate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if let raw = UserDefaults.standard.string(forKey: "appearance"),
           let mode = AppearanceMode(rawValue: raw) {
            appearance = mode
        }
    }

    let pdfBox = PDFViewBox()

    // MARK: - Library and lectures

    func openLibrary(at url: URL) {
        document?.saveNow()
        let library = Library(root: url)
        self.library = library
        libraryObserver = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.document = nil
        self.focusedQID = nil
        UserDefaults.standard.set(url.path, forKey: "lastLibraryPath")
        undoLog = UndoLog(libraryRoot: url)
        dismissedOrphans = []
        startWatchingLibrary()
        if let first = library.allLectures().first { open(lecture: first) }
        offerRecoveryIfNeeded()
    }

    func restoreLastLibrary() {
        guard let path = UserDefaults.standard.string(forKey: "lastLibraryPath") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openLibrary(at: url)
    }

    // MARK: - Watching the library folder

    private var watcher: Task<Void, Never>?

    /// Notices lectures added, renamed or removed in Finder, so the sidebar is
    /// never out of date and there is nothing to press to refresh it.
    ///
    /// Polling rather than FSEvents: the signature is a hash of folder
    /// modification dates, which costs one directory walk and no file reads, and
    /// two seconds of latency on a change you made in another app is not
    /// something anyone notices.
    private func startWatchingLibrary() {
        watcher?.cancel()
        guard let library else { return }
        var signature = library.contentsSignature()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, let library = self.library else { return }
                let current = library.contentsSignature()
                guard current != signature else { continue }
                signature = current
                library.rescan()
                self.offerRecoveryIfNeeded()
            }
        }
    }

    func closeLecture() {
        document?.saveNow()
        document = nil
        focusedQID = nil
    }

    func open(lecture url: URL) {
        document?.saveNow()
        let opened = LectureDocument(pdfURL: url, libraryRoot: library?.root)
        opened.hideFile = library?.settings.hideSidecarFiles ?? true
        document = opened
        documentObserver = opened.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // A shift is not something to leave in a banner and hope for: open it.
        if opened.pendingShift != nil { showPageShift = true }
        currentPage = 1
        anchorPage = 1
        focusedQID = nil
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    // MARK: - Paging

    func goToPage(_ page: Int) {
        guard pageCount > 0 else { return }
        currentPage = min(max(1, page), pageCount)
    }

    func nextPage() {
        goToPage(currentPage + 1)
    }

    func previousPage() {
        goToPage(currentPage - 1)
    }

    // MARK: - Questions

    var visibleQuestions: [Question] {
        // Insertion order, deliberately. Nothing re-sorts behind you.
        (document?.questions ?? []).filter { panelType.matches($0) }
    }

    var focusedQuestion: Question? {
        document?.question(qid: focusedQID)
    }

    @discardableResult
    func newQuestion() -> Question? {
        guard let document else { return nil }
        snapshot("adding that question")
        var question = Question(
            kind: panelType.kind,
            templateId: panelType.templateId,
            seedPage: panelType.kind == .slide2slide ? nil : currentPage
        )
        if panelType.kind == .slide2slide {
            question.questionPages = [currentPage]
            armedRow = .question
        } else {
            armedRow = .answer
        }
        if let template = templates.template(id: panelType.templateId),
           template.slides == .front {
            // A front-slides template wants the seeded page on the question row,
            // and that row armed, or the first ⌘E goes to the wrong side.
            question.questionPages = question.answerPages
            question.answerPages = []
            armedRow = .question
        }
        if let template = templates.template(id: panelType.templateId) {
            for blank in template.blanks where question.blanks[blank.key] == nil {
                question.blanks[blank.key] = ""
            }
        }
        document.add(question)
        commitSnapshot()
        focusedQID = question.qid
        anchorPage = currentPage
        return question
    }

    /// ⌘⏎ -- finish this question and fold the card shut. It does *not* open a
    /// new one: ⌘N does that, and two keys that both made questions meant one of
    /// them made one you hadn't asked for.
    func commitAndAdvance() {
        guard let document, let current = focusedQuestion else { return }
        if current.isEmpty {
            // Nothing in it, so there is nothing to commit and no reason to
            // leave an empty card behind.
            document.delete(qid: current.qid)
            focusedQID = document.questions.last(where: { panelType.matches($0) })?.qid
            return
        }
        // The autosave debounce means a keystroke half a second ago may not be
        // in `questions` yet, and saving before it lands would write the older
        // text. The signal makes the focused field commit its binding first.
        commitSignal += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.document?.saveNow()
            // Collapse it. The card folding shut is the "done" -- clearer than
            // any message, and it puts the list back in front of you.
            self.focusedQID = nil
        }
    }

    /// Bumped by ⌘⏎. The focused question card watches it, pushes its text into
    /// the model and gives up keyboard focus — which is also what makes ⌘⏎ look
    /// like it did something in an app that has no unsaved state to show you.
    @Published private(set) var commitSignal = 0

    func deleteFocusedQuestion() {
        guard let document, let qid = focusedQID else { return }
        snapshot("deleting that question")
        document.delete(qid: qid)
        commitSnapshot()
        focusedQID = document.questions.last(where: { panelType.matches($0) })?.qid
    }

    /// Applies the hidden flag to every existing sidecar, so flipping the
    /// setting takes effect on files that are already there.
    func applySidecarVisibility() {
        guard let library else { return }
        let hidden = library.settings.hideSidecarFiles
        document?.hideFile = hidden
        for pdfURL in library.allLectures() {
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            AtomicWrite.setHidden(hidden, at: sidecar)
        }
    }

    // MARK: - Export history

    /// Forgets everything the app remembers about past exports, and returns how
    /// many questions were reset.
    ///
    /// Everything is per lecture — there is no central file. Each lecture's
    /// question file loses its tombstones and its last-exported deck name (so
    /// deleted-question and moved-lecture reports start clean), and every
    /// question loses its `export` record — content hash and last stamped `mod`
    /// — so the next export rewrites every note rather than only the changed
    /// ones.
    ///
    /// This does not touch Anki. Your cards, and their review history, are
    /// matched by GUID and are unaffected — the next export simply updates all
    /// of them instead of a few.
    @discardableResult
    func resetExportHistory(scope: ResetScope) -> Int {
        guard let library else { return 0 }
        let targets = lectures(in: scope, library: library)
        guard !targets.isEmpty else { return 0 }
        var cleared = 0

        if let document, targets.contains(document.pdfURL) {
            cleared += document.questions.filter {
                $0.export != nil || !$0.childExports.isEmpty
            }.count
            document.forgetExportHistory()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        for pdfURL in targets where pdfURL != document?.pdfURL {
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            guard let data = try? Data(contentsOf: sidecar),
                  var file = try? decoder.decode(SidecarFile.self, from: data) else { continue }
            var touched = !(file.retiredQIDs ?? []).isEmpty || file.lastExportedDeckName != nil
            for index in file.questions.indices
            where file.questions[index].export != nil || !file.questions[index].childExports.isEmpty {
                file.questions[index].export = nil
                file.questions[index].childExports = [:]
                cleared += 1
                touched = true
            }
            file.retiredQIDs = nil
            file.lastExportedDeckName = nil
            if touched, let out = try? encoder.encode(file) {
                try? AtomicWrite.write(out, to: sidecar,
                                       hidden: library.settings.hideSidecarFiles)
            }
        }
        return cleared
    }

    /// Which lectures a reset applies to.
    func lectures(in scope: ResetScope, library: Library) -> [URL] {
        switch scope {
        case .lecture:
            return document.map { [$0.pdfURL] } ?? []
        case .folder:
            guard let folder = document?.pdfURL.deletingLastPathComponent() else { return [] }
            return library.allLectures().filter { $0.deletingLastPathComponent() == folder }
        case .library:
            return library.allLectures()
        }
    }

    /// Drops the tombstones for the given lectures, on disk as well as in the
    /// open document. Called once Anki has confirmed the deletions.
    func clearRetired(in lectures: [URL]) {
        guard let library else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        for pdfURL in lectures {
            if let document, document.pdfURL == pdfURL {
                document.clearRetired()
                continue
            }
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            guard let data = try? Data(contentsOf: sidecar),
                  var file = try? decoder.decode(SidecarFile.self, from: data),
                  !(file.retiredQIDs ?? []).isEmpty else { continue }
            file.retiredQIDs = nil
            if let out = try? encoder.encode(file) {
                try? AtomicWrite.write(out, to: sidecar,
                                       hidden: library.settings.hideSidecarFiles)
            }
        }
    }

    // MARK: - Templates

    /// Deleting a template converts every question built from it into a plain
    /// Basic question, keeping the text the template had rendered.
    ///
    /// Templates are a typing aid, not a card format — everything compiles down
    /// to the same Anki note type either way — so nothing is lost. Runs across
    /// the whole library, not just the open lecture, because templates are
    /// shared across courses.
    func deleteTemplate(_ template: Template) -> Int {
        var converted = 0

        if let document {
            var questions = document.questions
            for index in questions.indices where questions[index].templateId == template.id {
                convert(&questions[index], using: template)
                converted += 1
            }
            if converted > 0 { document.questions = questions; document.saveNow() }
        }

        if let library {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601

            for pdfURL in library.allLectures() where pdfURL != document?.pdfURL {
                let sidecar = pdfURL.deletingPathExtension()
                    .appendingPathExtension(AnkiIdentity.sidecarExtension)
                guard let data = try? Data(contentsOf: sidecar),
                      var file = try? decoder.decode(SidecarFile.self, from: data) else { continue }
                var touched = false
                for index in file.questions.indices where file.questions[index].templateId == template.id {
                    convert(&file.questions[index], using: template)
                    converted += 1
                    touched = true
                }
                if touched, let out = try? encoder.encode(file) {
                    try? AtomicWrite.write(out, to: sidecar,
                                   hidden: library.settings.hideSidecarFiles)
                }
            }
        }

        templates.delete(template)
        if panelType == .template(template.id) { panelType = .basic }
        return converted
    }

    private func convert(_ question: inout Question, using template: Template) {
        let rendered = template.render(blanks: question.blanks)
        question.kind = .basic
        question.templateId = nil
        question.front = rendered.front.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.back.isEmpty {
            question.back = rendered.back.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        question.blanks = [:]
        question.updatedAt = Date()
    }

    // MARK: - The attachment gestures

    private func mutateFocused(_ change: (inout Question) -> Void) {
        guard let document, var question = focusedQuestion else { return }
        change(&question)
        question.questionPages = PageSet.normalise(question.questionPages)
        question.answerPages = PageSet.normalise(question.answerPages)
        // Every page edit funnels through here, so this is the one place a crop
        // can be left behind pointing at a page the question no longer cites.
        question.pruneCrops()
        document.update(question)
        commitSnapshot()
    }

    /// ⌘E -- the range becomes anchor → wherever you have scrolled to.
    func extendToCurrentPage() {
        snapshot("the slide range")
        let pages = PageSet.extend(from: anchorPage, to: currentPage)
        mutateFocused { question in
            switch armedRow {
            case .question: question.questionPages = pages
            case .answer:   question.answerPages = pages
            }
        }
    }

    /// ⌘T -- add or remove just this page, for the non-contiguous stragglers.
    func toggleCurrentPage(force: Bool = false) {
        snapshot("that slide")
        let page = currentPage
        mutateFocused { question in
            switch armedRow {
            case .question:
                if question.questionPages.contains(page), !force {
                    question.questionPages.removeAll { $0 == page }
                } else {
                    question.questionPages.append(page)
                }
            case .answer:
                if question.answerPages.contains(page), !force {
                    question.answerPages.removeAll { $0 == page }
                } else {
                    question.answerPages.append(page)
                }
            }
        }
    }

    /// ⌘R -- start a new range here.
    func setAnchorToCurrentPage() {
        snapshot("re-anchoring")
        anchorPage = currentPage
        mutateFocused { question in
            switch armedRow {
            case .question: question.questionPages = [currentPage]
            case .answer:   question.answerPages = [currentPage]
            }
        }
    }

    // MARK: - Find

    @Published var findVisible = false
    @Published var findQuery = "" { didSet { runFind() } }
    @Published private(set) var findMatchCount = 0
    @Published private(set) var findIndex = 0
    private var findMatches: [PDFSelection] = []

    func openFind() {
        findVisible = true
    }

    func closeFind() {
        findVisible = false
        findMatches = []
        findMatchCount = 0
        findIndex = 0
        pdfBox.view.setCurrentSelection(nil, animate: false)
    }

    /// Searching is the document's job, not ours -- PDFKit already knows how to
    /// walk the text layer, and a slide deck's is small enough that doing it
    /// synchronously on every keystroke is imperceptible.
    private func runFind() {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = pdfBox.view.document, query.count >= 2 else {
            findMatches = []
            findMatchCount = 0
            findIndex = 0
            pdfBox.view.setCurrentSelection(nil, animate: false)
            return
        }
        findMatches = document.findString(query, withOptions: [.caseInsensitive])
        findMatchCount = findMatches.count
        findIndex = 0
        showFindMatch()
    }

    /// Wraps at both ends: a find that stops dead at the last hit reads as
    /// broken when the one you wanted was two slides back.
    func stepFind(_ step: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + step + findMatches.count) % findMatches.count
        showFindMatch()
    }

    private func showFindMatch() {
        guard findMatches.indices.contains(findIndex),
              let document = pdfBox.view.document else { return }
        let selection = findMatches[findIndex]
        selection.color = .systemYellow
        pdfBox.view.setCurrentSelection(selection, animate: true)
        pdfBox.view.go(to: selection)
        if let page = selection.pages.first {
            let number = document.index(for: page) + 1
            if number != currentPage { currentPage = number }
        }
    }

    /// Which slide row ⌘E and ⌘T should act on for a given question.
    ///
    /// `newQuestion` worked this out when a question was created; focusing an
    /// existing one didn't, so the armed row was left over from whatever you
    /// were looking at before. Click a Slide2Slide question, arm its question
    /// row, then click a Basic question, and ⌘E wrote into `questionPages` --
    /// which a Basic card neither shows nor exports.
    func defaultArmedRow(for question: Question) -> ArmedRow {
        switch question.kind {
        case .slide2slide:
            return .question
        case .template:
            return templates.template(id: question.templateId)?.slides == .front ? .question : .answer
        case .basic, .occlusion:
            return .answer
        }
    }

    /// True when the panel shows both slide rows for this question, and the
    /// armed one therefore needs marking.
    func showsBothRows(_ question: Question) -> Bool {
        switch question.kind {
        case .slide2slide:
            return true
        case .template:
            return templates.template(id: question.templateId)?.slides == .both
        case .basic, .occlusion:
            return false
        }
    }

    // MARK: - Undo

    /// Library-wide and on disk — see UndoLog.
    @Published private(set) var undoLog: UndoLog?
    /// The questions as they were when the current action started.
    private var pendingBefore: (label: String, lecture: URL, questions: [Question])?

    var canUndo: Bool { textUndoAvailable || undoLog?.undoLabel != nil }
    var canRedo: Bool { undoLog?.redoLabel != nil }
    var undoLabel: String? { undoLog?.undoLabel }
    var redoLabel: String? { undoLog?.redoLabel }

    /// Called before something changes the questions. The matching `commit` is
    /// what actually records it, so an action that turns out to change nothing
    /// leaves no step behind.
    func snapshot(_ label: String) {
        guard let document else { return }
        pendingBefore = (label, document.pdfURL, document.questions)
    }

    private func commitSnapshot() {
        guard let pending = pendingBefore, let document,
              document.pdfURL == pending.lecture else {
            pendingBefore = nil
            return
        }
        undoLog?.record(label: pending.label, lecture: pending.lecture,
                        before: pending.questions, after: document.questions)
        pendingBefore = nil
    }

    /// True when the thing with keyboard focus is a text field with something to
    /// undo. AppKit puts the field editor in the responder chain, so this is how
    /// we tell "undo my typing" from "undo my last change".
    private var textUndoAvailable: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText,
              let manager = responder.undoManager else { return false }
        return manager.canUndo
    }

    func undo() {
        if let responder = NSApp.keyWindow?.firstResponder as? NSText,
           let manager = responder.undoManager, manager.canUndo {
            manager.undo()
            return
        }
        guard let (step, lecture) = undoLog?.popUndo() else { return }
        if let trashed = step.trashed {
            library?.restore(trashed)
        } else {
            apply(step.before, to: lecture)
        }
        statusMessage = "Undid \(step.label)."
    }

    func redo() {
        guard let (step, lecture) = undoLog?.popRedo() else { return }
        if let trashed = step.trashed {
            // Trashing again puts the files somewhere new, so the step has to
            // learn the new paths or a second undo would look in the old place.
            var moved: [UndoLog.TrashedFile] = []
            for file in trashed {
                let url = URL(fileURLWithPath: file.original)
                if let result = try? trashPath(url) { moved.append(contentsOf: result) }
            }
            undoLog?.updateLatestTrash(moved)
        } else {
            apply(step.after, to: lecture)
        }
        statusMessage = "Redid \(step.label)."
    }

    private func trashPath(_ url: URL) throws -> [UndoLog.TrashedFile] {
        guard let library else { return [] }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? try library.trashFolder(url) : try library.trash(url)
    }

    /// Trashes a lecture or a folder and puts it on the undo stack.
    func trash(_ url: URL, isFolder: Bool, name: String) {
        guard let library else { return }
        if isFolder {
            if let open = document?.pdfURL, open.path.hasPrefix(url.path + "/") { closeLecture() }
        } else if document?.pdfURL == url {
            closeLecture()
        }
        do {
            let moved = isFolder ? try library.trashFolder(url) : try library.trash(url)
            undoLog?.recordTrash(label: "deleting \(name)", files: moved)
            statusMessage = "\(name) moved to the Trash."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Undo reaches across lectures, so it may have to open one first.
    private func apply(_ questions: [Question], to lecture: URL) {
        if document?.pdfURL != lecture {
            guard FileManager.default.fileExists(atPath: lecture.path) else {
                statusMessage = "That lecture is no longer in the library."
                return
            }
            open(lecture: lecture)
        }
        document?.questions = questions
        focusedQID = nil
    }

    // MARK: - Orphan recovery

    @Published var showRecovery = false
    @Published var showPageShift = false
    /// Orphans the user has already declined this session, so a rescan doesn't
    /// reopen the window on files they have decided to leave alone.
    private var dismissedOrphans: Set<String> = []

    var pendingOrphans: [OrphanRecovery.Orphan] {
        (library?.orphans ?? []).filter { !dismissedOrphans.contains($0.id) }
    }

    /// Called after a scan. Opens the window rather than guessing.
    func offerRecoveryIfNeeded() {
        guard !pendingOrphans.isEmpty else { return }
        showRecovery = true
    }

    func adopt(_ orphan: OrphanRecovery.Orphan, pdfURL: URL) {
        guard let library else { return }
        guard library.adopt(orphan, pdfURL: pdfURL) else { return }
        statusMessage = "\(orphan.questionCount) question\(orphan.questionCount == 1 ? "" : "s") reunited with \(pdfURL.deletingPathExtension().lastPathComponent)."
        // Open it straight away. Loading runs the page check, so if the slides
        // have moved under these questions you are told now -- while you still
        // remember doing it -- rather than the next time you happen to open it.
        open(lecture: pdfURL)
    }

    func dismissOrphan(_ orphan: OrphanRecovery.Orphan) {
        dismissedOrphans.insert(orphan.id)
    }

    // MARK: - Preview

    @Published var showPreview = false
    @Published var previewScope: ExportScope = .currentLecture

    func openPreview() {
        guard library != nil else { return }
        document?.saveNow()
        showPreview = true
    }

    /// The same scope rules the export sheet uses, so what you proof is the set
    /// you are about to export.
    func previewLectures(library: Library) -> [URL] {
        switch previewScope {
        case .wholeLibrary:
            return library.allLectures()
        case .currentFolder:
            guard let current = document?.pdfURL else { return [] }
            let folder = current.deletingLastPathComponent()
            return library.allLectures().filter { $0.deletingLastPathComponent() == folder }
        case .currentLecture:
            guard let current = document?.pdfURL else { return [] }
            return [current]
        }
    }

    /// Pressing E in the preview: open that lecture, switch the panel to that
    /// card type, focus the question, and scroll to its first slide. Seeing a
    /// bad crop and fixing it should be one key, not a hunt.
    func jumpToQuestion(qid: String, pdfURL: URL) {
        if document?.pdfURL != pdfURL { open(lecture: pdfURL) }
        guard let question = document?.question(qid: qid) else { return }
        panelType = Self.panelType(for: question)
        focusedQID = qid
        if let page = question.allPages.first { currentPage = page }
    }

    // MARK: - Search

    /// Two axes: what you are searching, and how far. ⌘F is the fast inline one
    /// (this lecture's slides); the other three open the sheet.
    enum SearchScope: String, CaseIterable, Identifiable {
        case librarySlides
        case lectureQuestions
        case libraryQuestions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .librarySlides:    return "All slides"
            case .lectureQuestions: return "This lecture's questions"
            case .libraryQuestions: return "All questions"
            }
        }

        /// Searching every PDF in a library means opening every PDF, so that one
        /// waits for Return rather than running on each keystroke.
        var runsOnSubmitOnly: Bool { self == .librarySlides }
    }

    struct SearchHit: Identifiable, Hashable {
        let id: String
        let title: String
        let lecture: String
        let detail: String
        let pdfPath: String
        let page: Int?
        let qid: String?
    }

    @Published var showSearchSheet = false
    @Published var searchScope: SearchScope = .libraryQuestions {
        didSet { searchLecture = nil; runSearch() }
    }
    @Published var searchQuery = "" { didSet { searchLecture = nil; runSearch() } }
    @Published private(set) var searchHits: [SearchHit] = []
    /// When a library-wide search is showing lectures rather than hits, this is
    /// the lecture you drilled into. Nil means the lecture list.
    @Published var searchLecture: String?
    @Published private(set) var isSearching = false

    /// Library searches land on a list of lectures first. A hundred hits spread
    /// over forty lectures is not a list anybody reads; "which lectures mention
    /// this" is the question you actually had, and the hits are one click in.
    var searchIsLibraryWide: Bool {
        searchScope != .lectureQuestions
    }

    /// (lecture, number of hits), in library order.
    var searchLectures: [(lecture: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for hit in searchHits {
            if counts[hit.lecture] == nil { order.append(hit.lecture) }
            counts[hit.lecture, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    var visibleSearchHits: [SearchHit] {
        guard searchIsLibraryWide, let lecture = searchLecture else { return searchHits }
        return searchHits.filter { $0.lecture == lecture }
    }

    func openSearch(_ scope: SearchScope) {
        guard library != nil else { return }
        // The open lecture autosaves on a delay, so flush it first -- otherwise
        // the question you typed a moment ago is the one thing the search can't
        // find, which reads as the search being broken.
        document?.saveNow()
        searchLecture = nil
        // Order matters: `runSearch` returns early unless the sheet is showing,
        // so setting the scope first cleared the results and nothing re-ran them.
        showSearchSheet = true
        searchScope = scope
        runSearch()
    }

    func submitSearch() {
        runSearch(force: true)
    }

    func runSearch(force: Bool = false) {
        guard showSearchSheet else { searchHits = []; return }
        let needle = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard needle.count >= 2 else { searchHits = []; return }
        if searchScope.runsOnSubmitOnly && !force { return }

        isSearching = true
        defer { isSearching = false }

        switch searchScope {
        case .lectureQuestions:
            guard let document else { searchHits = []; return }
            let url = document.pdfURL
            searchHits = questionHits(in: document.questions,
                                      lecture: url.deletingPathExtension().lastPathComponent,
                                      pdfPath: url.path,
                                      needle: needle)
        case .libraryQuestions:
            searchHits = allLectureSidecars().flatMap { url, questions in
                questionHits(in: questions,
                             lecture: url.deletingPathExtension().lastPathComponent,
                             pdfPath: url.path,
                             needle: needle)
            }
        case .librarySlides:
            searchHits = slideHits(needle: needle)
        }
    }

    private func questionHits(in questions: [Question], lecture: String,
                              pdfPath: String, needle: String) -> [SearchHit] {
        questions.compactMap { question in
            let text = ([question.front, question.back] + Array(question.blanks.values))
                .joined(separator: " ")
            guard text.lowercased().contains(needle) else { return nil }
            let pages = PageSet.describe(question.allPages)
            return SearchHit(
                id: question.qid,
                title: question.summary(template: templates.template(id: question.templateId)),
                lecture: lecture,
                detail: pages.isEmpty ? "" : "slides \(pages)",
                pdfPath: pdfPath,
                page: question.allPages.first,
                qid: question.qid
            )
        }
    }

    /// Opens every PDF in the library and searches its text layer. Capped per
    /// lecture and overall: a common word in a hundred lectures is thousands of
    /// hits, and nobody reads past the first few.
    private func slideHits(needle: String) -> [SearchHit] {
        guard let library else { return [] }
        var hits: [SearchHit] = []
        let perLecture = 25
        let total = 400

        for url in library.allLectures() {
            guard hits.count < total, let pdf = PDFDocument(url: url) else { continue }
            let lecture = url.deletingPathExtension().lastPathComponent
            var found = 0
            for index in 0..<pdf.pageCount where found < perLecture {
                guard let page = pdf.page(at: index),
                      let text = page.string,
                      let range = text.range(of: needle, options: .caseInsensitive) else { continue }
                found += 1
                hits.append(SearchHit(
                    id: "\(url.path)#\(index)",
                    title: Self.snippet(text, around: range),
                    lecture: lecture,
                    detail: "slide \(index + 1)",
                    pdfPath: url.path,
                    page: index + 1,
                    qid: nil
                ))
                if hits.count >= total { break }
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let match = flat.range(of: String(text[range]), options: .caseInsensitive) else {
            return String(flat.prefix(120))
        }
        let lower = flat.index(match.lowerBound, offsetBy: -50, limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(match.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[lower..<upper]).trimmingCharacters(in: .whitespaces)
        if lower != flat.startIndex { out = "…" + out }
        if upper != flat.endIndex { out += "…" }
        return out
    }

    private func allLectureSidecars() -> [(URL, [Question])] {
        guard let library else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return library.allLectures().compactMap { url in
            let sidecar = url.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            guard let data = try? Data(contentsOf: sidecar),
                  let file = try? decoder.decode(SidecarFile.self, from: data) else { return nil }
            return (url, file.questions)
        }
    }

    /// Opens whatever the hit points at -- a slide, or a question.
    func open(_ hit: SearchHit) {
        showSearchSheet = false
        let url = URL(fileURLWithPath: hit.pdfPath)
        if document?.pdfURL != url { open(lecture: url) }
        if let qid = hit.qid, let question = document?.question(qid: qid) {
            panelType = Self.panelType(for: question)
            focusedQID = qid
        }
        if let page = hit.page { currentPage = page }
    }

    static func panelType(for question: Question) -> PanelType {
        switch question.kind {
        case .basic:       return .basic
        case .slide2slide: return .slide2slide
        case .occlusion:   return .occlusion
        case .template:    return question.templateId.map { PanelType.template($0) } ?? .basic
        }
    }

    /// Tag changes are structural, so they belong on the undo stack too.
    func toggleTag(_ tag: String, on qid: String) {
        guard let document, var question = document.question(qid: qid) else { return }
        snapshot("that tag")
        if let index = question.tags.firstIndex(of: tag) {
            question.tags.remove(at: index)
        } else {
            question.tags.append(tag)
        }
        document.update(question)
        commitSnapshot()
    }

    // MARK: - Cropping

    /// What the overlay should outline for a page. Follows the armed row, so
    /// the same page can carry a different crop on the front and the back.
    func crop(forPage page: Int) -> CropRect? {
        focusedQuestion?.crop(page: page, row: armedRow)
    }

    /// Where an ⌥-drag ends up. On an occlusion question a dragged rectangle is
    /// a mask; on everything else it is a crop. Same gesture, and the card type
    /// already governs the whole panel, so there is never any doubt which.
    func regionDragged(_ rect: CropRect, page: Int) {
        // With nothing focused this used to do nothing at all, silently -- the
        // commonest way to conclude a feature is broken. Make the question the
        // drag obviously implies instead.
        if focusedQuestion == nil { newQuestion() }
        guard let question = focusedQuestion else {
            statusMessage = "Open a lecture first."
            return
        }
        if question.kind == .occlusion {
            addMask(rect, page: page)
        } else {
            setCrop(rect, page: page)
        }
    }

    // MARK: - Occlusion

    func masks(forPage page: Int) -> [CropRect] {
        guard let question = focusedQuestion, question.kind == .occlusion,
              question.occlusionPage == page else { return [] }
        return question.masks.map(\.rect)
    }

    func addMask(_ rect: CropRect, page: Int) {
        snapshot("that region")
        mutateFocused { question in
            // Occlusion is one image, so a drag on a different slide moves the
            // question to that slide rather than quietly doing nothing.
            if question.occlusionPage != page {
                question.answerPages = [page]
                question.questionPages = []
            }
            question.masks.append(Mask(rect: rect))
        }
    }

    func deleteMask(_ maskID: String) {
        guard let document, var question = focusedQuestion else { return }
        snapshot("removing that region")
        // A mask that has been exported has a card in Anki. Deleting it here
        // cannot delete that card -- nothing can, on import -- so it is reported
        // in the export sheet exactly like a deleted question.
        if question.childExports[maskID] != nil {
            document.retire(qid: question.guid(variant: maskID))
        }
        question.masks.removeAll { $0.id == maskID }
        question.childExports[maskID] = nil
        document.update(question)
        commitSnapshot()
    }

    func setOcclusionMode(_ mode: OcclusionMode) {
        // Undoable like every other mutator: this one changes how many cards the
        // question produces, which is the last thing you'd want stuck.
        snapshot("the reveal mode")
        mutateFocused { question in question.occlusionMode = mode }
    }

    /// What the panel promises before you export. Occlusion is the only thing in
    /// this app that can turn one question into a dozen cards, so it says so.
    var occlusionCardCount: Int {
        guard let question = focusedQuestion, question.kind == .occlusion else { return 0 }
        return question.occlusionMode == .separate ? max(1, question.masks.count) : 1
    }

    /// Committed by the crop overlay. Cropping a page the question doesn't yet
    /// cite attaches it first -- otherwise the drag would appear to do nothing,
    /// and "nothing happened" is the worst answer a gesture can give.
    func setCrop(_ crop: CropRect, page: Int) {
        snapshot("that crop")
        mutateFocused { question in
            switch armedRow {
            case .question:
                if !question.questionPages.contains(page) { question.questionPages.append(page) }
            case .answer:
                if !question.answerPages.contains(page) { question.answerPages.append(page) }
            }
            question.setCrop(crop, page: page, row: armedRow)
        }
    }

    /// `row` defaults to whatever is armed, which is what ⌘U wants. The crop
    /// badge passes its own row explicitly, so clicking the badge on one row
    /// can never clear a crop on the other.
    func clearCrop(page: Int, row: ArmedRow? = nil) {
        snapshot("removing that crop")
        let target = row ?? armedRow
        mutateFocused { question in
            question.setCrop(nil, page: page, row: target)
        }
    }

    var currentPageHasCrop: Bool {
        crop(forPage: currentPage) != nil
    }

    func cyclePanelType() {
        var order: [PanelType] = [.basic, .slide2slide, .occlusion]
        order.append(contentsOf: templates.templates.map { PanelType.template($0.id) })
        guard let index = order.firstIndex(of: panelType) else {
            panelType = .basic
            return
        }
        panelType = order[(index + 1) % order.count]
        focusedQID = visibleQuestions.last?.qid
    }

    /// The page ⌘E would take if you pressed it now.
    /// ⌘E replaces the row with anchor…here, so the hint has to be true for
    /// every direction that can go, not only forwards. Showing it only when the
    /// current page is past the end meant ⌘E could silently *shrink* a range
    /// with nothing on screen to warn you.
    var ghostPage: Int? {
        guard let question = focusedQuestion else { return nil }
        let pages = armedRow == .question ? question.questionPages : question.answerPages
        let next = PageSet.extend(from: anchorPage, to: currentPage)
        guard next != PageSet.normalise(pages) else { return nil }
        return currentPage
    }

    func counts() -> [(label: String, count: Int, type: PanelType)] {
        let questions = document?.questions ?? []
        var out: [(String, Int, PanelType)] = [
            ("Basic", questions.filter { $0.kind == .basic }.count, .basic),
            ("Slide2Slide", questions.filter { $0.kind == .slide2slide }.count, .slide2slide),
            ("Occlusion", questions.filter { $0.kind == .occlusion }.count, .occlusion)
        ]
        for template in templates.templates {
            let count = questions.filter { $0.kind == .template && $0.templateId == template.id }.count
            out.append((template.name, count, .template(template.id)))
        }
        return out.map { (label: $0.0, count: $0.1, type: $0.2) }
    }
}
