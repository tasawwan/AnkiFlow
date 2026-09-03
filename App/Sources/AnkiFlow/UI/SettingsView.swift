import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            AppearanceSettings().pane().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            TagSettings().pane().tabItem { Label("Tags", systemImage: "tag") }
            RenderingSettings().pane().tabItem { Label("Rendering", systemImage: "photo") }
            ExportSettings().pane().tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            KeyboardSettings().pane().tabItem { Label("Keyboard", systemImage: "keyboard") }
            TemplateSettings().pane().tabItem { Label("Templates", systemImage: "doc.text") }
        }
        .environmentObject(state)
    }
}

private extension View {
    /// Every pane the same size.
    ///
    /// A frame on the TabView alone doesn't hold: macOS sizes the Settings
    /// window to its content, and a pane whose text has no width to wrap
    /// against reports an ideal width of most of the screen — which is why the
    /// window grew when you clicked Templates. Constraining each pane fixes the
    /// measurement at the source, and switching tabs stops moving the window.
    func pane() -> some View {
        frame(width: 600, height: 470, alignment: .topLeading)
    }
}

// MARK: - Appearance

/// Two skins, same structure. Light is Editorial — warm paper and ink. Dark is
/// Studio — navy chrome with the slide floating on near-black, so the page is
/// the only lit thing on screen.
struct AppearanceSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(
                get: { state.appearance },
                set: { state.appearance = $0 }
            )) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)

            Section {
                Text("**Editorial (light)** — warm paper, ink, hairline borders. Quiet enough to sit in for an hour.")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text("**Studio (dark)** — navy chrome and a near-black field, so a white slide reads like a lightbox. Better at night; brighter contrast against the page.")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only the colours change. Question cards, rows and layout are identical either way.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}

// MARK: - Tags

/// Which tags get a permanent checkbox in the question panel.
struct TagSettings: View {
    @EnvironmentObject var state: AppState
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned tags get a checkbox at the bottom of the question panel, always visible. Unpinned ones live behind the tag button.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let library = state.library {
                List {
                    ForEach(Array(library.settings.tags.enumerated()), id: \.element.id) { index, tag in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { library.settings.tags[index].pinned },
                                set: { library.settings.tags[index].pinned = $0 }
                            ))
                            .labelsHidden()
                            .help("Always show a checkbox for this tag")

                            TextField("", text: Binding(
                                get: { library.settings.tags[index].name },
                                set: { library.settings.tags[index].name = $0.replacingOccurrences(of: " ", with: "-") }
                            ))
                            .textFieldStyle(.plain)

                            Spacer()

                            Button {
                                library.settings.tags.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .onMove { source, destination in
                        library.settings.tags.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .frame(minHeight: 200)

                HStack {
                    TextField("New tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Drag to reorder — that's the order the checkboxes appear in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Open a library first — tags are per library.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func add() {
        let name = newTag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, let library = state.library,
              !library.settings.tags.contains(where: { $0.name == name }) else { return }
        library.settings.tags.append(TagDefinition(name: name, pinned: true))
        newTag = ""
    }
}

// MARK: - Rendering

struct RenderingSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            if let library = state.library {
                Picker("Slide width", selection: Binding(
                    get: { library.settings.imageWidth },
                    set: { library.settings.imageWidth = $0; library.settings.renderVersion += 1 }
                )) {
                    Text("1200 px — smaller collection").tag(1200)
                    Text("1600 px — recommended").tag(1600)
                    Text("2000 px — dense diagrams").tag(2000)
                }

                Picker("Format", selection: Binding(
                    get: { library.settings.imageFormat },
                    set: { library.settings.imageFormat = $0; library.settings.renderVersion += 1 }
                )) {
                    ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                }

                Text(PageRenderer.webPSupported
                     ? "Auto uses WebP on this Mac — roughly a third the size of JPEG for lecture slides."
                     : "This macOS version can't encode WebP, so Auto uses JPEG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                let renderer = PageRenderer(
                    cacheDirectory: LibraryPaths.cacheDirectory(inLibrary: library.root),
                    settings: library.settings
                )
                LabeledContent("Cache") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: renderer.cacheSizeInBytes(), countStyle: .file))
                        Button("Clear") { renderer.clearCache() }
                            .controlSize(.small)
                    }
                }

                Text("A 60-slide lecture is roughly 5–6 MB of images. Changing width or format re-renders everything on the next export.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open a library first.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}

// MARK: - Export

struct ExportSettings: View {
    @EnvironmentObject var state: AppState

    /// How many questions Anki already knows about. Renaming the root after
    /// this point splits the collection, so the warning is worth earning.
    private var exportedCount: Int {
        (state.document?.questions ?? []).filter { $0.export != nil }.count
    }

    var body: some View {
        Form {
            if let library = state.library {
                Toggle("Reveal the .apkg in Finder after exporting", isOn: Binding(
                    get: { library.settings.revealAfterExport },
                    set: { library.settings.revealAfterExport = $0 }
                ))
            }

            Section("Deck root") {
                if let library = state.library {
                    TextField("Deck root", text: Binding(
                        get: { library.settings.deckRoot },
                        set: { library.settings.deckRoot = $0 }
                    ))
                    LabeledContent("Decks will be named",
                                   value: "\(library.settings.resolvedDeckRoot)::Anatomy::Lecture 04")

                    if exportedCount > 0 {
                        Label("\(exportedCount) question\(exportedCount == 1 ? " has" : "s have") already been exported.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.78, green: 0.55, blue: 0.20))
                        Text("Anki never moves existing cards between decks on import. Rename the root now and your studied cards stay in the old tree while new ones go to the new one — your collection ends up split. If you want them together you'd rename the parent deck in Anki yourself, which takes ten seconds and is the tidier fix.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Nothing exported yet, so this is free to change. Per library, so different courses can use different roots.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Open a library first.").foregroundStyle(.secondary)
                }
            }

            Section("Export history") {
                Text("Each lecture keeps its own record — which deck it last exported to, and which of its questions you have since deleted — inside its question file. There's no central database, because a question belongs to one PDF and cites that PDF's pages, so it can't move to another lecture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("To clear it, use **Export history** in the export sheet (⌘D), where you can pick a lecture, a folder, or the whole library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Question files") {
                if let library = state.library {
                    Toggle("Hide question files in Finder", isOn: Binding(
                        get: { library.settings.hideSidecarFiles },
                        set: {
                            library.settings.hideSidecarFiles = $0
                            state.applySidecarVisibility()
                        }
                    ))
                    Text("Your questions live next to each PDF as `<lecture>.ankiflow.json`. Hiding uses the filesystem's hidden flag rather than renaming, so the files keep readable names, git still tracks them, and ⇧⌘. in Finder shows them whenever you want a look.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Fixed for merging") {
                LabeledContent("Note type", value: AnkiIdentity.noteTypeName)
                LabeledContent("Sidecar files", value: ".\(AnkiIdentity.sidecarExtension)")

                Text("These two are read-only on purpose — they are how Anki matches your cards on re-import. Changing either after a first export would orphan every card you have studied, so there is no control here that can do it. The deck root above is safe by comparison: it changes where cards are filed, not whether they are recognised.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}

// MARK: - Keyboard

struct KeyboardSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every one of these is a menu command, so it fires while the cursor is in a text box — you never have to leave the question you're typing to attach the slide you're looking at.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(Array(Shortcuts.all.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    Text(row.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .leading)
                    Text(row.what).font(.system(size: 12.5))
                }
            }

            Text("There is no ⌘S for Save — the app autosaves and has no unsaved state.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }
}

// MARK: - Templates

struct TemplateSettings: View {
    @EnvironmentObject var state: AppState
    @State private var pendingDelete: Template?
    @State private var lastResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.templates.templates.isEmpty {
                Text("No templates yet.")
                    .font(.system(size: 13, weight: .medium))
                Text("A template is a question shape with named blanks you fill in — write one when you notice you're typing the same shape for a third time. New from Question turns whatever you're editing in the panel into one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                List(state.templates.templates) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(template.name).font(.system(size: 13, weight: .medium))
                            Text("\(template.blanks.count) blank\(template.blanks.count == 1 ? "" : "s") · \(usageCount(template)) question\(usageCount(template) == 1 ? "" : "s")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { edit(template) }
                            .controlSize(.small)
                        Button {
                            pendingDelete = template
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete this template")
                    }
                }
            }

            if let lastResult {
                Text(lastResult)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.changed)
            }

            HStack {
                Button("New from Question") {
                    guard let question = state.focusedQuestion else { return }
                    var template = Template(name: "Untitled Template")
                    template.front = question.front
                    template.back = question.back
                    state.editingTemplate = template
                    WindowOpener.open(WindowID.templateEditor)
                }
                .disabled(state.focusedQuestion == nil)
                .help("Turn the question you're editing into a template")

                Button("New Template…") {
                    state.editingTemplate = nil
                    WindowOpener.open(WindowID.templateEditor)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.templates.directory])
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .alert("Delete “\(pendingDelete?.name ?? "")”?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let template = pendingDelete {
                    let converted = state.deleteTemplate(template)
                    lastResult = converted == 0
                        ? "Deleted “\(template.name)”."
                        : "Deleted “\(template.name)” and turned \(converted) question\(converted == 1 ? "" : "s") into Basic."
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            let count = pendingDelete.map(usageCount) ?? 0
            Text(count == 0
                 ? "No questions use it."
                 : "\(count) question\(count == 1 ? "" : "s") built from it will become Basic questions, keeping the text exactly as it reads now. Templates are a typing aid, not a card format, so nothing is lost.")
        }
    }

    private func usageCount(_ template: Template) -> Int {
        (state.document?.questions ?? []).filter { $0.templateId == template.id }.count
    }

    /// Opens the editor as its own window and brings it forward — as a sheet it
    /// appeared behind the Settings window, which looked like nothing happened.
    private func edit(_ template: Template) {
        state.editingTemplate = template
        WindowOpener.open(WindowID.templateEditor)
    }
}
