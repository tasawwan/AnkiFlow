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

            // ⌘D for Deck. ⌘E belongs to Extend, which is pressed hundreds of
            // times a session against Export's once.
            Button("Export Deck…") {
                state.document?.saveNow()
                state.showExportSheet = true
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(state.library == nil)
        }

        // There is no Save command: the app autosaves and has no unsaved state,
        // so the key is left unbound rather than given a job to justify it.
        CommandGroup(replacing: .saveItem) { }

        // ⌘U. SwiftUI's own Undo item only reaches a focused text field's undo
        // manager, so every structural change -- attaching slides, cropping,
        // masks, deleting a question -- had no undo at all. This one asks the
        // text field first and falls back to the app's own stack, which is what
        // ⌘U is expected to mean in both places.
        CommandGroup(replacing: .undoRedo) {
            Button(state.undoLabel.map { "Undo \($0)" } ?? "Undo") { state.undo() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!state.canUndo)
            Button(state.redoLabel.map { "Redo \($0)" } ?? "Redo") { state.redo() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
        }

        // Find lives in Edit, where everyone already looks for it. It searches
        // the PDF rather than your questions: finding the slide that mentions a
        // term is what you do while writing a question about it.
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

            Button("Find Questions in Lecture…") { state.openSearch(.lectureQuestions) }
                .keyboardShortcut("f", modifiers: .option)
                .disabled(state.document == nil)

            Button("Find Questions in Library…") { state.openSearch(.libraryQuestions) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(state.library == nil)
        }

        // View
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { state.showSidebar.toggle() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Toggle Slide Gallery") { state.showThumbnails.toggle() }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Next Page") { state.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Page") { state.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
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

        // Question -- every gesture on the fast path, with its key printed
        // beside it. This menu is how you relearn the bindings after a month off.
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

            // No shortcut: ⌘U is Undo now, and undoing a crop is what that key
            // is for. This stays in the menu for removing an older crop you have
            // since typed past.
            Button("Uncrop This Page") { state.clearCrop(page: state.currentPage) }
                .disabled(!state.currentPageHasCrop)


            Divider()

            Button("Add Written Answer") { state.revealBackField.toggle() }
                .keyboardShortcut("b", modifiers: .command)

            Button("Delete Question") { state.deleteFocusedQuestion() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.focusedQID == nil)
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

    func applicationWillTerminate(_ notification: Notification) {
        state?.document?.saveNow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        state?.document?.saveNow()
    }
}
