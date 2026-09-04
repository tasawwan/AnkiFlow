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
    case cloze
    case template(String)

    var kind: QuestionKind {
        switch self {
        case .basic:       return .basic
        case .slide2slide: return .slide2slide
        case .occlusion:   return .occlusion
        case .cloze:       return .cloze
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
        case .cloze:              return question.kind == .cloze
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
    @Published var showFlaggedPagesOnly = false
    @Published var showExportSheet = false
    @Published var editingTemplate: Template?
    @Published var statusMessage: String?

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

    /// Put the library away and go back to the empty state.
    ///
    /// Everything on disk is left exactly as it is -- this closes a window onto
    /// a folder, it does not touch the folder. The remembered path goes too, so
    /// the next launch opens empty rather than reopening what you just closed.
    func closeLibrary() {
        closeLecture()
        libraryObserver = nil
        library = nil
        undoLog = nil
        dismissedOrphans = []
        showRecovery = false
        watcher?.cancel()
        watcher = nil
        statusMessage = nil
        UserDefaults.standard.removeObject(forKey: "lastLibraryPath")
    }

    func openLibrary(at url: URL) {
        // `closeLecture`, not a bare save-and-nil: it is what takes the markup
        // bar down. Left up, its Done button and Esc both live inside the
        // "a lecture is open" branch of the view and would not be on screen,
        // while the menu item that stops editing is disabled because there is no
        // PDF -- a mode with no way out of it.
        closeLecture()
        let library = Library(root: url)
        self.library = library
        libraryObserver = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        // Unsaved marks/crops to the PDF are discarded rather than written to disk,
        // so the user's PDF is never modified without an explicit Save command.
        commitPendingText()
        stopEditingPDF(discardingChanges: true)
        document = nil
        focusedQID = nil
    }

    func open(lecture url: URL) {
        document?.saveNow()
        commitPendingText()
        stopEditingPDF(discardingChanges: true)
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
        let bounded = min(max(1, page), pageCount)
        guard showFlaggedPagesOnly else {
            currentPage = bounded
            return
        }
        let flagged = flaggedPages
        guard !flagged.isEmpty else { return }
        currentPage = flagged.min { abs($0 - bounded) < abs($1 - bounded) } ?? flagged[0]
    }

    func nextPage() {
        if showFlaggedPagesOnly {
            let pages = flaggedPages
            guard let index = pages.firstIndex(of: currentPage), !pages.isEmpty else {
                currentPage = pages.first ?? currentPage
                return
            }
            currentPage = pages[(index + 1) % pages.count]
        } else {
            goToPage(currentPage + 1)
        }
    }

    func previousPage() {
        if showFlaggedPagesOnly {
            let pages = flaggedPages
            guard let index = pages.firstIndex(of: currentPage), !pages.isEmpty else {
                currentPage = pages.last ?? currentPage
                return
            }
            currentPage = pages[(index - 1 + pages.count) % pages.count]
        } else {
            goToPage(currentPage - 1)
        }
    }

    var flaggedPages: [Int] {
        guard let pdf = document?.editableDocument else { return [] }
        return (0..<pdf.pageCount).compactMap { index in
            guard let page = pdf.page(at: index) else { return nil }
            return page.annotations.contains(where: PDFEditing.isFlag) ? index + 1 : nil
        }
    }

    func toggleFlaggedPagesOnly() {
        showFlaggedPagesOnly.toggle()
        if showFlaggedPagesOnly, let first = flaggedPages.first {
            currentPage = first
        }
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
            seedPage: nil
        )
        // Nothing is attached yet, and the anchor is where you are standing.
        //
        // A new question used to arrive already holding the current slide. That
        // made sense when there was one slide row; with two it is actively
        // wrong, because the flow is now type → Tab → ⌘E, and a seeded question
        // row would leave slide 12 on the front of a card whose answer is
        // 12–18. Attaching is an explicit act: ⌘T for this slide, ⌘E for a run.
        armedRow = defaultArmedRow(for: question)
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
    @Published private(set) var findAnnotationHighlight: (PDFPage, CGRect)?
    private struct FindMatch {
        let selection: PDFSelection?
        let page: PDFPage
        let bounds: CGRect
    }
    private var findMatches: [FindMatch] = []

    func openFind() {
        if findVisible {
            closeFind()
        } else {
            findVisible = true
        }
    }

    func closeFind() {
        findVisible = false
        findMatches = []
        findMatchCount = 0
        findIndex = 0
        findAnnotationHighlight = nil
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
            findAnnotationHighlight = nil
            pdfBox.view.setCurrentSelection(nil, animate: false)
            return
        }
        findMatches = document.findString(query, withOptions: [.caseInsensitive]).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            return FindMatch(selection: selection, page: page, bounds: selection.bounds(for: page))
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard PDFEditing.kind(of: annotation) == "FreeText" else { continue }
                guard let contents = annotation.contents,
                      contents.range(of: query, options: [.caseInsensitive]) != nil else { continue }
                // PDFKit's document search does not include FreeText
                // annotations. Build a page selection for the annotation's
                // bounds so the find result gets the same visible highlight
                // and navigation behavior as native slide text.
                findMatches.append(FindMatch(
                    selection: nil,
                    page: page,
                    bounds: annotation.bounds
                ))
            }
        }
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
        let match = findMatches[findIndex]
        if let selection = match.selection {
            findAnnotationHighlight = nil
            selection.color = .systemYellow
            pdfBox.view.setCurrentSelection(selection, animate: true)
            pdfBox.view.go(to: selection)
        } else {
            pdfBox.view.setCurrentSelection(nil, animate: false)
            findAnnotationHighlight = (match.page, match.bounds)
            pdfBox.view.go(to: match.bounds, on: match.page)
        }
        let number = document.index(for: match.page) + 1
        if number != currentPage { currentPage = number }
    }

    /// Which slide row ⌘E and ⌘T should act on for a given question.
    ///
    /// `newQuestion` worked this out when a question was created; focusing an
    /// existing one didn't, so the armed row was left over from whatever you
    /// were looking at before. Click a Slide2Slide question, arm its question
    /// row, then click a Basic question, and ⌘E wrote into `questionPages` --
    /// which a Basic card neither shows nor exports.
    /// Occlusion and cloze have no question-slides row, so their slides can only
    /// be answer slides. Everything else opens with the caret in the question
    /// field, and the armed row follows the caret from there.
    func defaultArmedRow(for question: Question) -> ArmedRow {
        switch question.kind {
        case .occlusion, .cloze:
            return .answer
        case .basic, .slide2slide:
            return .question
        case .template:
            return templates.template(id: question.templateId)?.slides == .back ? .answer : .question
        }
    }

    /// Where a range should start from, given which row is armed.
    ///
    /// It has to follow the armed row: reading it from `answerPages` while the
    /// *question* row is armed -- which is what Slide2Slide and a front-slides
    /// template do -- anchors one row on the other's slides, and the first ⌘E
    /// rewrites the row from a page that was never in it.
    func anchor(for question: Question, row: ArmedRow) -> Int {
        let pages = row == .question ? question.questionPages : question.answerPages
        return pages.first ?? currentPage
    }

    /// True when the panel shows both slide rows for this question, and the
    /// armed one therefore needs marking.
    func showsBothRows(_ question: Question) -> Bool {
        switch question.kind {
        case .basic, .slide2slide:
            return true
        case .template:
            return templates.template(id: question.templateId)?.slides == .both
        case .occlusion, .cloze:
            return false
        }
    }

    // MARK: - Undo

    /// Library-wide and on disk — see UndoLog.
    @Published private(set) var undoLog: UndoLog?
    /// The questions as they were when the current action started.
    private var pendingBefore: (label: String, lecture: URL, questions: [Question])?

    var canUndo: Bool {
        if isEditingPDF { return editSession?.canUndo == true }
        return textUndoAvailable || undoLog?.undoLabel != nil
    }
    var canRedo: Bool {
        if isEditingPDF { return editSession?.canRedo == true }
        return undoLog?.redoLabel != nil
    }
    var undoLabel: String? { isEditingPDF ? editSession?.undoLabel : undoLog?.undoLabel }
    var redoLabel: String? { isEditingPDF ? editSession?.redoLabel : undoLog?.redoLabel }

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
        // While the markup bar is up ⌘U belongs to the marks. The question undo
        // log is untouched by anything you draw on a slide, so the two stacks
        // never need to interleave.
        if isEditingPDF {
            commitPendingText()
            let label = editSession?.undoLabel
            editSession?.undo()
            repaintPDF()
            if let label { statusMessage = "Undid \(label)." }
            return
        }
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
        if isEditingPDF {
            commitPendingText()
            let label = editSession?.redoLabel
            editSession?.redo()
            repaintPDF()
            if let label { statusMessage = "Redid \(label)." }
            return
        }
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

    func trashOrphan(_ orphan: OrphanRecovery.Orphan) {
        guard let library, library.trashOrphan(orphan) else {
            statusMessage = "Could not move \(orphan.oldName) to the Trash."
            return
        }
        dismissedOrphans.remove(orphan.id)
        statusMessage = "\(orphan.oldName) moved to the Trash."
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
        case .cloze:       return .cloze
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

    // MARK: - Editing the PDF

    /// Whether the markup bar is up.
    ///
    /// Separate from `editTool`, and the separation matters: editing with the
    /// text-select tool in hand still selects text normally, which is what
    /// Highlight, Underline and Strikethrough need -- they act on a selection
    /// you have already made.
    @Published private(set) var isEditingPDF = false
    /// Live while editing: the pending marks, the undo stack, and whether any
    /// of it still needs saving. Nothing here reaches the file until you save.
    @Published private(set) var editSession: PDFEditSession?
    @Published var editTool: PDFEditing.Tool = .select {
        didSet {
            guard oldValue != editTool else { return }
            pdfBox.view.setCurrentSelection(nil, animate: false)
        }
    }
    @Published var editStroke: InkColour = .amber
    /// nil means "no fill" -- the outline only, which is what you want over a
    /// diagram nine times out of ten.
    @Published var editFill: InkColour?
    @Published var editLineWidth: Double = 2
    @Published var editFontSize: Double = 14
    @Published var editBold = false
    @Published var editItalic = false
    @Published var editUnderline = false
    @Published var showingStylePicker = false
    /// Raised when you try to leave editing with marks that were never saved.
    @Published var confirmingDiscardEdits = false
    /// Page deletion is the one edit that cannot be undone by doing the
    /// opposite, so it is the one that asks.
    @Published var confirmingPageDelete = false

    /// The four ink colours. Kept short on purpose: a colour well would let you
    /// pick something invisible on a white slide, and the point of marking a
    /// slide is that the mark is obvious.
    enum InkColour: String, CaseIterable, Identifiable {
        case amber, red, blue, green

        var id: String { rawValue }

        var label: String {
            switch self {
            case .amber: return "Amber"
            case .red:   return "Red"
            case .blue:  return "Blue"
            case .green: return "Green"
            }
        }

        var nsColor: NSColor {
            switch self {
            case .amber: return NSColor(red: 0.878, green: 0.627, blue: 0.227, alpha: 1)
            case .red:   return NSColor(red: 0.710, green: 0.329, blue: 0.369, alpha: 1)
            case .blue:  return NSColor(red: 0.294, green: 0.478, blue: 0.749, alpha: 1)
            case .green: return NSColor(red: 0.243, green: 0.612, blue: 0.427, alpha: 1)
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    var canEditPDF: Bool { document?.editableDocument != nil }
    var hasUnsavedPDFEdits: Bool { editSession?.hasUnsavedChanges == true }

    private var editSessionObserver: AnyCancellable?
    private var pendingPageRemap: [Int: Int] = [:]

    func startEditingPDF() {
        guard let lecture = document, let pdf = lecture.editableDocument else { return }
        let session = PDFEditSession(document: pdf, url: lecture.pdfURL)
        // Forwarded, or nothing driven by the session redraws: the Save button
        // would not appear on the first mark, ⌘S would stay disabled, and the
        // Undo menu would keep the title it had when editing began.
        editSessionObserver = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        editSession = session
        pendingPageRemap = [:]
        editTool = .select
        isEditingPDF = true
    }

    /// Leave editing. Refuses while there are unsaved marks -- it raises the
    /// confirmation instead, because silently throwing away a page of markup is
    /// the one thing this feature must never do.
    /// Push whatever is being typed into a text box onto the undo stack.
    ///
    /// A menu key equivalent does not move first responder, so ⌘S with the caret
    /// still in a note would write the annotation with its old (usually empty)
    /// contents. Resigning first responder ends the field's editing session,
    /// which is what commits it.
    /// Force the slide back onto the screen after the document changed under it.
    ///
    /// `layoutDocumentView` alone rebuilds the layout but does not always redraw
    /// a page whose annotations changed, which is what made undo look like it
    /// had done nothing at all.
    func repaintPDF() {
        let view = pdfBox.view
        view.layoutDocumentView()
        view.setNeedsDisplay(view.bounds)
        if let docView = view.documentView {
            docView.setNeedsDisplay(docView.bounds)
            func invalidateRecursively(_ v: NSView) {
                v.needsDisplay = true
                v.layer?.setNeedsDisplay()
                for sub in v.subviews {
                    invalidateRecursively(sub)
                }
            }
            invalidateRecursively(docView)
        }
    }

    /// Picks up a text mark instrument (highlight, underline, strikethrough).
    /// If text is currently selected in the PDF view, the mark is applied immediately to it.
    func applyTextMarkTool(_ tool: PDFEditing.Tool) {
        guard let mark = tool.textMark else {
            editTool = editTool == tool ? .select : tool
            return
        }
        // Capture the native selection before changing tools; editTool's
        // didSet clears it so a new tool cannot leave stale text selected.
        let selectedText = pdfBox.view.currentSelection
        editTool = tool
        if let selection = selectedText,
           let session = editSession {
            let made = PDFEditing.marks(for: selection, kind: mark, colour: editStroke.nsColor)
            if !made.isEmpty {
                session.perform("that \(mark.label.lowercased())",
                                undo: {
                                    for (annotation, page) in made {
                                        annotation.shouldDisplay = false
                                        page.removeAnnotation(annotation)
                                    }
                                },
                                redo: {
                                    for (annotation, page) in made {
                                        annotation.shouldDisplay = true
                                        page.addAnnotation(annotation)
                                    }
                                })
                pdfBox.view.setCurrentSelection(nil, animate: false)
                repaintPDF()
            }
        }
    }

    private func commitPendingText() {
        guard isEditingPDF else { return }
        pdfBox.view.window?.makeFirstResponder(pdfBox.view)
    }

    func stopEditingPDF(discardingChanges: Bool = false) {
        commitPendingText()
        if hasUnsavedPDFEdits && !discardingChanges {
            confirmingDiscardEdits = true
            return
        }
        if discardingChanges {
            editSession?.revertAll()
            pendingPageRemap = [:]
            pdfBox.view.layoutDocumentView()
        }
        confirmingDiscardEdits = false
        editSessionObserver = nil
        editSession = nil
        isEditingPDF = false
        showingStylePicker = false
        pdfBox.view.setCurrentSelection(nil, animate: false)
    }

    /// ⌘S. Writes the marks into the PDF and refreshes the fingerprint, so the
    /// slides re-render and the affected cards update on the next export.
    @discardableResult
    func savePDFEdits() -> Bool {
        commitPendingText()
        guard let lecture = document, let session = editSession else { return false }
        do {
            try lecture.applyPDFEdit(PDFEditing.Change(remap: pendingPageRemap,
                                                       boxChanges: session.boxChanges(),
                                                       label: "your markup"))
            session.markSaved()
            pendingPageRemap = [:]
            statusMessage = "Saved your markup into \(lecture.pdfURL.lastPathComponent)."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Marks

    /// Put a one-shot tool down once it has been used.
    ///
    /// Drawing a shape and then wanting to nudge it is the common next move, so
    /// the tool returns to Select rather than making you go and find a pointer.
    /// The text marks and Select itself stay in your hand -- you highlight three
    /// things in a row far more often than one.
    func toolWasUsed() {
        if editTool.isOneShot { editTool = .select }
    }

    /// Undo and redo, aimed at whichever stack is in play. The markup bar has
    /// its own buttons for these as well as the Edit menu, because in a mode
    /// with its own toolbar you look at the toolbar.
    func undoEdit() { undo() }
    func redoEdit() { redo() }

    /// Recolor whatever is selected, or set the color for the next mark.
    func setEditStroke(_ colour: InkColour) {
        commitActiveTextBox()
        editStroke = colour
        if let session = editSession, let selection = session.selection {
            session.setColour(colour.nsColor, on: selection.annotation)
            repaintPDF()
        }
    }

    func setEditFill(_ fill: InkColour?) {
        commitActiveTextBox()
        editFill = fill
        if let session = editSession, let selection = session.selection {
            session.setFill(fill?.nsColor, on: selection.annotation)
            repaintPDF()
        }
    }

    func setEditLineWidth(_ width: Double) {
        editLineWidth = width
        guard let session = editSession, let selection = session.selection,
              PDFEditing.kind(of: selection.annotation) != "FreeText" else { return }
        session.setLineWidth(CGFloat(width), on: selection.annotation)
        repaintPDF()
    }

    func setEditFontSize(_ size: Double) {
        commitActiveTextBox()
        editFontSize = size
        applySelectedTextFont()
    }

    func toggleEditBold() {
        editBold.toggle()
        if !pdfBox.toggleFontTrait(.boldFontMask) { applySelectedTextFont() }
    }

    func toggleEditItalic() {
        editItalic.toggle()
        if !pdfBox.toggleFontTrait(.italicFontMask) { applySelectedTextFont() }
    }

    func toggleEditUnderline() {
        if pdfBox.toggleUnderline() { return }
        editUnderline.toggle()
        guard let session = editSession, let selection = session.selection,
              PDFEditing.kind(of: selection.annotation) == "FreeText" else { return }
        let text = PDFEditing.richText(for: selection.annotation)
            ?? NSAttributedString(string: selection.annotation.contents ?? "",
                                   attributes: [.font: selection.annotation.font ?? NSFont.systemFont(ofSize: editFontSize),
                                                .foregroundColor: selection.annotation.fontColor ?? editStroke.nsColor])
        let updated = NSMutableAttributedString(attributedString: text)
        updated.addAttribute(.underlineStyle,
                             value: editUnderline ? NSUnderlineStyle.single.rawValue : 0,
                             range: NSRange(location: 0, length: updated.length))
        session.setAttributedString(updated, on: selection.annotation)
        repaintPDF()
    }

    private func commitActiveTextBox() {
        guard isEditingPDF else { return }
        pdfBox.view.window?.makeFirstResponder(pdfBox.view)
    }

    private func applySelectedTextFont() {
        guard let session = editSession, let selection = session.selection,
              PDFEditing.kind(of: selection.annotation) == "FreeText" else { return }
        session.setFontSize(CGFloat(editFontSize), on: selection.annotation)
        repaintPDF()
    }

    func deleteSelectedMark() {
        guard let session = editSession, let selection = session.selection else { return }
        session.remove(selection.annotation, from: selection.page)
        repaintPDF()
    }

    var currentPageIsFlagged: Bool {
        document?.editableDocument?.page(at: currentPage - 1)?.annotations.contains(where: PDFEditing.isFlag) == true
    }

    func togglePageFlag() {
        if !isEditingPDF { startEditingPDF() }
        guard let session = editSession,
              let page = session.document.page(at: currentPage - 1) else { return }
        if let marker = page.annotations.first(where: PDFEditing.isFlag) {
            session.perform("unflagging page \(currentPage)",
                            undo: {
                                marker.shouldDisplay = true
                                page.addAnnotation(marker)
                            },
                            redo: {
                                marker.shouldDisplay = false
                                page.removeAnnotation(marker)
                            })
            statusMessage = "Unflagged page \(currentPage)."
        } else {
            let marker = PDFEditing.flag(on: page)
            session.perform("flagging page \(currentPage)",
                            undo: {
                                marker.shouldDisplay = false
                                page.removeAnnotation(marker)
                            },
                            redo: {
                                marker.shouldDisplay = true
                                page.addAnnotation(marker)
                            })
            statusMessage = "Flagged page \(currentPage)."
        }
        repaintPDF()
    }

    // MARK: Undo, while editing

    var pdfUndoAvailable: Bool { isEditingPDF && editSession?.canUndo == true }
    var pdfRedoAvailable: Bool { isEditingPDF && editSession?.canRedo == true }

    // MARK: Pages

    /// Page operations write to the file straight away rather than waiting for
    /// ⌘S. They are not marks: deleting or reordering slides has to renumber
    /// every question that points at them, and that is a change to the question
    /// files as much as to the PDF. Batching it behind a save would mean holding
    /// two documents' worth of pending state in step.
    /// Called *before* a page operation touches the document.
    ///
    /// A page operation writes the live document, and the live document carries
    /// any pending marks with it -- so they are committed deliberately rather
    /// than smuggled out. This has to run first: bailing afterwards would leave
    /// the page already rotated or deleted in memory, nothing on disk, and the
    /// questions un-renumbered.
    private func readyForPageEdit() -> Bool {
        guard editSession?.hasUnsavedChanges == true else { return true }
        return savePDFEdits()
    }

    private func applyPageEdit(_ change: PDFEditing.Change) {
        guard let lecture = document else { return }
        do {
            try lecture.applyPDFEdit(change)
            pdfBox.view.layoutDocumentView()
            if currentPage > lecture.pageCount { currentPage = max(1, lecture.pageCount) }
            statusMessage = summary(of: change)
        } catch {
            statusMessage = error.localizedDescription
        }
        // Renumbering reloads the PDF from disk, which leaves every closure on
        // the undo stack pointing at pages of a document nobody can see any
        // more. The session is rebuilt against the new one, keeping the tool in
        // your hand -- and if the reload failed there is nothing to edit, so
        // editing ends rather than carrying on against a document that is gone.
        if isEditingPDF {
            let tool = editTool
            editSessionObserver = nil
            editSession = nil
            startEditingPDF()
            if editSession == nil {
                stopEditingPDF(discardingChanges: true)
                statusMessage = "Could not reopen \(lecture.pdfURL.lastPathComponent) after that change."
            } else {
                editTool = tool
            }
        }
    }

    private func summary(of change: PDFEditing.Change) -> String {
        let base = "Saved \(change.label) into \(document?.pdfURL.lastPathComponent ?? "the PDF")."
        guard change.touchesNumbering else { return base }
        return base + " Slide numbers in your questions followed it."
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let pdf = document?.editableDocument, readyForPageEdit() else { return }
        applyPageEdit(PDFEditing.rotate(pages: [currentPage], by: degrees, in: pdf))
    }

    func deleteCurrentPage() {
        guard let pdf = document?.editableDocument, readyForPageEdit() else { return }
        do {
            applyPageEdit(try PDFEditing.delete(pages: [currentPage], in: pdf))
        } catch {
            statusMessage = error.localizedDescription
        }
        confirmingPageDelete = false
    }

    func moveCurrentPage(to destination: Int) {
        guard let pdf = document?.editableDocument, readyForPageEdit() else { return }
        applyPageEdit(PDFEditing.move(page: currentPage, to: destination, in: pdf))
        currentPage = min(max(destination, 1), pdf.pageCount)
    }

    func movePage(from source: Int, to destination: Int) {
        guard source != destination, let pdf = document?.editableDocument else {
            currentPage = source
            return
        }
        if !isEditingPDF { startEditingPDF() }
        guard let session = editSession else { return }
        let change = PDFEditing.move(page: source, to: destination, in: pdf)
        let count = pdf.pageCount
        let oldRemap = pendingPageRemap
        pendingPageRemap = oldRemap.reduce(into: [:]) { result, entry in
            result[entry.key] = change.remap[entry.value] ?? entry.value
        }
        for entry in change.remap where oldRemap[entry.key] == nil {
            pendingPageRemap[entry.key] = entry.value
        }
        session.record("moving that slide",
                        undo: { [weak self] in
                            guard let self, let pdf = self.document?.editableDocument else { return }
                            _ = PDFEditing.move(page: destination, to: source, in: pdf)
                            self.pdfBox.view.layoutDocumentView()
                        },
                        redo: { [weak self] in
                            guard let self, let pdf = self.document?.editableDocument else { return }
                            _ = PDFEditing.move(page: source, to: destination, in: pdf)
                            self.pdfBox.view.layoutDocumentView()
                        })
        currentPage = min(max(destination, 1), count)
        pdfBox.view.layoutDocumentView()
        statusMessage = "Slide moved. Save to write the new order into the PDF."
    }

    func insertPages(from url: URL) {
        guard let pdf = document?.editableDocument, readyForPageEdit() else { return }
        do {
            applyPageEdit(try PDFEditing.insert(contentsOf: url, at: currentPage + 1, in: pdf))
        } catch {
            statusMessage = error.localizedDescription
        }
    }



    /// Give every slide the crop box this one has. The common case by a mile:
    /// a deck exported with the same margin on all sixty slides, trimmed once.
    ///
    /// The box is copied as a fraction of each page's *media* box rather than in
    /// points, so it lands in the same visual place on a slide of a different
    /// size -- a title page in another aspect ratio, say.
    func trimAllSlidesLikeThisOne() {
        guard let pdf = document?.editableDocument, let session = editSession,
              let page = pdf.page(at: currentPage - 1) else { return }
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return }
        let box = page.bounds(for: .cropBox)
        // Copying an untrimmed slide's box would *expand* every slide that has
        // already been trimmed back out to its full page -- the opposite of what
        // anyone reaching for this means.
        guard !CropRect(rect: box, in: media).isFullPage else {
            statusMessage = "Trim this slide first, then this copies its margins to the rest."
            return
        }
        let wantedFraction = CropRect(rect: box, in: media)

        // One undo step for the whole lecture: it was one command.
        var undos: [() -> Void] = []
        var redos: [() -> Void] = []
        for number in 1...pdf.pageCount where number != currentPage {
            guard let other = pdf.page(at: number - 1) else { continue }
            let otherMedia = other.bounds(for: .mediaBox)
            // The old box has to be read before it is replaced -- it is what the
            // crops and masks on that slide are expressed against.
            let old = other.bounds(for: .cropBox)
            let wanted = wantedFraction.rect(in: otherMedia).intersection(otherMedia)
            guard wanted.width > 1, wanted.height > 1, wanted != old else { continue }
            undos.append { other.setBounds(old, for: .cropBox) }
            redos.append { other.setBounds(wanted, for: .cropBox) }
        }
        guard !redos.isEmpty else {
            statusMessage = "Every slide already has this one's margins."
            return
        }
        session.perform("trimming every slide",
                        undo: { for step in undos { step() } },
                        redo: { for step in redos { step() } })
        pdfBox.view.layoutDocumentView()
    }

    // MARK: - Cloze
    // MARK: - Cloze

    /// Wrap a range of the focused cloze question's text in `{{cN::…}}`.
    ///
    /// `newCard` decides the ordinal: a new one makes this deletion its own
    /// card, reusing the highest existing one blanks it at the same time as the
    /// previous deletion. Returns false when the range is already inside a
    /// deletion -- nesting, which this app does not produce.
    @discardableResult
    func hideCloze(range: Range<String.Index>, newCard: Bool) -> Bool {
        guard let question = focusedQuestion, question.kind == .cloze else { return false }
        let ordinal = newCard
            ? Cloze.nextOrdinal(in: question.front)
            : max(1, question.clozeOrdinals.max() ?? 1)
        guard let updated = Cloze.wrap(question.front, range: range, ordinal: ordinal) else {
            return false
        }
        snapshot(newCard ? "hiding that" : "adding that to the card")
        mutateFocused { $0.front = updated }
        return true
    }

    func cyclePanelType() {
        var order: [PanelType] = [.basic, .slide2slide, .occlusion, .cloze]
        order.append(contentsOf: templates.templates.map { PanelType.template($0.id) })
        guard let index = order.firstIndex(of: panelType) else {
            show(.basic)
            return
        }
        show(order[(index + 1) % order.count])
    }

    /// Switch the panel to a card type and leave it ready to use.
    ///
    /// "Ready" means the slide row is already armed, so ⌘E and ⌘T land on the
    /// right side of the card the moment you arrive. Setting `panelType` on its
    /// own left `armedRow` holding whatever the *previous* type wanted -- arrive
    /// at Occlusion from Slide2Slide and the question row was still armed, so
    /// the first ⌘T went to a row that kind of card does not even show, and you
    /// had to click a row to fix it.
    func show(_ type: PanelType) {
        panelType = type
        focusedQID = visibleQuestions.last?.qid
        if let question = focusedQuestion {
            // The panel re-derives this from the focused field a moment later;
            // this is the value it starts from, and the one that stands when the
            // caret never lands anywhere (a template with no blanks, say).
            armedRow = defaultArmedRow(for: question)
            // The slide you are looking at, not the question's first slide.
            // Switching tabs is "make one of these about *this*"; jumping the
            // page away from what you were reading would be the opposite.
            anchorPage = currentPage
        } else {
            // Nothing here yet. Arm the row this kind of card would use, so the
            // first ⌘E or ⌘T creates a question and fills the right row.
            armedRow = (type.kind == .occlusion || type.kind == .cloze) ? .answer : .question
            if let template = templates.template(id: type.templateId), template.slides == .back {
                armedRow = .answer
            }
            anchorPage = currentPage
        }
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
            ("Occlusion", questions.filter { $0.kind == .occlusion }.count, .occlusion),
            ("Cloze", questions.filter { $0.kind == .cloze }.count, .cloze)
        ]
        for template in templates.templates {
            let count = questions.filter { $0.kind == .template && $0.templateId == template.id }.count
            out.append((template.name, count, .template(template.id)))
        }
        return out.map { (label: $0.0, count: $0.1, type: $0.2) }
    }
}
