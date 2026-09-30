import Foundation
import SwiftUI
import AppKit
import PDFKit
import Combine

/// Which card type the right panel is showing. One type per window -- never a
/// Basic question and an Occlusion in the same list.
///
/// A template tab is a *view* of the Basic list, not a fifth kind of card. The
/// cards in it are Basic cards whose text happens to fit that template's shape,
/// which is why `kind` answers `.basic` for one. Which tab a given question
/// belongs in is `AppState.tab(for:)`, because it needs the templates to say.
enum PanelType: Hashable {
    case basic
    case occlusion
    case cloze
    case template(String)

    var kind: QuestionKind {
        switch self {
        case .basic:       return .basic
        case .occlusion:   return .occlusion
        case .cloze:       return .cloze
        case .template:    return .basic
        }
    }

    var templateId: String? {
        if case .template(let id) = self { return id }
        return nil
    }
}

/// Which chip row ⌘E and ⌘T are arming.
enum ArmedRow {
    case question
    case answer
}

@MainActor
final class AppState: ObservableObject {
    @Published var library: Library?
    @Published var document: LectureDocument?
    @Published var currentPage: Int = 1 {
        didSet {
            guard currentPage != oldValue, let url = document?.pdfURL else { return }
            // Whatever was selected belonged to the slide you just left.
            pdfBox.view.setCurrentSelection(nil, animate: false)
            rememberPage(currentPage, for: url)
        }
    }
    @Published var panelType: PanelType = .basic
    /// Narrows the question list to cards carrying every one of these tags.
    ///
    /// Session-scoped, like every other stack in this app: a filter you forgot
    /// you left on is a list that looks empty for no reason, and finding your
    /// way out of that on a Tuesday morning is not worth what remembering it
    /// buys. A new question made while a filter is on is born with those tags,
    /// so writing under a filter cannot produce a card the filter then hides.
    @Published var tagFilter: Set<String> = [] {
        didSet {
            guard tagFilter != oldValue else { return }
            // Only when the filter actually hid what you had open. Moving focus
            // every time would close the card you were mid-sentence in -- and,
            // if you had not typed anything yet, throw it away.
            guard let question = focusedQuestion, !passesTagFilter(question) else { return }
            focusedQID = nil
        }
    }
    @Published var focusedQID: String? {
        didSet {
            // Last touched wins. ⌘T, ⌘E and ⌘R aim at one thing, and the honest
            // answer to which one is whichever you put your hands on most
            // recently -- so picking up a card lets go of the lecture question.

            // Leaving a card you put nothing on throws it away. Next runloop,
            // because deleting here would change the document from inside this
            // property's own publish.
            guard let abandoned = oldValue, abandoned != focusedQID else { return }
            Task { @MainActor [weak self] in self?.discard(ifEmpty: abandoned) }
        }
    }
    /// Bigger, smaller, or back to the default.
    enum TextSizeChange { case bigger, smaller, reset }

    /// The menu asks; the notes pane does it.
    ///
    /// Resizing means rebuilding the styled text at a new base size, and only
    /// the pane knows how to put the caret back afterwards. A tick rather than
    /// a published value because the same request twice running -- ⌘+ ⌘+ -- has
    /// to arrive twice.
    private(set) var pendingTextSizeChange: TextSizeChange = .reset
    @Published private(set) var textSizeTick = 0

    func changeTextSize(_ change: TextSizeChange) {
        pendingTextSizeChange = change
        textSizeTick += 1
    }

    @Published var armedRow: ArmedRow = .answer
    /// Which slide row has its crop list open.
    ///
    /// On the state rather than inside the row, because the row is rebuilt
    /// whenever the card redraws -- which, while you are typing in it, is every
    /// keystroke. `@State` there was reset by each rebuild, so the list opened
    /// and closed again before you saw it, and only stayed open once you had
    /// left the card and stopped causing rebuilds.
    @Published var expandedCropRow: ArmedRow?
    @Published var anchorPage: Int = 1
    @Published var showSidebar = true
    @Published var showThumbnails = false
    /// The notes editor at the foot of the right panel. On by default: notes you
    /// have to go and reveal are notes you do not take.
    @Published var showNotes = true
    /// The open lecture's notes, or nil when no lecture is open.
    @Published private(set) var notes: LectureNotes?
    @Published var showFlaggedPagesOnly = false
    /// Show only slides no question cites. The companion to the flag filter:
    /// one finds the slides you marked, this finds the ones you have not
    /// covered, which is the gap you cannot see by scrolling.
    @Published var showUncoveredPagesOnly = false {
        didSet { if showUncoveredPagesOnly { showFlaggedPagesOnly = false } }
    }

    /// Slides some question cites, on either side. A slide on the answer of one
    /// card is covered as surely as one on the front of another -- the question
    /// this answers is "have I written anything about this slide", not "have I
    /// written a question whose front is this slide".
    var coveredPages: Set<Int> {
        var out = Set<Int>()
        for question in document?.questions ?? [] where !question.isEmpty {
            out.formUnion(question.allPages)
        }
        return out
    }

    var uncoveredPages: Set<Int> {
        guard pageCount > 0 else { return [] }
        return Set(1...pageCount).subtracting(coveredPages)
    }
    @Published var showExportSheet = false
    @Published var showSyncSheet = false
    /// What the last background poll found and did not act on: conflicts, and
    /// deletions. Drives the count on the menu item; the sheet re-reads from
    /// Anki rather than trusting this, which can be a minute stale.
    @Published var pendingSync: SyncPlan?
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
        // Said once, on the run that lifts settings out of a library, because
        // the change is invisible until an export lands somewhere unexpected.
        if SettingsStore.shared.consumeMigrationNotice() {
            statusMessage = "Settings now live with the app rather than in this folder, and deck names gained a level — “\(library.settings.resolvedDeckRoot)”, then your library's name. Cards already in Anki stay where they are; clear the deck root in Settings to keep the old names. The .ankiflow folder is no longer used and can be deleted."
        } else if LibraryPaths.hasLeftovers(inLibrary: url) {
            statusMessage = "The .ankiflow folder in this library is no longer used — settings live with the app and images are cached outside your coursework now. It can be deleted."
        }
        self.focusedQID = nil
        UserDefaults.standard.set(url.path, forKey: "lastLibraryPath")
        undoLog = UndoLog(libraryRoot: url)
        dismissedOrphans = []
        startWatchingLibrary()
        let lectures = library.allLectures()
        if let target = rememberedLecture(in: url, among: lectures) ?? lectures.first {
            open(lecture: target)
        }
        offerRecoveryIfNeeded()
    }

    // MARK: - Where you left off

    /// Which lecture was last open in each library, and which page was last
    /// shown in each lecture.
    ///
    /// Kept per lecture rather than as one global "last page", so every lecture
    /// remembers its own place: coming back to one you were halfway through puts
    /// you back where you were instead of at slide 1, whether you got there by
    /// reopening the app or by clicking it in the sidebar. Small enough for
    /// defaults -- a path and an integer each.
    private enum Place {
        static let lecture = "lastLectureByLibrary"
        static let page = "lastPageByLecture"
    }

    private func rememberLecture(_ url: URL) {
        guard let root = library?.root.path else { return }
        var map = UserDefaults.standard.dictionary(forKey: Place.lecture) as? [String: String] ?? [:]
        map[root] = url.path
        UserDefaults.standard.set(map, forKey: Place.lecture)
    }

    private func rememberPage(_ page: Int, for url: URL) {
        var map = UserDefaults.standard.dictionary(forKey: Place.page) as? [String: Int] ?? [:]
        map[url.path] = page
        UserDefaults.standard.set(map, forKey: Place.page)
    }

    private func rememberedLecture(in root: URL, among lectures: [URL]) -> URL? {
        guard let map = UserDefaults.standard.dictionary(forKey: Place.lecture) as? [String: String],
              let path = map[root.path] else { return nil }
        // Matched against the library's own list rather than trusted from
        // defaults: a lecture renamed, moved or deleted in Finder since last
        // time would otherwise open nothing at all.
        return lectures.first { $0.path == path }
    }

    private func rememberedPage(for url: URL) -> Int? {
        (UserDefaults.standard.dictionary(forKey: Place.page) as? [String: Int])?[url.path]
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
        notes?.saveNow()
        notes = nil
        // Unsaved marks/crops to the PDF are discarded rather than written to disk,
        // so the user's PDF is never modified without an explicit Save command.
        commitPendingText()
        stopEditingPDF(discardingChanges: true)
        document = nil
        focusedQID = nil
    }

    func open(lecture url: URL) {
        // A new lecture means new slides; the word lists were the old one's.
        forgetVocabulary()
        // Before the save, or the empty card goes out with it.
        discardEmptyFocusedQuestion()
        document?.saveNow()
        notes?.saveNow()
        commitPendingText()
        stopEditingPDF(discardingChanges: true)
        let opened = LectureDocument(pdfURL: url, libraryRoot: library?.root)
        opened.hideFile = library?.settings.hideSidecarFiles ?? true
        document = opened
        documentObserver = opened.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // `labelColor`, not a palette colour: it is the system text colour and
        // follows light and dark on its own, so a note written in one appearance
        // is still readable in the other.
        // Deliberately *not* forwarded into AppState's objectWillChange, unlike
        // the document. The note changes on every keystroke, and forwarding it
        // would redraw the sidebar, the slide pane and the question panel once
        // per character typed. The notes views observe it directly instead; the
        // only thing the rest of the app needs to know is that a different note
        // is open, which `notes` being @Published already says.
        notes = LectureNotes(pdfURL: url, textColour: .labelColor)
        // Old-scheme template questions become ordinary cards carrying their
        // own words, once, here.
        adoptTemplateText()
        // Slide order is settled on open, not as you work: attaching a slide
        // while the caret is in a question would otherwise make that row jump
        // out from under you, which is the same reason rating a topic does not
        // reorder the topics list.
        opened.sortQuestionsBySlides()
        // And the deck path comes back off anything an earlier sync filed as a
        // tag. Only this lecture's own, and only when it is open -- a lecture
        // you never look at keeps its stray tag until you do, which costs
        // nothing and avoids rewriting the whole library on launch.
        scrubPathTags()
        // A shift is not something to leave in a banner and hope for: open it.
        if opened.pendingShift != nil { showPageShift = true }
        rememberLecture(url)
        watchLecture(url)
        topicFilter = nil
        // Clamped, because the remembered page may be past the end of a PDF that
        // has had slides taken out of it since.
        let wanted = rememberedPage(for: url) ?? 1
        currentPage = min(max(1, wanted), max(1, opened.pageCount))
        anchorPage = currentPage
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
        let all = document?.questions ?? []
        // A topic in hand ignores the tabs. You clicked a disease to see what
        // you have written about it, and making you find the tab each card
        // happens to live in would be answering a different question.
        //
        // The matching set is worked out once, when you click, rather than on
        // every redraw: it reads the text layer of every cited slide, which is
        // not something to do per keystroke.
        if topicFilter != nil {
            return all.filter { topicMatches.contains($0.qid) }
        }
        // Insertion order, deliberately. Nothing re-sorts behind you.
        return all.filter { tab(for: $0) == panelType && passesTagFilter($0) }
    }

    /// A topic you clicked in the topics pane. While it is set the question
    /// panel shows every card that mentions it, whatever kind of card it is.
    @Published var topicFilter: String?
    @Published private var topicMatches: Set<String> = []

    /// Shows the cards a topic appears in. Opens the lecture first when the
    /// topic came from the folder or library list, since the cards are in it.
    func showCards(for topic: Topic, in lecture: URL? = nil) {
        if let lecture, document?.pdfURL != lecture { open(lecture: lecture) }
        focusedQID = nil
        topicMatches = questionsMentioning(topic.name)
        topicFilter = topic.name
        statusMessage = topicMatches.isEmpty
            ? "Nothing in this lecture mentions “\(topic.name)”."
            : nil
    }

    /// Every card that mentions a term -- in what you wrote, or on a slide it
    /// cites.
    ///
    /// The slides count because that is where most of a topic actually lives. A
    /// card reading "What are the four types?" is about hypersensitivity even
    /// though it never says the word; the slide behind it says it on every
    /// line. Searching only your own words would have found the cards where you
    /// happened to repeat the slide, which are the ones you least need help
    /// finding.
    private func questionsMentioning(_ term: String) -> Set<String> {
        let needle = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var out = Set<String>()
        for question in document?.questions ?? [] where !question.isEmpty {
            if Self.mentions(needle, in: question.front.lowercased())
                || Self.mentions(needle, in: question.back.lowercased()) {
                out.insert(question.qid)
                continue
            }
            for page in question.allPages
            where Self.mentions(needle, in: pageText(page)) {
                out.insert(question.qid)
                break
            }
        }
        return out
    }

    /// Substring, but not inside a longer word.
    ///
    /// A topic can be three letters -- "IgE", "ANA" -- and a plain `contains`
    /// puts every card holding "banana" in a list about antinuclear antibodies.
    /// Both sides are already lowercased by the callers.
    static func mentions(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        var search = haystack[haystack.startIndex...]
        while let found = search.range(of: needle) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            search = haystack[haystack.index(after: found.lowerBound)...]
        }
        return false
    }

    private var pageTextCache: [Int: String] = [:]

    /// A slide's text layer, lowercased and kept, because the topic search
    /// walks every cited page of every card.
    private func pageText(_ page: Int) -> String {
        if let cached = pageTextCache[page] { return cached }
        guard let pdf = document?.document, page >= 1, page <= pdf.pageCount else { return "" }
        let text = (pdf.page(at: page - 1)?.string ?? "").lowercased()
        pageTextCache[page] = text
        return text
    }

    // MARK: Which tab a question belongs in

    /// Cached template matches, keyed by the text that was matched.
    ///
    /// Matching is string work, and `visibleQuestions` and `counts()` both run
    /// on every redraw of the panel -- which is every keystroke. The key is the
    /// text itself rather than the qid, so editing a card invalidates only its
    /// own entry and two cards with the same text share one.
    private var matchCache: [String: String] = [:]
    private var matchCacheStamp = ""

    /// The template whose shape this question's text fits, if any.
    func matchedTemplateId(for question: Question) -> String? {
        let stamp = templates.templates.map { "\($0.fingerprint)|\($0.kind.rawValue)" }
            .joined(separator: "\u{1F}")
        if stamp != matchCacheStamp {
            matchCache.removeAll(keepingCapacity: true)
            matchCacheStamp = stamp
        }
        // Bounded rather than pruned cleverly: typing a long answer makes an
        // entry per keystroke, and none of the old ones will ever be asked for
        // again. Throwing the lot away costs one re-match per visible card.
        if matchCache.count > 4000 { matchCache.removeAll(keepingCapacity: true) }

        // The kind is part of the key: an occlusion template and a basic one
        // can be worded identically, and only one of them is this card's.
        let key = question.kind.rawValue + "\u{1F}" + question.front + "\u{1F}" + question.back
        if let cached = matchCache[key] { return cached.isEmpty ? nil : cached }
        let found = Template.bestMatch(front: question.front, back: question.back,
                                       kind: question.kind, in: templates.templates)
        matchCache[key] = found?.id ?? ""
        return found?.id
    }

    /// Where this question shows up in the panel.
    ///
    /// Text first: a Basic card whose wording fits a template lands in that
    /// template's tab, whether it was written through the template or typed out
    /// by hand. The session hint only covers the one case text cannot -- a card
    /// you just made and have not typed into yet.
    func tab(for question: Question) -> PanelType {
        // Written before templates became a lens, and not yet converted -- which
        // happens the first time its lecture is opened.
        if question.kind == .template {
            return question.templateId.map { PanelType.template($0) } ?? .basic
        }
        if let hint = question.viewTemplateId,
           let template = templates.template(id: hint),
           template.enabled, template.kind == question.kind,
           question.hasNoText
            || template.recover(front: question.front, back: question.back) != nil {
            return .template(hint)
        }
        if let match = matchedTemplateId(for: question) { return .template(match) }
        switch question.kind {
        case .occlusion:        return .occlusion
        case .cloze:            return .cloze
        case .basic, .template: return .basic
        }
    }

    /// The template this question is being read through, if any.
    func template(for question: Question) -> Template? {
        templates.template(id: tab(for: question).templateId)
    }

    /// What was typed into each of a template's blanks, read back out of the
    /// finished text. Empty for a question that has nothing in it yet.
    func blankValues(for question: Question, template: Template) -> [String: String] {
        template.recover(front: question.front, back: question.back) ?? [:]
    }

    /// Type into one blank of a template. The card's own text is what changes --
    /// the blanks are a way of editing it, not a second copy of it.
    func setBlank(_ key: String, to value: String, on qid: String, template: Template) {
        guard let document, var question = document.question(qid: qid) else { return }
        // Re-rendering a question the template cannot read would throw away
        // whatever is in it. An empty one has nothing to lose, and every other
        // question in a template's tab is there because it reads back.
        guard question.hasNoText
                || template.recover(front: question.front, back: question.back) != nil
        else { return }
        var values = template.recover(front: question.front, back: question.back) ?? [:]
        values[key] = value
        let on = template.selectedOptions(inFront: question.front)
        let rendered = template.render(blanks: values, options: on)
        question.front = rendered.front
        // A template with no back of its own leaves the answer as free text.
        if !template.composed(options: on).back.isEmpty { question.back = rendered.back }
        question.viewTemplateId = template.id
        question.updatedAt = Date()
        document.update(question)
        fileTopics(from: values, template: template)
    }

    /// Ticks or unticks one of a shape's optional questions on a card.
    ///
    /// The card's own words are what change -- ticking appends the sentence,
    /// unticking takes it away -- because that is the only place the state can
    /// live. Whatever you had typed into the blanks the option brought with it
    /// survives being unticked and comes back with it, since it is recovered
    /// from the answer text either way.
    func setOption(_ key: String, on: Bool, for qid: String, template: Template) {
        guard let document, var question = document.question(qid: qid) else { return }
        var selected = template.selectedOptions(inFront: question.front)
        guard selected.contains(key) != on else { return }
        let values = template.recover(front: question.front, back: question.back) ?? [:]
        snapshot(on ? "asking that too" : "dropping that question")
        if on { selected.insert(key) } else { selected.remove(key) }
        let rendered = template.render(blanks: values, options: selected)
        question.front = rendered.front
        if !template.composed(options: selected).back.isEmpty { question.back = rendered.back }
        question.viewTemplateId = template.id
        question.updatedAt = Date()
        document.update(question)
    }

    /// Which blank of a clinical shape belongs in which section of the topics
    /// panel. A disease is a diagnosis, so it is Dx -- not a concept.
    static let clinicalTopicRoutes: [(key: String, type: String)] = [
        ("disease", "Dx"), ("tx", "Tx"), ("rx", "Rx")
    ]

    /// Puts every clinical topic already in the library under the right heading.
    ///
    /// Reads each lecture's cards and its notes straight off disk, so a lecture
    /// you have not opened is fixed alongside the one you have -- the point
    /// being that you should not have to visit two hundred files to correct a
    /// routing decision this app got wrong.
    ///
    /// Driven by the cards rather than by guessing at names: a topic is moved to
    /// Dx only because some card in that lecture has it as its Disease, which
    /// is the only evidence that would justify moving something you filed by
    /// hand.
    @discardableResult
    func reclassifyClinicalTopics() -> Int {
        guard let library else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var moved = 0

        for url in library.allLectures() {
            let questions: [Question]
            if let document, document.pdfURL == url {
                questions = document.questions
            } else {
                let sidecar = url.deletingPathExtension()
                    .appendingPathExtension(AnkiIdentity.sidecarExtension)
                guard let data = try? Data(contentsOf: sidecar),
                      let file = try? decoder.decode(SidecarFile.self, from: data)
                else { continue }
                questions = file.questions
            }

            var wanted: [String: String] = [:]
            for question in questions {
                guard let template = Template.bestMatch(front: question.front,
                                                        back: question.back,
                                                        kind: question.kind,
                                                        in: templates.templates),
                      let values = template.recover(front: question.front,
                                                    back: question.back)
                else { continue }
                for route in Self.clinicalTopicRoutes {
                    let name = (values[route.key] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.count > 2, name.count < 80 else { continue }
                    wanted[name] = route.type
                }
            }
            guard !wanted.isEmpty else { continue }

            let notesURL = AnkiIdentity.notesURL(for: url)
            if let document, document.pdfURL == url, let notes {
                // The open lecture goes through its own object, which owns the
                // file and is watching it -- writing underneath it would be
                // overwritten by its next autosave.
                for (name, type) in wanted {
                    guard let topic = notes.topics.first(where: { $0.id == name.lowercased() }),
                          topic.type.caseInsensitiveCompare(type) != .orderedSame else { continue }
                    notes.moveTopic(topic, to: type)
                    moved += 1
                }
            } else {
                moved += (try? TopicBlock.refile(wanted, inFileAt: notesURL)) ?? 0
            }
        }

        statusMessage = moved == 0
            ? "Every clinical topic is already under the right heading."
            : "Re-filed \(moved) topic\(moved == 1 ? "" : "s")."
        return moved
    }

    /// Disease, Tx and Rx become topics as you type them.
    ///
    /// Only ones that are not already there, and always at Low: re-editing a
    /// card must not duplicate a topic or push a rating you have since raised
    /// back down.
    private func fileTopics(from values: [String: String], template: Template) {
        guard let notes else { return }
        let routes = Self.clinicalTopicRoutes
        for route in routes {
            let name = (values[route.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count > 2, name.count < 80,
                  !notes.topics.contains(where: { $0.id == name.lowercased() }) else { continue }
            notes.addTopic(name, type: route.type)
        }
    }

    // MARK: Tag filter

    func passesTagFilter(_ question: Question) -> Bool {
        tagFilter.isEmpty || tagFilter.isSubset(of: Set(question.tags))
    }

    /// The tags worth offering as filters: the library's own list, plus any tag
    /// this lecture's cards carry that the list has never heard of.
    /// Only tags that are actually on a card in this lecture.
    ///
    /// The whole vocabulary was the wrong list: a chip for a tag nothing here
    /// carries can only ever empty the panel, so every one of them was a click
    /// that led nowhere. Ordered by the library's list so the chips keep a
    /// stable order rather than jumping about as you tag things, with anything
    /// the list has never heard of after them.
    var filterTags: [String] {
        let used = Set((document?.questions ?? []).flatMap(\.tags))
        guard !used.isEmpty else { return [] }
        var out = (library?.settings.activeTags ?? []).map(\.name).filter(used.contains)
        for tag in used.sorted() where !out.contains(tag) { out.append(tag) }
        return out
    }

    func toggleTagFilter(_ tag: String) {
        if tagFilter.contains(tag) {
            tagFilter.remove(tag)
        } else {
            tagFilter.insert(tag)
        }
    }

    func clearTagFilter() { tagFilter = [] }

    var focusedQuestion: Question? {
        document?.question(qid: focusedQID)
    }

    @discardableResult
    func newQuestion() -> Question? {
        guard let document else { return nil }
        guard canAddQuestions(to: panelType) else {
            statusMessage = "That template is switched off, so it only reads the "
                + "cards you already made. Turn it back on in Templates to add more."
            return nil
        }
        snapshot("adding that question")
        var question = Question(kind: panelType.kind, seedPage: nil)

        // A template tab is a *view* of the Basic list, so its cards are Basic
        // cards -- `templateId` belongs to the old scheme and stays nil. What
        // puts a card in the tab you made it in is `viewTemplateId`.
        //
        // It has to be set here because a template recognises its cards by
        // their wording, and a card you have just made has no wording yet.
        // Without the hint a new CC card was filed on the Basic list and never
        // appeared in the tab where ⌘N was pressed, which from where you sit
        // looks exactly like ⌘N doing nothing at all.
        question.viewTemplateId = panelType.templateId

        // Nothing is attached yet, and the anchor is where you are standing.
        //
        // A new question used to arrive already holding the current slide. That
        // made sense when there was one slide row; with two it is actively
        // wrong, because the flow is now type -> Tab -> Cmd-E, and a seeded
        // question row would leave slide 12 on the front of a card whose answer
        // is 12-18. Attaching is an explicit act: Cmd-T for this slide, Cmd-E
        // for a run.
        armedRow = defaultArmedRow(for: question)
        document.add(question)
        commitSnapshot()
        focusedQID = question.qid
        anchorPage = currentPage
        return question
    }

    /// Cmd-Return -- finish this question and fold the card shut. It does *not*
    /// open a new one: Cmd-N does that, and two keys that both made questions
    /// meant one of them made one you hadn't asked for.
    func commitAndAdvance() {
        guard let document, let current = focusedQuestion else { return }
        if current.isEmpty {
            // Nothing in it, so there is nothing to commit and no reason to
            // leave an empty card behind.
            document.delete(qid: current.qid)
            focusedQID = document.questions.last(where: { tab(for: $0) == panelType })?.qid
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

    /// Bumped by Cmd-Return. The focused question card watches it, pushes its
    /// text into the model and gives up keyboard focus -- which is also what
    /// makes Cmd-Return look like it did something in an app that has no
    /// unsaved state to show you.
    @Published private(set) var commitSignal = 0

    /// A card you opened and put nothing on is thrown away when you leave it.
    ///
    /// Cmd-N and a change of mind would otherwise leave an empty question in the
    /// file, and an empty question is a card that exports as a blank. It takes
    /// no undo step: being offered a way back to a card you never wrote anything
    /// in is stranger than the card quietly not existing.
    func discard(ifEmpty qid: String) {
        guard let document, let question = document.question(qid: qid),
              question.isEmpty else { return }
        document.delete(qid: qid)
    }

    /// The same, for the card open right now.
    ///
    /// For the moments where the focus change that normally does this never
    /// comes: quitting, switching away from the app, closing a lecture.
    func discardEmptyFocusedQuestion() {
        guard let qid = focusedQID, let document,
              let question = document.question(qid: qid), question.isEmpty else { return }
        document.delete(qid: qid)
        focusedQID = nil
    }

    func deleteFocusedQuestion() {
        guard let document, let qid = focusedQID else { return }
        snapshot("deleting that question")
        document.delete(qid: qid)
        commitSnapshot()
        focusedQID = document.questions.last(where: { tab(for: $0) == panelType })?.qid
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

    /// Deleting a template cannot touch a card.
    ///
    /// Nothing written today points at a template: a card built through one is
    /// an ordinary Basic card holding its own finished text, and the template
    /// only recognises that text to put the card in its own tab. Delete it and
    /// those cards move back to Basic, reading exactly as they did.
    ///
    /// The sweep below is for lectures written under the old scheme that have
    /// not been opened since, where the words really did live in the template.
    /// It writes them into the questions before the template goes. Returns how
    /// many it had to rescue, which is zero for anything current.
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

    /// Write a template question's text into the question itself.
    ///
    /// The back follows the exporter rather than the file: a template with a
    /// back of its own always won, so that is what is on the card in Anki and
    /// what has to survive. Anything typed into the free answer field of such a
    /// question was never on a card and is not resurrected here.
    private func convert(_ question: inout Question, using template: Template) {
        let rendered = template.render(blanks: question.blanks)
        let back = rendered.back.trimmingCharacters(in: .whitespacesAndNewlines)
        question.kind = .basic
        question.templateId = nil
        question.viewTemplateId = template.id
        question.front = rendered.front.trimmingCharacters(in: .whitespacesAndNewlines)
        if !back.isEmpty { question.back = back }
        question.blanks = [:]
        question.updatedAt = Date()
    }

    /// A template question whose template is gone.
    ///
    /// The text of these cards never existed anywhere but in the template, so
    /// there is nothing to restore -- only the values that were typed into the
    /// blanks, which are at least the words you wrote. Better a card that reads
    /// oddly and can be fixed than one that is blank and cannot.
    private func salvage(_ question: inout Question) {
        if question.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            question.front = question.blanks.keys.sorted()
                .compactMap { key in
                    let value = (question.blanks[key] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
                .joined(separator: " — ")
        }
        question.kind = .basic
        question.templateId = nil
        question.blanks = [:]
        question.updatedAt = Date()
    }

    /// Bring a lecture written under the old scheme up to date, once.
    ///
    /// Templates used to be part of a question: the file said `type: template`
    /// and held the blanks, and the words on the card lived only in the template
    /// file. That made a card hostage to a file it never mentioned. Now the
    /// question carries its own finished text and the template merely recognises
    /// it, so opening an old lecture writes that text down and the dependency
    /// is gone for good.
    private func adoptTemplateText() {
        guard let document else { return }
        var questions = document.questions
        var converted = 0
        var orphaned = 0
        for index in questions.indices where questions[index].kind == .template {
            if let template = templates.template(id: questions[index].templateId) {
                convert(&questions[index], using: template)
                converted += 1
            } else {
                salvage(&questions[index])
                orphaned += 1
            }
        }
        guard converted + orphaned > 0 else { return }
        document.questions = questions
        document.saveNow()
        if orphaned > 0 {
            statusMessage = orphaned == 1
                ? "One question was built from a template that is missing — its text was pieced back together from what you had typed into it. Worth a look."
                : "\(orphaned) questions were built from templates that are missing — their text was pieced back together from what you had typed into them. Worth a look."
        }
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
        defer { reportArmedRow() }
        mutateFocused { question in
            switch armedRow {
            case .question: question.questionPages = pages
            case .answer:   question.answerPages = pages
            }
        }
    }

    /// ⌘T -- add or remove just this page, for the non-contiguous stragglers.
    func toggleCurrentPage(force: Bool = false) {
        let page = currentPage
        snapshot("that slide")
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
        reportArmedRow()
    }

    /// What the armed row holds now, said out loud.
    ///
    /// ⌘T is a keystroke with no visible actor -- the change happens in a row
    /// that may be scrolled out of sight, so nothing tells you whether it landed
    /// or which side it landed on. This is also the thing to read when the row
    /// and the panel disagree: it reports the model, not the chips.
    private func reportArmedRow() {
        guard let question = focusedQuestion else {
            statusMessage = "Open a question first — ⌘T attaches the slide to the card you're editing."
            return
        }
        let pages = armedRow == .question ? question.questionPages : question.answerPages
        let side = armedRow == .question ? "Question" : "Answer"
        statusMessage = pages.isEmpty
            ? "\(side) slides: none"
            : "\(side) slides: \(PageSet.describe(pages))"
    }

    /// ⌘R -- start a new range here.
    func setAnchorToCurrentPage() {
        anchorPage = currentPage
        snapshot("re-anchoring")
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
    /// were looking at before. Click a question, arm its question
    /// row, then click a Basic question, and ⌘E wrote into `questionPages` --
    /// which a Basic card neither shows nor exports.
    /// Occlusion and cloze have no question-slides row, so their slides can only
    /// be answer slides. Everything else opens with the caret in the question
    /// field, and the armed row follows the caret from there.
    func defaultArmedRow(for question: Question) -> ArmedRow {
        // Which rows a template's cards show is the template's choice, and it
        // is made by the shape the card is being read through -- not by
        // anything stored on the card, which is a plain Basic one.
        if let template = template(for: question) {
            return template.effectiveSlides == .back ? .answer : .question
        }
        switch question.kind {
        case .occlusion, .cloze:
            return .answer
        case .basic, .template:
            return .question
        }
    }

    /// Where a range should start from, given which row is armed.
    ///
    /// It has to follow the armed row: reading it from `answerPages` while the
    /// *question* row is armed -- which is what a front-slides
    /// template do -- anchors one row on the other's slides, and the first ⌘E
    /// rewrites the row from a page that was never in it.
    func anchor(for question: Question, row: ArmedRow) -> Int {
        let pages = row == .question ? question.questionPages : question.answerPages
        return pages.first ?? currentPage
    }

    /// True when the panel shows both slide rows for this question, and the
    /// armed one therefore needs marking.
    func showsBothRows(_ question: Question) -> Bool {
        // A template's cards draw both rows exactly as a Basic card does; its
        // "slides on" setting picks the armed one rather than hiding the other.
        if let template = template(for: question) {
            return template.kind == .basic || template.kind == .template
        }
        switch question.kind {
        case .basic, .template:
            return true
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
        if notesLedgerLeads { return true }
        return textUndoAvailable || undoLog?.undoLabel != nil
    }
    var canRedo: Bool {
        if isEditingPDF { return editSession?.canRedo == true }
        if lastListSurface == .notes, notesUndo.canRedo { return true }
        return undoLog?.redoLabel != nil
    }
    var undoLabel: String? {
        if isEditingPDF { return editSession?.undoLabel }
        return notesLedgerLeads ? notesUndo.undoLabel : undoLog?.undoLabel
    }
    var redoLabel: String? {
        if isEditingPDF { return editSession?.redoLabel }
        if lastListSurface == .notes, notesUndo.canRedo { return notesUndo.redoLabel }
        return undoLog?.redoLabel
    }

    // MARK: Notes-list undo

    /// Which of the two list ledgers ⌘Z is currently aimed at.
    ///
    /// One variable rather than a focus test, because clicking a rating chip or
    /// a checkbox does not move the first responder, so asking AppKit what has
    /// focus would give the wrong answer for exactly the actions this covers.
    /// Whichever list you last changed is the one that gets taken back.
    enum ListSurface { case questions, notes }
    private(set) var lastListSurface: ListSurface = .questions
    let notesUndo = NotesUndoLog()
    /// Republished so the Edit menu relabels itself; the log is not observable
    /// on its own.
    @Published private(set) var notesUndoTick = 0

    private var notesLedgerLeads: Bool { lastListSurface == .notes && notesUndo.canUndo }

    /// Wrap any change to a lecture's topics or questions so it can be taken
    /// back. Records nothing when the change turned out to be a no-op.
    func notesEdit(_ label: String, on pdfURL: URL, addedQIDs: [String] = [],
                   _ change: () -> Void) {
        let before = notesLists(for: pdfURL)
        change()
        let after = notesLists(for: pdfURL)
        guard before != after || !addedQIDs.isEmpty else { return }
        notesUndo.record(NotesUndoStep(label: label, pdfURL: pdfURL,
                                       before: before, after: after,
                                       addedQIDs: addedQIDs))
        lastListSurface = .notes
        notesUndoTick += 1
    }

    private func notesLists(for pdfURL: URL) -> NotesLists {
        if let notes, notes.pdfURL == pdfURL {
            return NotesLists(topics: notes.topics, questions: notes.questions)
        }
        return NotesFile.lists(forPDF: pdfURL)
    }

    private func applyNotes(_ lists: NotesLists, to pdfURL: URL) {
        if let notes, notes.pdfURL == pdfURL {
            notes.replaceLists(topics: lists.topics, questions: lists.questions)
        } else {
            try? NotesFile.write(lists, forPDF: pdfURL)
        }
    }

    private func undoNotesEdit() {
        guard let step = notesUndo.popUndo() else { return }
        for qid in step.addedQIDs { document?.delete(qid: qid) }
        applyNotes(step.before, to: step.pdfURL)
        statusMessage = "Undid \(step.label)."
        notesUndoTick += 1
    }

    private func redoNotesEdit() {
        guard let step = notesUndo.popRedo() else { return }
        applyNotes(step.after, to: step.pdfURL)
        statusMessage = step.addedQIDs.isEmpty
            ? "Redid \(step.label)."
            : "Redid \(step.label) — the cards it made are not brought back; move it again."
        notesUndoTick += 1
    }

    /// Called before something changes the questions. The matching `commit` is
    /// what actually records it, so an action that turns out to change nothing
    /// leaves no step behind.
    func snapshot(_ label: String) {
        // Touching a card aims ⌘Z back at the card ledger.
        lastListSurface = .questions
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
        // While the markup bar is up ⌘Z belongs to the marks. The question undo
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
            statusMessage = "Undid that typing."
            return
        }
        if notesLedgerLeads {
            undoNotesEdit()
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
        if let responder = NSApp.keyWindow?.firstResponder as? NSText,
           let manager = responder.undoManager, manager.canRedo {
            manager.redo()
            statusMessage = "Redid that typing."
            return
        }
        if lastListSurface == .notes, notesUndo.canRedo {
            redoNotesEdit()
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
        statusMessage = "\(orphan.questionCount) question\(orphan.questionCount == 1 ? "" : "s") reunited with \(pdfURL.lectureName)."
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
        panelType = tab(for: question)
        // A filter that hides where you just jumped to would make ⏎ do nothing
        // visible, so landing on a question lifts it.
        if !passesTagFilter(question) { tagFilter = [] }
        focusedQID = qid
        if let page = question.allPages.first { currentPage = page }
    }

    // MARK: - Search

    /// Two axes: what you are searching, and how far. ⌘F is the fast inline one
    /// (this lecture's slides); the other three open the sheet.
    enum SearchScope: String, CaseIterable, Identifiable {
        case librarySlides
        case libraryQuestions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .librarySlides:    return "All slides"
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
    ///
    /// Both remaining scopes are library-wide; the lecture-only one went with
    /// the pane it belonged to.
    var searchIsLibraryWide: Bool { true }

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
        // Let go of the text field first.
        //
        // The question fields are real NSTextViews now, and a first responder
        // that is still holding the keyboard gets the keystrokes meant for the
        // search sheet -- so ⌘F opened it and then everything you typed went
        // into the card behind it. Dropping focus here hands the next key to
        // the sheet, and coming back is a click into the field you want.
        focusedField = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
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
        case .libraryQuestions:
            searchHits = allLectureSidecars().flatMap { url, questions in
                questionHits(in: questions,
                             lecture: url.lectureName,
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
            let lecture = url.lectureName
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

    /// Re-sorts the open lecture now, for when you have just finished attaching
    /// slides and want the list to catch up.
    func sortQuestionsBySlides() {
        guard let document else { return }
        snapshot("sorting by slide")
        if document.sortQuestionsBySlides() {
            statusMessage = "Questions reordered by slide."
            commitSnapshot()
        } else {
            statusMessage = "Already in slide order."
        }
    }

    /// Which of the focused card's text fields has the caret, for the fields
    /// themselves to read and write. Cleared by anything that takes the
    /// keyboard somewhere else.
    @Published var focusedField: QuestionField?

    // MARK: - How far along a lecture is

    /// QIDs Anki still has as new cards. Refreshed by the background poll; empty
    /// when Anki has not been reachable, which is why `nothingLeft` below is
    /// only ever claimed for a lecture that has actually been exported.
    @Published private(set) var unlearnedQIDs: Set<String> = []

    enum LectureState {
        /// Nothing written here yet.
        case untouched
        /// Written, but not finished: cards Anki has not seen.
        case inProgress
        /// Every question exported, and Anki has no new cards left for them.
        case learned
    }

    /// Read from the sidecar, so the sidebar can colour a lecture it has not
    /// opened.
    func lectureState(for pdfURL: URL, questions: [Question],
                      reviewed: Bool = false) -> LectureState {
        // Your word, first. Everything below it is the app guessing from
        // evidence; this is you knowing.
        if reviewed { return .learned }
        let real = questions.filter { !$0.isEmpty }
        guard !real.isEmpty else { return .untouched }
        guard real.allSatisfy({ $0.export != nil }) else { return .inProgress }
        // Only claimable with something to claim it from: with Anki closed the
        // set is empty, and every exported lecture would otherwise go green.
        guard !unlearnedQIDs.isEmpty || ankiSeenRecently else { return .inProgress }
        return real.contains { unlearnedQIDs.contains($0.qid) } ? .inProgress : .learned
    }

    /// True once a poll has actually talked to Anki this session.
    private(set) var ankiSeenRecently = false

    /// Marks a lecture learned, or takes the mark back.
    ///
    /// Works on a lecture that is not open by writing its sidecar directly --
    /// ticking off a course from the library list is the whole point, and
    /// opening two hundred lectures to do it is not.
    func toggleReviewed(_ pdfURL: URL) {
        if let document, document.pdfURL == pdfURL {
            document.setReviewed(!document.reviewed)
            return
        }
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecar),
              var file = try? decoder.decode(SidecarFile.self, from: data) else {
            statusMessage = "Nothing to mark here yet — this lecture has no questions."
            return
        }
        file.reviewed = (file.reviewed ?? false) ? nil : true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let out = try? encoder.encode(file) {
            try? AtomicWrite.write(out, to: sidecar,
                                   hidden: library?.settings.hideSidecarFiles ?? true)
            objectWillChange.send()
        }
    }

    func isReviewed(_ pdfURL: URL) -> Bool {
        if let document, document.pdfURL == pdfURL { return document.reviewed }
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecar),
              let file = try? decoder.decode(SidecarFile.self, from: data) else { return false }
        return file.reviewed ?? false
    }

    // MARK: - Topic types

    var topicTypes: [TopicType] { SettingsStore.shared.settings.topicTypes }

    /// Folded sections, by type. Per type rather than per lecture: fold Rx once
    /// and it stays folded everywhere, which is what you meant by folding it.
    @Published private var collapsedTopicSections: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedTopicSections") ?? [])

    func isTopicSectionCollapsed(_ type: String) -> Bool {
        collapsedTopicSections.contains(type.lowercased())
    }

    func toggleTopicSection(_ type: String) {
        let key = type.lowercased()
        if collapsedTopicSections.contains(key) {
            collapsedTopicSections.remove(key)
        } else {
            collapsedTopicSections.insert(key)
        }
        UserDefaults.standard.set(Array(collapsedTopicSections), forKey: "collapsedTopicSections")
    }

    func addTopicType(_ raw: String) {
        let name = TopicType.tidy(raw)
        guard !name.isEmpty,
              !topicTypes.contains(where: { $0.id == name.lowercased() }) else { return }
        SettingsStore.shared.settings.topicTypes.append(TopicType(name: name))
    }

    func setTopicType(_ type: TopicType, enabled: Bool) {
        guard let index = topicTypes.firstIndex(where: { $0.id == type.id }) else { return }
        SettingsStore.shared.settings.topicTypes[index].enabled = enabled
    }

    /// Removes the definition. Anything already filed under it stays in its
    /// notes file and keeps its section, switched off, until you move it --
    /// exactly as if you had toggled it. Built-ins are never removed, the same
    /// rule tags follow.
    func removeTopicType(_ type: TopicType) {
        guard !type.isBuiltIn else { return }
        SettingsStore.shared.settings.topicTypes.removeAll { $0.id == type.id }
    }

    func moveTopicTypes(from source: IndexSet, to destination: Int) {
        SettingsStore.shared.settings.topicTypes.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Syncing back from Anki

    /// One accepted change from the reconciliation sheet.
    struct SyncResolution {
        let url: URL
        let qid: String
        /// Nil means "leave this field alone" -- the row was declined, or the
        /// field never differed.
        var front: String?
        var back: String?
        var tags: [String]?
        var delete = false
    }

    /// Every lecture's questions, with the open one taken from memory rather
    /// than disk so unsaved edits are part of the comparison instead of showing
    /// up as changes Anki made.
    func lectureQuestionsForSync() -> [AnkiSync.LectureQuestions] {
        guard let library else { return [] }
        var out: [AnkiSync.LectureQuestions] = []
        let onDisk = Dictionary(allLectureSidecars().map { ($0.0, $0.1) },
                                uniquingKeysWith: { a, _ in a })
        for url in library.allLectures() {
            let questions: [Question]
            if let document, document.pdfURL == url {
                questions = document.questions
            } else if let stored = onDisk[url] {
                questions = stored
            } else {
                continue
            }
            out.append(AnkiSync.LectureQuestions(
                url: url,
                name: url.lectureName,
                questions: questions,
                pathTags: pathTags(for: url)
            ))
        }
        return out
    }

    /// Both tags a lecture's cards could be carrying: the one its folders
    /// compute now, and the one it was last exported under. They differ
    /// whenever a folder has been renamed since.
    private func pathTags(for url: URL) -> Set<String> {
        var tags = Set<String>()
        if let library { tags.insert(library.pathTag(for: url)) }
        let pinned: String?
        if let document, document.pdfURL == url {
            pinned = document.lastExportedDeckName
        } else {
            let sidecar = url.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pinned = (try? Data(contentsOf: sidecar))
                .flatMap { try? decoder.decode(SidecarFile.self, from: $0) }?
                .lastExportedDeckName
        }
        if let pinned {
            tags.insert(pinned.replacingOccurrences(of: " ", with: "-"))
        }
        return tags
    }

    /// Takes the deck path back off the open lecture's questions.
    ///
    /// A repair, not a feature: an earlier sync read the path tag back out of
    /// Anki and filed it as though you had chosen it. The tags themselves are
    /// harmless in your collection -- that is where they belong -- they just
    /// have no business being shown here as something you tagged.
    func scrubPathTags() {
        guard let document else { return }
        let unwanted = pathTags(for: document.pdfURL)
        guard !unwanted.isEmpty else { return }
        var questions = document.questions
        var changed = false
        for index in questions.indices {
            let kept = questions[index].tags.filter { !unwanted.contains($0) }
            if kept.count != questions[index].tags.count {
                questions[index].tags = kept
                changed = true
            }
        }
        guard changed else { return }
        document.questions = questions
        document.saveNow()
    }

    /// Applies the accepted rows, and re-bases every question it touches.
    ///
    /// Re-basing matters: the merged text becomes the new common ancestor, so
    /// the same edit is not offered again on the next sync. Without it, taking
    /// Anki's version once would leave the recorded ancestor pointing at the
    /// text nobody has any more, and every future sync would report the same
    /// row forever.
    @discardableResult
    func applySync(_ resolutions: [SyncResolution]) -> Int {
        guard !resolutions.isEmpty else { return 0 }
        snapshot("those changes from Anki")

        var applied = 0
        let byLecture = Dictionary(grouping: resolutions, by: \.url)

        for (url, rows) in byLecture {
            if let document, document.pdfURL == url {
                var questions = document.questions
                applied += apply(rows, to: &questions)
                document.questions = questions
                for row in rows where row.delete { document.forget(qid: row.qid) }
                document.saveNow()
                continue
            }

            let sidecar = url.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: sidecar),
                  var file = try? decoder.decode(SidecarFile.self, from: data) else { continue }
            applied += apply(rows, to: &file.questions)
            for row in rows where row.delete {
                file.questions.removeAll { $0.qid == row.qid }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            if let out = try? encoder.encode(file) {
                try? AtomicWrite.write(out, to: sidecar,
                                       hidden: library?.settings.hideSidecarFiles ?? true)
            }
        }
        return applied
    }

    private func apply(_ rows: [SyncResolution], to questions: inout [Question]) -> Int {
        var applied = 0
        for row in rows where !row.delete {
            guard let index = questions.firstIndex(where: { $0.qid == row.qid }) else { continue }
            if let front = row.front { questions[index].front = front }
            if let back = row.back { questions[index].back = back }
            if let tags = row.tags { questions[index].tags = tags }
            // Read into a local first: the right-hand side reads the same
            // element the left-hand side is writing, and an inout write needs
            // exclusive access to it.
            let merged = questions[index].textFingerprint
            questions[index].export?.textHash = merged
            applied += 1
        }
        return applied
    }

    /// Watches Anki for the rest of the window's life.
    ///
    /// What it applies on its own is exactly what has nothing to decide: a card
    /// changed in Anki and not here since the last export. The three-way merge
    /// is what makes that safe -- if you have also touched the question, it is
    /// a conflict by definition and waits for you. Deletions always wait,
    /// whatever they look like.
    func autoSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard library != nil,
                  library?.settings.autoSyncFromAnki ?? true,
                  // Not while the sheet is up: it is doing its own, fuller read,
                  // and applying rows underneath it would change the list you
                  // are looking at.
                  !showSyncSheet else { continue }
            await pollAnki()
        }
    }

    func pollAnki() async {
        guard await AnkiConnect.isAvailable() else { return }
        let lectures = lectureQuestionsForSync()
        let expected = lectures.reduce(0) { $0 + $1.questions.filter { $0.export != nil }.count }
        guard let fetched = try? await AnkiSync.fetchRecent(expecting: expected) else { return }

        let plan = AnkiSync.plan(lectures: lectures,
                                 ankiNotes: fetched.notes,
                                 allGuids: fetched.allGuids)

        ankiSeenRecently = true
        // What Anki still has as new. One query and one fields read, rather than
        // asking per lecture -- a curriculum has hundreds and the answer for all
        // of them fits in the cards you have not started.
        if let newIDs = try? await AnkiConnect.findNotesScoped(query: "is:new"),
           let newNotes = try? await AnkiConnect.notesInfo(newIDs) {
            unlearnedQIDs = Set(newNotes.map(\.guid))
        }

        let automatic = plan.edits.filter { $0.side == .ankiOnly }
        if !automatic.isEmpty {
            let applied = applySync(automatic.map { row in
                SyncResolution(url: row.url, qid: row.id,
                               front: row.textIsAppOwned ? nil : row.front?.theirs,
                               back: row.textIsAppOwned ? nil : row.back?.theirs,
                               tags: row.tags?.theirs)
            })
            if applied > 0 {
                statusMessage = applied == 1
                    ? "Pulled one edit back from Anki."
                    : "Pulled \(applied) edits back from Anki."
            }
        }

        var remaining = plan
        remaining.edits = plan.edits.filter { $0.side == .bothChanged }
        pendingSync = remaining.isEmpty ? nil : remaining
    }

    // MARK: - The lecture file changing underneath us

    private let pdfWatcher = FileWatcher()
    /// Bumped when the document is replaced, so the slide pane knows to put the
    /// scroll position back rather than starting at the top.
    @Published private(set) var pdfReloadToken = 0

    private func watchLecture(_ url: URL) {
        pdfWatcher.watch(url) { [weak self] in
            self?.lectureFileChanged()
        }
    }

    /// Something else wrote the lecture -- annotated on an iPad and synced back,
    /// re-exported from another app, replaced in Finder.
    private func lectureFileChanged() {
        guard let document else { return }

        // Marks you have not saved are carried onto the newer file rather than
        // being in the way of it.
        //
        // Refusing to reload was the safe answer and the wrong one: it left you
        // holding marks you could not write, because the stale-write guard will
        // not let them go on top of a newer lecture either. Annotations are
        // additive -- a highlight from here and one from the iPad are two
        // entries in a list, not two edits to the same sentence -- so replaying
        // yours onto their copy is a real merge, not a compromise.
        let pending = editSession?.pendingMarks()
        let carrying = pending.map { !$0.isEmpty } ?? false

        // Passed even when it is empty: an open session still has to be handed
        // over to the new document, and the handover is built alongside the
        // replay.
        guard document.reloadPDFFromDisk(replaying: pending) else { return }
        pdfWatcher.acknowledgeOwnWrite()
        forgetVocabulary()
        // Past the end of a lecture that lost slides.
        currentPage = min(max(1, currentPage), max(1, document.pageCount))
        // The session was holding the document that has just been replaced.
        // Where every mark came across as itself -- the ordinary case -- the
        // session is handed the new document and keeps its history: your marks
        // are the same objects, and the pages they name are redirected, so ⌘Z
        // still goes back through everything you did before the file changed.
        // Only when a mark had to be copied is the history untrustworthy, and
        // then the session is rebuilt and the marks arrive as a clean slate.
        //
        // A slide you have reordered is the other case. It is the one pending
        // edit that is not an annotation, so it is not among the marks replayed
        // onto the new file, and `pendingPageRemap` would go on claiming a move
        // the PDF no longer has. Rare enough to answer by starting over.
        if isEditingPDF, let session = editSession {
            if pendingPageRemap.isEmpty, let rebase = document.lastReplay.rebase {
                session.adopt(rebase.document, moves: rebase.moves,
                              baseline: rebase.baseline)
                if carrying { session.markCarriedOver() }
            } else {
                let tool = editTool
                restartEditSession()
                if carrying { editSession?.markCarriedOver() }
                editTool = tool
            }
        }

        // Last, so the pane restores the scroll position against the document
        // it is about to be handed.
        pdfReloadToken += 1
        // No status line for the ordinary case. The point of watching the file
        // is that annotating on the iPad and looking back at the Mac shows the
        // newer slide with nothing to acknowledge; a banner every time you put
        // the pencil down is the thing this was supposed to replace. A shift is
        // different -- that one needs an answer.
        if document.pendingShift != nil { showPageShift = true }

        let result = document.lastReplay
        if result.stranded > 0 {
            statusMessage = "\(result.replayed) of your marks were carried onto the new version of \(document.pdfURL.finderName); \(result.stranded) were on slides it no longer has."
        } else if result.replayed > 0 {
            statusMessage = result.replayed == 1
                ? "Your unsaved mark was carried onto the new version of this lecture."
                : "Your \(result.replayed) unsaved marks were carried onto the new version of this lecture."
        }
    }

    /// Opens whatever the hit points at -- a slide, or a question.
    func open(_ hit: SearchHit) {
        showSearchSheet = false
        let url = URL(fileURLWithPath: hit.pdfPath)
        if document?.pdfURL != url { open(lecture: url) }
        if let qid = hit.qid, let question = document?.question(qid: qid) {
            panelType = tab(for: question)
            if !passesTagFilter(question) { tagFilter = [] }
            focusedQID = qid
        }
        if let page = hit.page { currentPage = page }
    }

    /// Yield is one choice: setting one clears whichever was on, in a single
    /// edit, so one ⌘Z puts it back the way it was.
    func setYield(_ yield: String?, on qid: String) {
        guard let document, var question = document.question(qid: qid) else { return }
        snapshot("that yield")
        question.tags.removeAll(where: TagDefinition.isYield)
        if let yield { question.tags.append(yield) }
        question.updatedAt = Date()
        document.update(question)
        commitSnapshot()
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
    /// Armed for one crop.
    ///
    /// Separate from `expandedCropRow` because the two outlive each other: the
    /// drag is a one-shot -- it puts itself down the moment it commits, the way
    /// every other one-shot tool here does, so the pane goes straight back to
    /// scrolling -- while the list stays open, now showing the crop you just
    /// made.
    @Published var croppingRow: ArmedRow?

    var isCropping: Bool { croppingRow != nil }

    func regionDragged(_ rect: CropRect, page: Int) {
        // With nothing focused this used to do nothing at all, silently -- the
        // commonest way to conclude a feature is broken. Make the question the
        // drag obviously implies instead.
        if focusedQuestion == nil { newQuestion() }
        guard let question = focusedQuestion else {
            statusMessage = "Open a lecture first."
            return
        }
        // The crop control wins, and it is the only thing that can.
        //
        // On an occlusion card every drag became a region, which left the slide
        // itself impossible to crop -- a figure you wanted to occlude *and*
        // trim down to had no way to be trimmed. ⌥-drag still occludes, because
        // that is the thing you do forty times on one slide and it should need
        // no aiming; cropping is the rarer act, so it is the one you say out
        // loud by pressing the button first.
        //
        // The row comes from the button rather than from `armedRow`: you
        // pressed the crop control on a particular row, and a crop landing on
        // the other one would be the button lying about what it does.
        if let row = croppingRow {
            setCrop(rect, page: page, row: row)
        } else if question.kind == .occlusion {
            addMask(rect, page: page)
        } else {
            setCrop(rect, page: page)
        }
        croppingRow = nil
    }

    // MARK: - Occlusion

    // MARK: - Completions from the slides

    private var vocabularyCache: [Int: [String]] = [:]

    /// The words a completion may come from: this question's own slides, plus
    /// the one on screen.
    ///
    /// Deliberately not the whole lecture. Precision is the entire reason this
    /// is worth having -- a few hundred words off the slides you are writing
    /// about are nearly all terms you are about to type, and widening it to
    /// every page is how you get suggestions from a topic three weeks away.
    func completionCorpus(for question: Question?) -> SlideCorpus {
        var numbers = Set<Int>()
        if let question {
            numbers.formUnion(question.questionPages)
            numbers.formUnion(question.answerPages)
        }
        numbers.insert(currentPage)

        var corpus = SlideCorpus()
        var seen = Set<String>()
        for number in numbers.sorted() {
            let tokens = vocabulary(ofPage: number)
            guard !tokens.isEmpty else { continue }
            corpus.pages.append(tokens)
            for word in SlideVocabulary.completionWords(from: tokens)
            where seen.insert(word.lowercased()).inserted {
                corpus.words.append(word)
            }
        }
        return corpus
    }

    private func vocabulary(ofPage page: Int) -> [String] {
        if let cached = vocabularyCache[page] { return cached }
        guard let pdf = document?.document, page >= 1, page <= pdf.pageCount,
              let text = pdf.page(at: page - 1)?.string else { return [] }
        let tokens = SlideVocabulary.tokens(in: text)
        vocabularyCache[page] = tokens
        return tokens
    }

    func forgetVocabulary() {
        vocabularyCache.removeAll()
        pageTextCache.removeAll()
    }

    func masks(forPage page: Int) -> [Mask] {
        guard let question = focusedQuestion, question.kind == .occlusion,
              question.occlusionPage == page else { return [] }
        return question.masks
    }

    /// The region the pointer is over, in either direction: hovering a
    /// rectangle on the slide lights up its row in the panel, and hovering a row
    /// lights up the rectangle. With regions grouped into cards, "which one is
    /// this?" stopped being answerable by looking -- every mask is the same
    /// navy block -- and this is the cheapest way to answer it.
    ///
    /// View state, like the text size. It is never written to a sidecar.
    @Published var hoveredMaskID: String?

    /// The group the hovered region belongs to, so its card-mates can be lit
    /// more faintly -- what shares a card is the thing you actually want to see.
    func hoveredMaskGroup() -> Int? {
        guard let hoveredMaskID, let question = focusedQuestion else { return nil }
        return question.masks.first { $0.id == hoveredMaskID }?.group
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
            // A new region gets a card of its own unless everything so far is
            // on one card, in which case it joins them -- the shape you are
            // working in carries on rather than being broken by the next drag.
            let group = question.isOneCard || question.masks.count == 1
                && question.occlusionMode == .allAtOnce
                ? (question.masks.first?.group ?? 1)
                : question.nextMaskGroup
            question.masks.append(Mask(rect: rect, group: group))
            question.occlusionMode = question.maskGroups.count == 1 ? .allAtOnce : .separate
        }
    }

    /// A region dragged or resized on the slide.
    ///
    /// The rectangle is part of the card's content hash, so this re-exports the
    /// card -- which is right: the picture genuinely changed. Grouping, the
    /// card it belongs to and its exported identity are all untouched, so a
    /// region you nudge keeps its review history.
    func setMaskRect(_ maskID: String, to rect: CropRect) {
        snapshot("resizing that region")
        mutateFocused { question in
            guard let index = question.masks.firstIndex(where: { $0.id == maskID }) else { return }
            question.masks[index].rect = rect
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

    /// How the regions are spread over cards, when it is one of the two shapes
    /// with a name. Nil for a grouping you built by hand.
    func maskGrouping(of question: Question) -> OcclusionMode? {
        guard question.masks.count > 1 else { return question.occlusionMode }
        if question.isOnePerCard { return .separate }
        if question.isOneCard { return .allAtOnce }
        return nil
    }

    /// Everything on one card, or a card each. Regroups what is already there,
    /// the same way the cloze bar does.
    func setOcclusionMode(_ mode: OcclusionMode) {
        // Undoable like every other mutator: this one changes how many cards the
        // question produces, which is the last thing you'd want stuck.
        snapshot("the reveal mode")
        mutateFocused { question in
            question.occlusionMode = mode
            for index in question.masks.indices {
                question.masks[index].group = mode == .allAtOnce ? 1 : index + 1
            }
        }
    }

    /// Move one region onto a different card. `group` of nil means a new one.
    func setMaskGroup(_ group: Int?, for maskID: String) {
        guard let question = focusedQuestion, question.kind == .occlusion else { return }
        let target = group ?? question.nextMaskGroup
        snapshot("moving that region")
        mutateFocused { question in
            guard let index = question.masks.firstIndex(where: { $0.id == maskID }) else { return }
            question.masks[index].group = target
            // Kept in step so the two single-group cases stay distinguishable,
            // which is what keeps their cards' GUIDs stable. See `noteVariants`.
            question.occlusionMode = question.maskGroups.count == 1 ? .allAtOnce : .separate
        }
    }

    /// What the panel promises before you export. Occlusion is the only thing in
    /// this app that can turn one question into a dozen cards, so it says so.
    var occlusionCardCount: Int {
        guard let question = focusedQuestion, question.kind == .occlusion else { return 0 }
        return max(1, question.maskGroups.count)
    }

    /// Committed by the crop overlay. Cropping a page the question doesn't yet
    /// cite attaches it first -- otherwise the drag would appear to do nothing,
    /// and "nothing happened" is the worst answer a gesture can give.
    /// `row` defaults to whatever is armed, which is what an ⌥-drag wants. The
    /// crop control passes its own row, so pressing it on the answer row can
    /// never put a crop on the question's slides.
    func setCrop(_ crop: CropRect, page: Int, row: ArmedRow? = nil) {
        let target = row ?? armedRow
        snapshot("that crop")
        mutateFocused { question in
            switch target {
            case .question:
                if !question.questionPages.contains(page) { question.questionPages.append(page) }
            case .answer:
                if !question.answerPages.contains(page) { question.answerPages.append(page) }
            }
            question.setCrop(crop, page: page, row: target)
        }
    }

    /// `row` defaults to whatever is armed, which is what ⌘E wants. The crop
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
    /// The thickness everything falls back to, and the one the slider is
    /// editing whenever a shape, a line or an arrow is in your hand.
    @Published var editLineWidth: Double = 2
    /// The pen and the highlighter each remember their own setting, because
    /// they are the two you go back and forth between: a 2pt pen and a 2pt
    /// highlighter are not both useful, and re-setting the slider on every
    /// switch is a tax on the tools you use most. nil means "still following
    /// the main thickness".
    @Published private(set) var penLineWidth: Double?
    @Published private(set) var highlighterLineWidth: Double?
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
    /// The markup inks, in spectrum order with the neutrals last.
    ///
    /// Muted rather than saturated, and all chosen to read on a white slide --
    /// these are drawn on the page, which stays light in both themes, so they
    /// are fixed values rather than palette ones. Graphite and white cover the
    /// two cases colour cannot: a figure already busy with colour, and a dark
    /// radiograph.
    enum InkColour: String, CaseIterable, Identifiable {
        case amber, orange, red, pink, purple, blue, teal, green, graphite, white

        var id: String { rawValue }

        var label: String {
            switch self {
            case .amber:    return "Amber"
            case .orange:   return "Orange"
            case .red:      return "Red"
            case .pink:     return "Pink"
            case .purple:   return "Purple"
            case .blue:     return "Blue"
            case .teal:     return "Teal"
            case .green:    return "Green"
            case .graphite: return "Graphite"
            case .white:    return "White"
            }
        }

        var nsColor: NSColor {
            switch self {
            case .amber:    return NSColor(red: 0.878, green: 0.627, blue: 0.227, alpha: 1)
            case .orange:   return NSColor(red: 0.851, green: 0.475, blue: 0.220, alpha: 1)
            case .red:      return NSColor(red: 0.710, green: 0.329, blue: 0.369, alpha: 1)
            case .pink:     return NSColor(red: 0.804, green: 0.404, blue: 0.573, alpha: 1)
            case .purple:   return NSColor(red: 0.549, green: 0.427, blue: 0.706, alpha: 1)
            case .blue:     return NSColor(red: 0.294, green: 0.478, blue: 0.749, alpha: 1)
            case .teal:     return NSColor(red: 0.216, green: 0.573, blue: 0.588, alpha: 1)
            case .green:    return NSColor(red: 0.243, green: 0.612, blue: 0.427, alpha: 1)
            case .graphite: return NSColor(red: 0.250, green: 0.243, blue: 0.227, alpha: 1)
            case .white:    return NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    var canEditPDF: Bool { document?.editableDocument != nil }
    var hasUnsavedPDFEdits: Bool { editSession?.hasUnsavedChanges == true }

    private var editSessionObserver: AnyCancellable?
    private var pendingPageRemap: [Int: Int] = [:]

    /// Rebuilds the editing session on whatever document is current.
    private func restartEditSession() {
        guard let lecture = document, let pdf = lecture.editableDocument else { return }
        let session = PDFEditSession(document: pdf, url: lecture.pdfURL)
        editSessionObserver = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        editSession = session
        pendingPageRemap = [:]
    }

    func startEditingPDF() {
        guard let lecture = document, let pdf = lecture.editableDocument else { return }
        // Start clean. Anything selected before the overlay went up is about to
        // become invisible, and an invisible selection is one a toolbar click
        // can mark without you knowing it was there.
        pdfBox.view.setCurrentSelection(nil, animate: false)
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
    /// Highlight, underline or strike through.
    ///
    /// Two meanings, decided by whether anything is selected. With text
    /// selected these are *verbs*: mark this, and give me back the tool I was
    /// holding. With nothing selected they are modes -- pick one up and drag
    /// over text to mark as you go.
    ///
    /// The tool used to change either way, which made the selected-text case
    /// cost two actions instead of none: mark the phrase, then put the pen back.
    /// Marking something you have already selected is not a decision to stop
    /// drawing.
    func applyTextMarkTool(_ tool: PDFEditing.Tool) {
        guard let mark = tool.textMark else {
            editTool = editTool == tool ? .select : tool
            return
        }
        // Only the pointer. A selection made with the pointer and marked in the
        // next breath is the case this is for; with a mark tool in hand you
        // select by dragging, and that marks on its own.
        //
        // The guard matters because `currentSelection` outlives what you can
        // see. It is a property of the PDF view, and while the markup overlay
        // is in front the view is not the one drawing selection highlights --
        // so a selection can sit there, invisible, long after you have moved on.
        // Clicking Highlight then marked all of it at once: a bar over the page
        // header, a strike through a line you had forgotten selecting, and a
        // second highlight straight over a first in the new colour.
        guard editTool == .select,
              let selection = pdfBox.view.currentSelection,
              selection.string?.isEmpty == false,
              let session = editSession else {
            editTool = editTool == tool ? .select : tool
            return
        }

        let made = PDFEditing.marks(for: selection, kind: mark, colour: editStroke.nsColor)
        guard !made.isEmpty else {
            // A selection PDFKit could make nothing of -- whitespace, an image.
            // Falling back to the mode is better than a click that does nothing.
            editTool = editTool == tool ? .select : tool
            return
        }

        let pages = session.pages
        session.perform("that \(mark.label.lowercased())",
                        undo: {
                            for (annotation, page) in made {
                                annotation.shouldDisplay = false
                                pages.remove(annotation, from: page)
                            }
                        },
                        redo: {
                            for (annotation, page) in made {
                                annotation.shouldDisplay = true
                                pages.add(annotation, to: page)
                            }
                        })
        // Cleared by hand, because `editTool` -- which normally does it -- is
        // deliberately left alone here.
        pdfBox.view.setCurrentSelection(nil, animate: false)
        repaintPDF()
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
            pdfWatcher.acknowledgeOwnWrite()
            pendingPageRemap = [:]
            statusMessage = "Saved your markup into \(lecture.pdfURL.finderName)."
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
    /// The text marks, Sketch and Select itself stay in your hand -- you
    /// highlight three things in a row, or draw three strokes, far more often
    /// than one.
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
            // A marked sentence recolours as one, and a highlight keeps the
            // transparency that lets you read the words under it.
            let family = session.selections.isEmpty ? [selection] : session.selections
            for entry in family {
                let wanted = PDFEditing.isTextMark(entry.annotation)
                    && PDFEditing.kind(of: entry.annotation) == "Highlight"
                    ? colour.nsColor.withAlphaComponent(0.38)
                    : colour.nsColor
                session.setColour(wanted, on: entry.annotation)
            }
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

    /// What the thickness slider is showing: the setting belonging to whatever
    /// is in your hand.
    var activeLineWidth: Double {
        switch editTool {
        case .pen:           return penLineWidth ?? editLineWidth
        case .freeHighlight: return highlighterLineWidth ?? editLineWidth
        default:             return editLineWidth
        }
    }

    /// The same setting in points, which is not the same number: a highlighter
    /// nib is wider than a pen at the same mark on the slider.
    var strokeWidth: Double {
        editTool == .freeHighlight
            ? activeLineWidth * Double(PDFEditing.highlighterScale)
            : activeLineWidth
    }

    /// Which thickness the slider writes to depends on what you are holding.
    /// With the pen or the highlighter up it writes to that implement alone;
    /// with anything else it writes the main thickness, and the main thickness
    /// is the one they both fall back to -- so setting it there puts the pen and
    /// the highlighter back on it too.
    func setEditLineWidth(_ width: Double) {
        switch editTool {
        case .pen:
            penLineWidth = width
        case .freeHighlight:
            highlighterLineWidth = width
        default:
            editLineWidth = width
            penLineWidth = nil
            highlighterLineWidth = nil
        }
        guard let session = editSession, let selection = session.selection,
              PDFEditing.kind(of: selection.annotation) != "FreeText" else { return }
        // The mark you have selected keeps its own nature: dragging the slider
        // with a highlighter stroke selected has to leave it a highlighter.
        let applied = PDFEditing.isHighlighter(selection.annotation)
            ? width * Double(PDFEditing.highlighterScale)
            : width
        session.setLineWidth(CGFloat(applied), on: selection.annotation)
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
        // The whole marked sentence when that is what is selected, not the one
        // line you happened to click.
        session.remove(session.selections.isEmpty ? [selection] : session.selections)
        repaintPDF()
    }

    var currentPageIsFlagged: Bool {
        document?.editableDocument?.page(at: currentPage - 1)?.annotations.contains(where: PDFEditing.isFlag) == true
    }

    /// Flag or unflag the slide you are on.
    ///
    /// Two paths, because flagging means two different things depending on what
    /// you are doing. Mid-markup it is one more edit: it joins the stack, ⌘Z
    /// takes it back, and it goes into the file when you press Save along with
    /// everything else.
    ///
    /// Reading, it is not an edit at all -- it is closer to ticking a box, and
    /// it used to drag the whole app into edit mode to do it. Two costs came
    /// with that: the tools appeared over the slide you were reading, and you
    /// were left holding unsaved changes the app would ask you about at quit,
    /// over a bookmark. So outside edit mode the session is opened, used and
    /// closed inside this one call, and the flag is in the PDF before your
    /// finger leaves the button. Clicking again is the undo.
    func togglePageFlag() {
        if isEditingPDF {
            guard let flagged = applyPageFlag() else { return }
            statusMessage = flagged
                ? "Flagged page \(currentPage)."
                : "Unflagged page \(currentPage)."
            return
        }

        startEditingPDF()
        guard isEditingPDF, let flagged = applyPageFlag() else { return }
        guard savePDFEdits() else {
            // `savePDFEdits` has already said what went wrong; discard so a
            // failed bookmark cannot strand the app in a mode nobody asked for.
            stopEditingPDF(discardingChanges: true)
            return
        }
        stopEditingPDF()
        // After the save, which sets a message about markup that nobody asked
        // for either.
        statusMessage = flagged
            ? "Flagged page \(currentPage)."
            : "Unflagged page \(currentPage)."
    }

    /// Puts the marker on or takes it off. Returns whether the page ended up
    /// flagged, or nil when there was no page to act on.
    @discardableResult
    private func applyPageFlag() -> Bool? {
        guard let session = editSession,
              let page = session.document.page(at: currentPage - 1) else { return nil }
        let wasFlagged = page.annotations.first(where: PDFEditing.isFlag)
        let pages = session.pages
        if let marker = wasFlagged {
            session.perform("unflagging page \(currentPage)",
                            undo: {
                                marker.shouldDisplay = true
                                pages.add(marker, to: page)
                            },
                            redo: {
                                marker.shouldDisplay = false
                                pages.remove(marker, from: page)
                            })
        } else {
            let marker = PDFEditing.flag(on: page)
            session.perform("flagging page \(currentPage)",
                            undo: {
                                marker.shouldDisplay = false
                                pages.remove(marker, from: page)
                            },
                            redo: {
                                marker.shouldDisplay = true
                                pages.add(marker, to: page)
                            })
        }
        repaintPDF()
        return wasFlagged == nil
    }

    // MARK: Page tags

    /// The labels the menu offers, from settings.
    var pageTags: [PageTagDefinition] { library?.settings.activePageTags ?? [] }

    /// What is already on the slide you are looking at. Read off the page
    /// rather than from a list, because the marks are in the PDF and the PDF is
    /// the record -- a tag put on from the iPad shows up here with no syncing.
    var tagsOnCurrentPage: Set<String> {
        guard let pdf = document?.editableDocument,
              let page = pdf.page(at: currentPage - 1) else { return [] }
        return Set(page.annotations.compactMap(PDFEditing.pageTagLabel))
    }

    /// Put a tag on this slide, or take it off. Same two paths as the flag:
    /// one more edit while you are marking up, a self-contained save while you
    /// are reading.
    func togglePageTag(_ label: String) {
        if isEditingPDF {
            guard let added = applyPageTag(label) else { return }
            statusMessage = added
                ? "Tagged page \(currentPage) \(label)."
                : "Removed \(label) from page \(currentPage)."
            return
        }

        startEditingPDF()
        guard isEditingPDF, let added = applyPageTag(label) else { return }
        guard savePDFEdits() else {
            stopEditingPDF(discardingChanges: true)
            return
        }
        stopEditingPDF()
        statusMessage = added
            ? "Tagged page \(currentPage) \(label)."
            : "Removed \(label) from page \(currentPage)."
    }

    /// Returns whether the tag ended up on the page, or nil if there was no
    /// page to act on.
    @discardableResult
    private func applyPageTag(_ label: String) -> Bool? {
        guard let session = editSession,
              let page = session.document.page(at: currentPage - 1) else { return nil }
        let existing = page.annotations.first { PDFEditing.pageTagLabel(of: $0) == label }
        let pages = session.pages
        // Re-laid out on both ends of every step, so taking the first of three
        // tags away closes the gap it leaves -- and undoing puts it back into
        // the row rather than on top of whatever moved up.
        let settle = { PDFEditing.placeTags(on: pages.resolve(page)) }
        if let tag = existing {
            session.perform("removing that tag",
                            undo: {
                                tag.shouldDisplay = true
                                pages.add(tag, to: page)
                                settle()
                            },
                            redo: {
                                tag.shouldDisplay = false
                                pages.remove(tag, from: page)
                                settle()
                            })
        } else {
            let tag = PDFEditing.pageTag(label, on: page)
            session.perform("tagging that page",
                            undo: {
                                tag.shouldDisplay = false
                                pages.remove(tag, from: page)
                                settle()
                            },
                            redo: {
                                tag.shouldDisplay = true
                                pages.add(tag, to: page)
                                settle()
                            })
        }
        repaintPDF()
        return existing == nil
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
                statusMessage = "Could not reopen \(lecture.pdfURL.finderName) after that change."
            } else {
                editTool = tool
            }
        }
    }

    private func summary(of change: PDFEditing.Change) -> String {
        let base = "Saved \(change.label) into \(document?.pdfURL.finderName ?? "the PDF")."
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
        let pages = session.pages
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
            undos.append { pages.setBounds(old, for: .cropBox, on: other) }
            redos.append { pages.setBounds(wanted, for: .cropBox, on: other) }
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

    /// How the deletions in one sentence are spread over cards.
    ///
    /// Two answers cover almost everything: every blank tested on its own, or
    /// all of them blanked at once. Anything else is a grouping you build by
    /// hand in the list, and this then reads `nil` -- there is no third mode to
    /// choose, only a shape you have already made.
    enum ClozeGrouping: String, CaseIterable, Identifiable {
        case separate
        case together

        var id: String { rawValue }

        var label: String {
            switch self {
            case .separate: return "Separate cards"
            case .together: return "One card"
            }
        }
    }

    /// What the next ⌘⇧C does. Session-scoped, like everything else here.
    @Published var clozeGrouping: ClozeGrouping = .separate

    /// How the deletions actually sit right now, or nil for a grouping you made
    /// by hand that is neither one thing nor the other.
    func actualClozeGrouping(of question: Question) -> ClozeGrouping? {
        let deletions = Cloze.deletions(in: question.front)
        guard deletions.count > 1 else { return deletions.isEmpty ? nil : clozeGrouping }
        let cards = Set(deletions.map(\.ordinal)).count
        if cards == deletions.count { return .separate }
        if cards == 1 { return .together }
        return nil
    }

    /// Wrap a range of the focused cloze question's text in `{{cN::…}}`.
    ///
    /// Returns false when the range is already inside a deletion -- nesting,
    /// which this app does not produce.
    /// `onCard` names the card this blank goes on. Nil takes the mode bar's
    /// answer -- a new card, or the one the others are already on.
    ///
    /// Naming the card at the moment you hide the words is the difference
    /// between three clicks and six for a sentence like "Protein A leads to
    /// inflammation, Protein B leads to growth", where the two proteins belong
    /// together and the two effects belong together. Making each blank and then
    /// moving it works, but you already knew where it went.
    @discardableResult
    func hideCloze(range: Range<String.Index>, onCard: Int? = nil) -> Bool {
        guard let question = focusedQuestion, question.kind == .cloze else { return false }
        // "One card" means this blank joins the others rather than starting a
        // card of its own, which is the whole difference between the two modes.
        let ordinal = onCard ?? (clozeGrouping == .together
            ? (Cloze.ordinals(in: question.front).min() ?? 1)
            : Cloze.nextOrdinal(in: question.front))
        guard let updated = Cloze.wrap(question.front, range: range,
                                       ordinal: max(1, ordinal)) else { return false }
        snapshot("hiding that")
        mutateFocused { $0.front = updated }
        return true
    }

    /// Flip the whole sentence between one card per blank and one card for all
    /// of them. It re-groups what is already there as well as setting what the
    /// next ⌘⇧C will do -- a switch that only affected the future would leave
    /// the label describing a shape you can see is not the shape on screen.
    func setClozeGrouping(_ mode: ClozeGrouping) {
        clozeGrouping = mode
        guard let question = focusedQuestion, question.kind == .cloze,
              Cloze.deletions(in: question.front).count > 1 else { return }
        snapshot(mode == .separate ? "splitting those onto their own cards"
                                   : "putting those on one card")
        mutateFocused { $0.front = Cloze.regrouped($0.front, separate: mode == .separate) }
    }

    /// Move one blank onto a different card. `ordinal` of nil means a new one.
    func setClozeCard(_ ordinal: Int?, forDeletionAt index: Int) {
        guard let question = focusedQuestion, question.kind == .cloze else { return }
        let target = ordinal ?? Cloze.nextOrdinal(in: question.front)
        snapshot("moving that blank")
        mutateFocused {
            $0.front = Cloze.compacted(Cloze.renumber($0.front, deletionAt: index, to: target))
        }
    }

    /// Stop hiding one phrase.
    func removeCloze(at index: Int) {
        guard let question = focusedQuestion, question.kind == .cloze else { return }
        snapshot("showing that again")
        mutateFocused { $0.front = Cloze.compacted(Cloze.unwrap($0.front, deletionAt: index)) }
    }

    /// The shapes with a tab right now: the ones you have switched on, plus any
    /// switched-off one this lecture still has cards for.
    ///
    /// A template you turn off stops being a way to write cards. It does not
    /// stop being the shape the cards you already wrote are in, and hiding
    /// their tab would leave them filed under Basic with their blanks gone --
    /// readable, but no longer the thing you wrote.
    var visibleTemplates: [Template] {
        var out = templates.active
        let present = Set((document?.questions ?? []).compactMap { matchedTemplateId(for: $0) })
        for template in templates.templates
        where !template.enabled && present.contains(template.id) {
            out.append(template)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether a tab will let you make something new in it.
    func canAddQuestions(to type: PanelType) -> Bool {
        guard let id = type.templateId else { return true }
        return templates.template(id: id)?.enabled ?? false
    }

    func cyclePanelType() {
        var order: [PanelType] = [.basic, .occlusion, .cloze]
        order.append(contentsOf: visibleTemplates.map { PanelType.template($0.id) })
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
    /// at Occlusion from Basic and the question row was still armed, so
    /// the first ⌘T went to a row that kind of card does not even show, and you
    /// had to click a row to fix it.
    func show(_ type: PanelType) {
        topicFilter = nil
        panelType = type
        // Nothing opens. Switching tabs is "show me these", not "put me back in
        // one of them" -- and the card it chose was the last one you happened to
        // write, which is rarely the one you came for. You arrive at the list.
        focusedQID = nil
        // Arm the row this kind of card uses, so the first ⌘E or ⌘T makes a
        // question and fills the right side of it.
        armedRow = (type.kind == .occlusion || type.kind == .cloze) ? .answer : .question
        if let template = templates.template(id: type.templateId),
           template.effectiveSlides == .back {
            armedRow = .answer
        }
        // The slide you are looking at, not any question's first slide.
        // Switching tabs is "make one of these about *this*"; jumping the page
        // away from what you were reading would be the opposite.
        anchorPage = currentPage
    }

    /// The page ⌘E would take if you pressed it now.
    /// ⌘E replaces the row with anchor…here, so the hint has to be true for
    /// every direction that can go, not only forwards. Showing it only when the
    /// current page is past the end meant ⌘E could silently *shrink* a range
    /// with nothing on screen to warn you.
    /// The slides already attached to whatever ⌘T is aimed at -- the armed row
    /// of the card you are editing, or the answer of the lecture question you
    /// have open. What the badges in the slide pane fill in.
    var armedPages: Set<Int> {
        guard let question = focusedQuestion else { return [] }
        return Set(armedRow == .question ? question.questionPages : question.answerPages)
    }

    var ghostPage: Int? {
        let pages: [Int]
        if let question = focusedQuestion {
            pages = armedRow == .question ? question.questionPages : question.answerPages
        } else {
            return nil
        }
        let next = PageSet.extend(from: anchorPage, to: currentPage)
        guard next != PageSet.normalise(pages) else { return nil }
        return currentPage
    }

    /// One bucket per tab, counted under whatever filter is on -- a tab reading
    /// zero has nothing in it *right now*, which is the question you are asking
    /// when you look at the row.
    func counts() -> [(label: String, count: Int, type: PanelType)] {
        var buckets: [PanelType: Int] = [:]
        for question in (document?.questions ?? []) where passesTagFilter(question) {
            buckets[tab(for: question), default: 0] += 1
        }
        var out: [(String, Int, PanelType)] = [
            ("Basic", buckets[.basic] ?? 0, .basic),
            ("Occlusion", buckets[.occlusion] ?? 0, .occlusion),
            ("Cloze", buckets[.cloze] ?? 0, .cloze)
        ]
        for template in visibleTemplates {
            out.append((template.name, buckets[.template(template.id)] ?? 0, .template(template.id)))
        }
        return out.map { (label: $0.0, count: $0.1, type: $0.2) }
    }
}
