import SwiftUI
import AppKit
import PDFKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    var body: some View {
        HSplitView {
            if state.showSidebar {
                SidebarView()
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 340, maxHeight: .infinity)
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
                    ThumbnailStrip(box: state.pdfBox)
                        .frame(height: 92)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(palette.field)
                }
            }
            // The PDF gets 55% of the default window: 792 of 1440, with the
            // sidebar and the panel taking 230 and 418. HSplitView lays out from
            // these ideals and then remembers wherever you drag the dividers.
            .frame(minWidth: 460, idealWidth: 792, maxWidth: .infinity, maxHeight: .infinity)

            QuestionPanel()
                .frame(minWidth: 360, idealWidth: 418, maxWidth: 660, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 1100, minHeight: 700)
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
                             cacheDirectory: LibraryPaths.cacheDirectory(inLibrary: library.root))
                    .environmentObject(state)
                    .environment(\.palette, palette)
            }
        }
        .sheet(isPresented: $state.showSearchSheet) {
            SearchSheet()
                .environmentObject(state)
                .environment(\.palette, palette)
        }
        .background(WindowOpenerBridge())
    }

    /// Things the document needs to tell you about the file underneath it.
    /// A renumbering prompt is the important one: it is the difference between
    /// noticing an inserted slide and finding out weeks later in Anki.
    @ViewBuilder
    private var noticeBar: some View {
        if let message = state.statusMessage {
            HStack(spacing: 10) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink2)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.line).frame(height: 1)
            }
            .task(id: message) {
                // Transient: it reports something that already happened, so it
                // shouldn't sit there for the rest of the session.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                state.statusMessage = nil
            }
        }
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
            } else if let notice = document.notice {
                HStack(spacing: 10) {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.line).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private var pdfArea: some View {
        if let document = state.document?.document {
            VStack(spacing: 0) {
                if state.findVisible {
                    FindBar()
                }
                PDFPane(box: state.pdfBox,
                        document: document,
                        currentPage: $state.currentPage,
                        cropForPage: { state.crop(forPage: $0) },
                        masksForPage: { state.masks(forPage: $0) },
                        onCrop: { page, rect in state.regionDragged(rect, page: page) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
