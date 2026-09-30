import SwiftUI
import AppKit
import PDFKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    var body: some View {
        HSplitView {
            if state.showSidebar {
                // Wide enough for the topic panel's header: the label, the
                // three-way scope control and the re-sort button sit on one
                // row, and below this they start eating each other.
                SidebarView()
                    .frame(minWidth: 272, idealWidth: 292, maxWidth: 360, maxHeight: .infinity)
            }

            VStack(spacing: 0) {
                // Above the PDF area, not inside it. Nested in there it only
                // appeared once a PDF had loaded -- so a file-operation error,
                // or the warning that a lecture's questions can't be read, was
                // invisible in exactly the cases that produce it.
                noticeBar
                pdfArea
                if state.showThumbnails {
                    Divider().overlay(palette.line)
                    ThumbnailStrip(box: state.pdfBox, currentPage: $state.currentPage,
                                   showFlaggedOnly: state.showFlaggedPagesOnly,
                                   showUncoveredOnly: state.showUncoveredPagesOnly,
                                   uncoveredPages: state.uncoveredPages) { source, destination in
                        state.movePage(from: source, to: destination)
                    }
                    .id("\(state.showFlaggedPagesOnly)-\(state.showUncoveredPagesOnly)")
                        .frame(height: 92)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(palette.field)
                }
            }
            // The library sidebar starts compact so the PDF toolbar has room for
            // its editing controls. HSplitView lays out from these ideals and
            // remembers wherever you drag the dividers.
            .frame(minWidth: 760, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)

            // Questions above, notes below, on a divider you can drag. A
            // VSplitView rather than a fixed height because how much of the
            // panel notes deserve depends entirely on the lecture.
            VSplitView {
                QuestionPanel()
                    .frame(minHeight: 220, maxHeight: .infinity)
                if state.showNotes, let notes = state.notes {
                    NotesPane(notes: notes)
                        .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, idealWidth: 418, maxWidth: 660, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The three panes stacked on the right need 470pt between them before
        // anything is squeezed, and the sidebar and the question header each
        // have a row of controls with a real minimum width. Sized so nothing
        // has to be dragged open before it can be used.
        .frame(minWidth: 1420, minHeight: 820)
        .background(palette.panel)
        .toolbarBackground(palette.chrome, for: .windowToolbar)
        // The window's own title, not a toolbar item. A `.principal` item is
        // laid out inside a fixed-width capsule, so a long lecture name spills
        // straight out of it; the real title bar truncates properly and gets
        // the document-name behaviours (proxy icon, ⌘-click path menu) free.
        .navigationTitle(state.document?.title ?? "AnkiFlow")
        .navigationSubtitle(pageIndicator)
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.showExportSheet) {
            ExportSheet().environment(\.palette, palette)
        }
        .task { await state.autoSyncLoop() }
        .sheet(isPresented: $state.showSyncSheet) {
            SyncSheet().environmentObject(state)
        }
        .sheet(isPresented: $state.showPageShift) {
            if let document = state.document, let shift = document.pendingShift {
                PageShiftSheet(shift: shift, pageCount: document.pageCount)
                    .environmentObject(state)
                    .environment(\.palette, palette)
            }
        }
        .sheet(isPresented: $state.showRecovery) {
            RecoverySheet()
                .environmentObject(state)
                .environment(\.palette, palette)
        }
        .sheet(isPresented: $state.showPreview) {
            if let library = state.library {
                PreviewSheet(settings: library.settings,
                             cacheDirectory: AppPaths.cacheDirectory)
                    .environmentObject(state)
                    .environment(\.palette, palette)
            }
        }
        .sheet(isPresented: $state.showSearchSheet) {
            SearchSheet()
                .environmentObject(state)
                .environment(\.palette, palette)
        }
        .alert("Save your marks first?", isPresented: $state.confirmingDiscardEdits) {
            // Only leave if the write actually succeeded -- a failed save that
            // closed editing anyway would drop the marks it just failed to keep.
            Button("Save") { if state.savePDFEdits() { state.stopEditingPDF() } }
            Button("Discard", role: .destructive) { state.stopEditingPDF(discardingChanges: true) }
            Button("Keep Editing", role: .cancel) { state.confirmingDiscardEdits = false }
        } message: {
            Text("You've marked up this PDF but haven't saved it. Discarding throws those marks away.")
        }
        .alert("Delete slide \(state.currentPage)?", isPresented: $state.confirmingPageDelete) {
            Button("Delete Slide", role: .destructive) { state.deleteCurrentPage() }
            Button("Cancel", role: .cancel) { state.confirmingPageDelete = false }
        } message: {
            // The only edit in this app that asks. Everything else here can be
            // put back by doing the opposite; a deleted page is gone from the
            // file, and ⌘Z cannot bring it back.
            Text("This removes the page from \(state.document?.pdfURL.finderName ?? "the PDF") itself. Undo can't bring it back, and any question pointing at it will lose that slide.")
        }
        .background(WindowOpenerBridge())
    }

    /// Things the document needs to tell you about the file underneath it.
    /// A renumbering prompt is the important one: it is the difference between
    /// noticing an inserted slide and finding out weeks later in Anki.
    @ViewBuilder
    private var noticeBar: some View {
        if let document = state.document {
            if let problem = document.loadError {
                // This one blocks every save until the file is readable, so it
                // cannot be a quiet log line: without it you would see a lecture
                // with no questions and no reason, and every edit you made would
                // be discarded.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.retired)
                    Text(problem + " Nothing will be saved for this lecture until that file can be read.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([document.sidecarURL])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.retired.opacity(0.12))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.line).frame(height: 1)
                }
            } else if let shift = document.pendingShift {
                // No dismiss. Every question in this lecture is pointing
                // somewhere, and letting this be waved away leaves them pointing
                // at the wrong slides with nothing on screen to say so.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.amber)
                    Text(shift.headline)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Fix slide numbers…") { state.showPageShift = true }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(palette.amber.opacity(0.10))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.line).frame(height: 1)
                }
            }
        }
    }

    /// One line under the toolbar for everything the app has to say about this
    /// lecture: what changed about the PDF since you last opened it, and what
    /// every action you take just did -- undo and redo included, whichever of
    /// the four stacks answered.
    ///
    /// One bar rather than two, because two meant two places to look for the
    /// same kind of information, and which one a message landed in depended on
    /// implementation detail nobody using the app can see. The notice about the
    /// file is sticky and dismissible; everything else fades on its own.
    ///
    /// The unreadable-question-file error and the slide-numbers warning stay
    /// above the toolbar rather than joining this: they must appear when there
    /// is no PDF on screen to put a toolbar over.
    private var messageBar: some View {
        let notice = state.document?.loadError == nil
            && state.document?.pendingShift == nil ? state.document?.notice : nil
        let message = notice ?? state.statusMessage
        return HStack(spacing: 9) {
            if message != nil {
                Image(systemName: notice != nil ? "info.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if notice != nil {
                Button("Dismiss") { state.document?.dismissNotice() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 29)
        .background(palette.surface.opacity(message == nil ? 0 : 1))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line.opacity(message == nil ? 0 : 1)).frame(height: 1)
        }
        .task(id: state.statusMessage) {
            guard state.statusMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            state.statusMessage = nil
        }
    }

    @ViewBuilder
    private var pdfArea: some View {
        if let document = state.document?.document {
            VStack(spacing: 0) {
                // Always present: collapsed it is just the Edit PDF button,
                // expanded it is the tools. One row either way, so turning
                // editing on doesn't shove the page down.
                PDFEditBar()
                if state.findVisible {
                    FindBar()
                }
                // Lives here rather than above the PDF pane so it slides in
                // below the toolbar instead of pushing it down.
                messageBar
                PDFPane(box: state.pdfBox,
                        document: document,
                        reloadToken: state.pdfReloadToken,
                        currentPage: $state.currentPage,
                        armedPages: state.armedPages,
                        cropForPage: { state.crop(forPage: $0) },
                        masksForPage: { state.masks(forPage: $0) },
                        hoveredMaskID: state.hoveredMaskID,
                        hoveredMaskGroup: state.hoveredMaskGroup(),
                        uncoveredPages: state.uncoveredPages,
                        isCropping: state.isCropping,
                        onHoverMask: { state.hoveredMaskID = $0 },
                        onMaskChanged: { state.setMaskRect($0, to: $1) },
                        onCrop: { page, rect in state.regionDragged(rect, page: page) },
                        session: state.editSession,
                        editTool: state.isEditingPDF ? state.editTool : nil,
                        strokeColour: state.editStroke.nsColor,
                        fillColour: state.editFill?.nsColor,
                        editLineWidth: state.strokeWidth,
                        editFontSize: state.editFontSize,
                        editBold: state.editBold,
                        editItalic: state.editItalic,
                        editUnderline: state.editUnderline,
                        findAnnotationHighlight: state.findAnnotationHighlight,
                        onToolUsed: { state.toolWasUsed() },
                        onMessage: { state.statusMessage = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Through the responder chain, so a focused find bar or page-range
            // field gets Esc first and only an unhandled one leaves edit mode.
            .onExitCommand {
                if state.isEditingPDF { state.stopEditingPDF() }
            }
        } else {
            ZStack {
                palette.field
                VStack(spacing: 10) {
                    Text(state.library == nil ? "No library open" : "No lecture selected")
                        .font(AppFont.question(19))
                        .foregroundStyle(palette.ink)
                    Text(state.library == nil
                         ? "File ▸ Open Library… (⌘O) and pick the folder your lecture PDFs live in."
                         : "Pick a lecture in the sidebar.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.dim)
                }
                .multilineTextAlignment(.center)
                .padding(40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageIndicator: String {
        guard let document = state.document, document.pageCount > 0 else { return "" }
        return "\(state.currentPage) of \(document.pageCount)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Toggle sidebar (⌘1)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                state.document?.saveNow()
                state.showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(state.library == nil)
            .help("Export deck (⌘D)")
        }
    }
}
