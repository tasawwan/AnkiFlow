import SwiftUI
import AppKit

@main
struct AnkiFlowApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onAppear {
                    delegate.state = state
                    state.restoreLastLibrary()
                }
                .task {
                    // Quiet: once a day at most, and never from a dev build.
                    await state.updates.checkInBackground()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Launch alone is not "every day" for an app that stays open
                    // for a week. Coming back to the front counts too, and the
                    // 24-hour throttle still applies.
                    Task { await state.updates.checkInBackground() }
                }
                .alert(updateTitle, isPresented: $state.updates.showResult) {
                    if state.updates.available != nil {
                        // Bounced off this runloop turn: this alert has to
                        // finish dismissing before the confirmation alert can
                        // present, or the second one never appears.
                        Button("Update from Source") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                state.sourceUpdate.begin()
                            }
                        }
                        Button("Skip This Version") { state.updates.skipCurrentOffer() }
                        Button("Later", role: .cancel) { }
                    } else {
                        Button("OK", role: .cancel) { }
                    }
                } message: {
                    Text(updateMessage)
                }
                .alert(sourceUpdateTitle, isPresented: $state.sourceUpdate.showResult) {
                    if state.sourceUpdate.problem != nil {
                        // Bounced to the next runloop turn: running an open
                        // panel modally while the alert is still dismissing
                        // leaves the panel behind the window.
                        Button("Choose Folder…") {
                            DispatchQueue.main.async { state.sourceUpdate.locateCheckout() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } else {
                        Button("OK", role: .cancel) { }
                    }
                } message: {
                    Text(sourceUpdateMessage)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { menus }

        Settings {
            SettingsView().environmentObject(state)
        }

        // Separate windows, not sheets. A sheet raised from the Settings window
        // opens behind it; a window comes to the front where you can see it.
        // `.commandsRemoved()` keeps the windows but takes their entries out of
        // the Window menu. Each one is opened from where it belongs -- the
        // editor from Settings, About and Documentation from their own menus --
        // so listing them again under Window was three ways to reach the same
        // three windows.
        Window("Template Editor", id: WindowID.templateEditor) {
            TemplateEditorWindow().environmentObject(state)
        }
        .defaultSize(width: 900, height: 620)
        .commandsRemoved()

        Window("About AnkiFlow", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Documentation", id: WindowID.tutorial) {
            TutorialView()
        }
        .defaultSize(width: 820, height: 740)
        .commandsRemoved()
    }

    @CommandsBuilder
    private var menus: some Commands {
        // App menu. "Check for Updates…" belongs in the application menu just
        // below About -- where every Mac app puts it, and therefore the first
        // place anyone looks. Help is for documentation.
        //
        // There is no separate "Update from Source" item: rebuilding is only
        // ever worth doing when there is something new to rebuild, so it is
        // offered by the alert that just told you so.
        // Grouped only to stay under the ten-child limit a Commands builder
        // imposes, the same way the View menu's own contents are. No effect on
        // where anything appears.
        Group {
            CommandGroup(replacing: .appInfo) {
            Button("About AnkiFlow") { openWindow(WindowID.about) }

            Divider()

            Button(state.updates.isChecking ? "Checking…" : "Check for Updates…") {
                Task { await state.updates.checkNow() }
            }
            .disabled(state.updates.isChecking)
        }

        // Services is a system courtesy for apps that hand text to other apps.
        // This one hands you .apkg files; the submenu was noise in the menu that
        // carries the app's own name.
            CommandGroup(replacing: .systemServices) { }

        // File
            CommandGroup(replacing: .newItem) {
            // New Question is in the Question menu with the rest of the fast
            // path. Two menu entries for one key taught nobody anything.
            Button("Open Library…") { openLibraryPanel(state: state) }
                .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Reveal PDF in Finder") {
                guard let url = state.document?.pdfURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(state.document == nil)

            Divider()

            Button("Sort Questions by Slide") { state.sortQuestionsBySlides() }
                .disabled(state.document == nil)

            Button("Re-file Clinical Topics") { state.reclassifyClinicalTopics() }
                .disabled(state.library == nil)

            Divider()

            Button("Export Deck…") {
                state.document?.saveNow()
                state.showExportSheet = true
            }
            // ⌘D for Deck. ⌘E belongs to Extend, which is pressed hundreds of
            // times a session against Export's once.
            .keyboardShortcut("d", modifiers: .command)
            .disabled(state.library == nil)

            // The other direction. Deliberately not on the export sheet: an
            // export is something you do to Anki, and this is something Anki
            // did to you -- reading them as one command would make every export
            // a two-way operation you did not ask for.
            Button(syncMenuTitle(state)) {
                state.document?.saveNow()
                state.showSyncSheet = true
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(state.library == nil)
        }

        // There is no Save command: the app autosaves and has no unsaved state,
        // so the key is left unbound rather than given a job to justify it.
            CommandGroup(replacing: .saveItem) { }

        // One Undo, two stacks. While the markup bar is up ⌘Z takes back the
        // last mark; the rest of the time it takes back the last thing you did
        // to your questions. Two separate shortcuts would mean remembering
        // which one you were in.
        // One Undo, on the key every Mac app uses. It aims at whichever stack is
        // in play: the markup bar's while that is up, the note's own typing
        // history while the caret is in a note -- the text view claims ⌘Z for
        // itself there -- and otherwise the questions.
        //
        // ⌘U is not undo. It was, briefly, as a workaround; it is the underline
        // key on this platform and it is spent that way now, on PDF markup here
        // and on note text inside the notes editor.
            CommandGroup(replacing: .undoRedo) {
            Button(state.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                if state.isEditingPDF { state.undoEdit() } else { state.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!state.canUndo)

            Button(state.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                if state.isEditingPDF { state.redoEdit() } else { state.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!state.canRedo)

            Divider()

            Button("Underline") { state.toggleEditUnderline() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!state.isEditingPDF)
        }

        // Find lives in Edit, where everyone already looks for it. It searches
        // the PDF rather than your questions: finding the slide that mentions a
        // term is what you do while writing a question about it.
        }

        // Not `pasteAsPlainText:`, which was the first attempt and did nothing
        // here: SwiftUI's multi-line TextField is not an AppKit field editor, so
        // that responder action found nobody to answer it. And dropping the
        // styling was never the point -- text copied out of a PDF arrives
        // wrapped at the slide's line width, and it is those line breaks you
        // want gone. See PasteCleaner.
        CommandGroup(after: .pasteboard) {
            Button("Paste Without Formatting") { PasteCleaner.pasteReflowed() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Divider()
            // Two axes, one letter. ⌘ is slides, ⌥ is questions; adding ⇧ or ⌘
            // widens from this lecture to the whole library. Once you know the
            // shape you never have to remember four separate keys.
            Button("Find Slides in Lecture…") { state.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(state.document == nil)
            Button("Find Next") { state.stepFind(1) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(state.findMatchCount == 0)

            Button("Find Slides in Library…") { state.openSearch(.librarySlides) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state.library == nil)

            Divider()

            Button("Find Questions in Library…") { state.openSearch(.libraryQuestions) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(state.library == nil)
        }

        // View
        CommandGroup(after: .toolbar) {
            // Grouped only to stay under the ten-child limit a ViewBuilder
            // imposes. No effect on the menu.
            Group {
                Button("Toggle Sidebar") { state.showSidebar.toggle() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Toggle Slide Gallery") { state.showThumbnails.toggle() }
                    .keyboardShortcut("2", modifiers: .command)
                Button(state.showFlaggedPagesOnly ? "Show All Pages" : "Show Flagged Pages Only") {
                    state.toggleFlaggedPagesOnly()
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(state.document == nil || state.flaggedPages.isEmpty)
                Button(state.showNotes ? "Hide Notes" : "Show Notes") { state.showNotes.toggle() }
                    .keyboardShortcut("4", modifiers: .command)
                Button(state.showUncoveredPagesOnly
                       ? "Show All Pages" : "Show Slides With No Question") {
                    state.showUncoveredPagesOnly.toggle()
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(state.document == nil)
            }

            Divider()

            Group {
                Button("Next Page") { state.nextPage() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Page") { state.previousPage() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                // A submenu rather than a shortcut each: the list is yours to
                // grow, so there is no fixed set of keys to hand out. A tick
                // means the slide already carries it, and choosing it again
                // takes it off.
                Menu("Tag This Slide") {
                    ForEach(state.pageTags) { tag in
                        let carried = state.tagsOnCurrentPage.contains(tag.label)
                        Button(carried ? "\(tag.label) ✓" : tag.label) {
                            state.togglePageTag(tag.label)
                        }
                    }
                }
                .disabled(state.document == nil || state.pageTags.isEmpty)
            }

            Divider()

            // Text size for the notes. Bound to "=" as well as "+", because ⌘+
            // on most keyboards is really ⌘⇧= and the unshifted key is the one
            // that actually arrives; the menu still draws it as ⌘+.
            // Bound to "=" rather than "+", which is the key actually pressed:
            // ⌘+ is ⌘⇧= on most layouts, so a shortcut declared as "+" only
            // fires with shift held. The menu draws ⌘= and everyone reads it as
            // "bigger" anyway. A second, hidden item for the other spelling was
            // worse than useless -- a hidden menu item registers no shortcut.
            Group {
                Button("Bigger Text") { state.changeTextSize(.bigger) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Smaller Text") { state.changeTextSize(.smaller) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { state.changeTextSize(.reset) }
                    .keyboardShortcut("0", modifiers: .command)
            }

            Divider()

            Button("Cycle Card Type") { state.cyclePanelType() }
                .keyboardShortcut("y", modifiers: .command)

            Divider()

            // ⌘P for Preview, not Print: nothing here gets printed, and looking
            // at your cards is a way of viewing them, not a file operation.
            Button("Preview Cards…") { state.openPreview() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(state.library == nil)
        }

        CommandMenu("Question") {
            Button("New Question") { state.newQuestion() }
                .keyboardShortcut("n", modifiers: .command)

            Button("Commit Question") { state.commitAndAdvance() }
                .keyboardShortcut(.return, modifiers: .command)

            Divider()

            Button("Extend to This Page") { state.extendToCurrentPage() }
                .keyboardShortcut("e", modifiers: .command)

            Button("Toggle This Page") { state.toggleCurrentPage() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Re-anchor Here") { state.setAnchorToCurrentPage() }
                .keyboardShortcut("r", modifiers: .command)

            // No shortcut: ⌘Z is Undo, and undoing a crop is what that key
            // is for. This stays in the menu for removing an older crop you have
            // since typed past.
            Button("Uncrop This Page") { state.clearCrop(page: state.currentPage) }
                .disabled(!state.currentPageHasCrop)


            Divider()

            Button("Delete Question") { state.deleteFocusedQuestion() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.focusedQID == nil)
        }

        // PDF -- the only menu in the app that writes to your lecture file.
        // Kept separate from Question for exactly that reason: nothing in here
        // is part of making a card, and nothing here happens by accident.
        CommandMenu("PDF") {
            Button(state.isEditingPDF ? "Stop Editing PDF" : "Edit PDF…") {
                if state.isEditingPDF { state.stopEditingPDF() } else { state.startEditingPDF() }
            }
            .disabled(!state.canEditPDF)

            Button("Save Marks into PDF") { state.savePDFEdits() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.hasUnsavedPDFEdits)

            Divider()

            // Grouped, not laid out flat: a ViewBuilder takes at most ten
            // children, and this menu has more than that.
            Group {
                Button("Highlight") { state.applyTextMarkTool(.highlight) }
                Button("Underline") { state.applyTextMarkTool(.underline) }
                Button("Strike Through") { state.applyTextMarkTool(.strikeOut) }
                Button("Delete Selected Mark") { state.deleteSelectedMark() }
                Button("Bold Text") { state.toggleEditBold() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italicize Text") { state.toggleEditItalic() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            .disabled(!state.isEditingPDF)

            Divider()

            Group {
                Button("Rotate Slide Right") { state.rotateCurrentPage(by: 90) }
                Button("Rotate Slide Left") { state.rotateCurrentPage(by: -90) }
                Button("Insert Slides…") { insertPagesPanel(state: state) }
                Button("Delete This Slide…") { state.confirmingPageDelete = true }
                Button("Trim Every Slide Like This One") { state.trimAllSlidesLikeThisOne() }
            }
            .disabled(!state.canEditPDF)
        }

        CommandGroup(replacing: .help) {
            Button("Documentation") { openWindow(WindowID.tutorial) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private var updateTitle: String {
        if state.updates.lastError != nil { return "Couldn't check for updates" }
        return state.updates.available == nil ? "You're up to date" : "Update available"
    }

    private var updateMessage: String {
        if let error = state.updates.lastError { return error }
        guard let release = state.updates.available else {
            let version = state.updates.currentVersion
            return version.map { "AnkiFlow \($0) is the latest version." }
                ?? "Running from source, so there's no version to compare."
        }
        let name = release.name ?? "AnkiFlow \(release.version)"
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = notes.isEmpty ? "" : "\n\n" + String(notes.prefix(400))
        return "\(name) is available. You have \(state.updates.currentVersion ?? "an unknown version").\(summary)"
    }

    private var sourceUpdateTitle: String {
        state.sourceUpdate.problem == nil ? "Command copied" : "That isn't the source folder"
    }

    private var sourceUpdateMessage: String {
        if let problem = state.sourceUpdate.problem { return problem }
        guard let command = state.sourceUpdate.copiedCommand else { return "" }
        return """
        Terminal is open in your AnkiFlow folder. Paste and press Return:

        \(command)

        The rebuild quits AnkiFlow and reopens it when it finishes.
        """
    }

    /// SwiftUI's `openWindow` is only available from a view's environment, so
    /// menu actions go through AppKit's URL-free equivalent.
    private func openWindow(_ id: String) {
        WindowOpener.open(id)
    }
}

enum WindowID {
    static let templateEditor = "template-editor"
    static let about = "about"
    static let tutorial = "tutorial"
}

/// Bridges menu commands to SwiftUI's window scenes.
///
/// `@Environment(\.openWindow)` isn't reachable from `@CommandsBuilder`, so a
/// hidden view holds the action and menu items call through here.
@MainActor
enum WindowOpener {
    static var handler: ((String) -> Void)?

    static func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        handler?(id)
    }
}

/// Invisible, but it's what gives WindowOpener something to call.
struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowOpener.handler = { id in openWindow(id: id) }
            }
    }
}

/// Two jobs: make the process behave like a real app when run via `swift run`
/// (no bundle, so it has to ask for a Dock icon and a menu bar), and flush
/// pending edits on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Markup is the one kind of edit in this app that is not written as you go.
    /// Everything else autosaves; marks on a slide wait for the Save button
    /// deliberately, so that trying things out on a lecture PDF is safe. The
    /// cost of that choice is that quitting is the moment it can all be thrown
    /// away silently, which is what this stops.
    ///
    /// Asked here rather than by watching the window close: Quit does not close
    /// windows first, it terminates, so a check hung off the window would never
    /// run.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.hasUnsavedPDFEdits else { return .terminateNow }

        let name = state.document?.pdfURL.finderName ?? "this lecture"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save your markup into \(name)?"
        alert.informativeText = "You have marks on the slides that have not been written into the PDF yet. Quitting without saving throws them away."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Only leave if the write actually worked. A failed save that quit
            // anyway would lose the marks and claim it had saved them.
            return state.savePDFEdits() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            state.stopEditingPDF(discardingChanges: true)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.discardEmptyFocusedQuestion()
        state?.document?.saveNow()
        // Notes autosave on a debounce, so quitting mid-sentence would drop the
        // last second or so of typing without this.
        state?.notes?.saveNow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        state?.discardEmptyFocusedQuestion()
        state?.document?.saveNow()
        state?.notes?.saveNow()
    }
}

/// "Changes in Anki… (3)" when the background poll has found things waiting on
/// a decision. A count in a menu is the quietest way to say so: nothing
/// interrupts you, and the number is there when you go looking.
@MainActor
private func syncMenuTitle(_ state: AppState) -> String {
    guard let pending = state.pendingSync else { return "Changes in Anki…" }
    let waiting = pending.edits.count + pending.deletions.count
    return waiting == 0 ? "Changes in Anki…" : "Changes in Anki… (\(waiting))"
}
