import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            AppearanceSettings().pane().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            TagSettings().pane().tabItem { Label("Tags", systemImage: "tag") }
            PageTagSettings().pane().tabItem { Label("Slide Tags", systemImage: "flag") }
            TopicTypeSettings().pane().tabItem { Label("Topics", systemImage: "list.bullet") }
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
/// The sections of the topics panel.
struct TopicTypeSettings: View {
    @EnvironmentObject var state: AppState
    @State private var newType = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each type is a section in the topics panel. Turning one off stops you filing anything new under it — topics already there stay in their notes files, and their section keeps showing, marked off, until you move or delete them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(state.topicTypes) { type in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { type.enabled },
                            set: { state.setTopicType(type, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                        Text(type.name)
                            .font(.system(size: 13))
                            .foregroundStyle(type.enabled ? .primary : .secondary)

                        if type.isBuiltIn {
                            Text("Default")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(.secondary.opacity(0.35), lineWidth: 1))
                        }

                        Spacer(minLength: 0)

                        if !type.isBuiltIn {
                            Button {
                                state.removeTopicType(type)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove this type. Topics already under it keep their section until you move them.")
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onMove { state.moveTopicTypes(from: $0, to: $1) }
            }
            .listStyle(.inset)
            .frame(minHeight: 150)

            HStack(spacing: 8) {
                TextField("Add a type — “Pharm”, “Sketchy”…", text: $newType)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(TopicType.tidy(newType).isEmpty)
            }

            Text("Drag to reorder — the panel follows this order. Defaults can be switched off but not removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit() {
        state.addTopicType(newType)
        newType = ""
    }
}

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
                        tagRow(library, index: index, tag: tag)
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

                Text("The switch turns a tag off — it keeps it in this list and stops offering it as a checkbox or a filter. The pin decides whether it gets a permanent checkbox or lives behind the tag button. Drag to reorder; that's the order they appear in. The tags AnkiFlow ships with can be turned off and renamed but not deleted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open a library first — tags are per library.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    /// On/off, pinned, the name, and — for anything you added yourself — a way
    /// to remove it. The shipped tags get a lock instead: `withDefaults` puts
    /// them straight back on the next launch, so offering a delete would be
    /// offering something that quietly undoes itself.
    private func tagRow(_ library: Library, index: Int, tag: TagDefinition) -> some View {
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { library.settings.tags[index].enabled },
                set: { library.settings.tags[index].enabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(tag.enabled ? "Turn this tag off" : "Turn this tag on")

            Toggle(isOn: Binding(
                get: { library.settings.tags[index].pinned },
                set: { library.settings.tags[index].pinned = $0 }
            )) {
                Image(systemName: library.settings.tags[index].pinned ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(!tag.enabled)
            .help("Always show a checkbox for this tag")

            TextField("", text: Binding(
                get: { library.settings.tags[index].name },
                set: { library.settings.tags[index].name = TagDefinition.normaliseLive($0) }
            ))
            .textFieldStyle(.plain)

            Spacer()

            if tag.isDefault {
                Image(systemName: "lock")
                    .foregroundStyle(.tertiary)
                    .help("Built in — turn it off if you don't want it, it can't be deleted")
            } else {
                Button {
                    library.settings.tags.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this tag")
            }
        }
        .opacity(tag.enabled ? 1 : 0.55)
    }

    private func add() {
        let name = TagDefinition.normalise(newTag)
        guard !name.isEmpty, let library = state.library,
              !library.settings.tags.contains(where: { $0.name == name }) else { return }
        library.settings.tags.append(TagDefinition(name: name, pinned: true))
        newTag = ""
    }
}

// MARK: - Rendering

/// The short labels you can put on a slide, beside the flag.
///
/// A separate pane from Tags on purpose: those go on *cards* and end up in
/// Anki, these are marks on the *PDF* and stay in the PDF. Naming them both
/// "tags" is the user's own word for both, so the panes say which is which
/// rather than inventing a second word for one of them.
struct PageTagSettings: View {
    @EnvironmentObject var state: AppState
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A slide tag is drawn in the corner of the page next to the flag, and written into the PDF itself — so it's there in Preview, on your iPad, and on the slide image that reaches Anki.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let library = state.library {
                List {
                    ForEach(Array(library.settings.pageTags.enumerated()),
                            id: \.element.id) { index, tag in
                        row(library, index: index, tag: tag)
                    }
                    .onMove { source, destination in
                        library.settings.pageTags.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 170)

                HStack(spacing: 8) {
                    TextField("Add a tag — “CC”, “HY”, “Path”…", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(library) }
                    Button("Add") { add(library) }
                        .disabled(tidied.isEmpty
                                  || library.settings.pageTags.contains { $0.label == tidied })
                }

                Text("Short is the point — these are drawn at 13pt in the corner of a slide, so two or three letters read well and a sentence does not. Turning one off stops it being offered for new slides; the ones already marked keep their tag and can still have it taken off. Drag to reorder — that's the order the menu shows.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open a library first — slide tags are per library.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var tidied: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add(_ library: Library) {
        let label = tidied
        guard !label.isEmpty,
              !library.settings.pageTags.contains(where: { $0.label == label }) else { return }
        library.settings.pageTags.append(PageTagDefinition(label: label))
        newTag = ""
    }

    private func row(_ library: Library, index: Int, tag: PageTagDefinition) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { library.settings.pageTags[index].enabled },
                set: { library.settings.pageTags[index].enabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Text(tag.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tag.enabled ? .primary : .secondary)

            Spacer(minLength: 0)

            Button {
                library.settings.pageTags.removeAll { $0.label == tag.label }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this tag. Slides already marked with it keep their mark.")
        }
        .padding(.vertical, 1)
    }
}

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
                    cacheDirectory: AppPaths.cacheDirectory,
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
    @FocusState private var deckRootFocused: Bool

    /// What the deck names will actually read, with this library's own folder
    /// in the middle -- the abstract "root::…" was never the part people needed
    /// to see.
    private func deckPreview(_ library: Library) -> String {
        var parts: [String] = []
        let root = library.settings.resolvedDeckRoot
        if !root.isEmpty { parts.append(root) }
        parts.append(library.name)
        parts.append(contentsOf: ["Anatomy", "Lecture 04"])
        return parts.joined(separator: "::")
    }

    /// How many questions Anki already knows about. Changing the root after
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

            Section("Changes in Anki") {
                if let library = state.library {
                    Toggle("Watch Anki while it's open", isOn: Binding(
                        get: { library.settings.autoSyncFromAnki },
                        set: { library.settings.autoSyncFromAnki = $0 }
                    ))
                    Text("Every minute, cards you edited in Anki and nowhere else are pulled back here. Anything you changed in both places, and anything deleted in Anki, is never applied on its own — it waits in ⌘⇧D, which does a fuller check than the background one can afford.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Deck root") {
                if let library = state.library {
                    TextField("Deck root", text: Binding(
                        get: { library.settings.deckRoot },
                        set: { library.settings.deckRoot = $0 }
                    ))
                    // Return gets you out of the field. Without it the focus
                    // ring stays put and the key does nothing, which reads as
                    // the pane being stuck.
                    .focused($deckRootFocused)
                    .onSubmit { deckRootFocused = false }
                    LabeledContent("Decks will be named", value: deckPreview(library))

                    if exportedCount > 0 {
                        Label("\(exportedCount) question\(exportedCount == 1 ? " has" : "s have") already been exported.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.78, green: 0.55, blue: 0.20))
                        Text("Anki never moves existing cards between decks on import. Change the root now and your studied cards stay in the old tree while new ones go to the new one — your collection ends up split. If you want them together you'd rename the parent deck in Anki yourself, which takes ten seconds and is the tidier fix.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("One root above everything. Your library folder is the level below it, and the folders inside your library are the levels below that — so your decks in Anki are shaped like your folders on disk. Leave it empty and there is no level above the library at all.")
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
                LabeledContent("Note types", value: "\(AnkiIdentity.noteTypeName), \(AnkiIdentity.clozeNoteTypeName)")
                LabeledContent("Sidecar files", value: ".\(AnkiIdentity.sidecarExtension)")

                Text("These are read-only on purpose — they are how Anki matches your cards on re-import. Changing either after a first export would orphan every card you have studied, so there is no control here that can do it. The deck root above is safe by comparison: it changes where cards are filed, not whether they are recognised.")
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
                Text("A template is a question shape with named blanks you fill in — write one when you notice you're typing the same shape for a third time. New from Question turns whatever you're editing in the panel into one. Cards never point at a template: a template recognises the wording of a card you already wrote, so turning one off or deleting it changes nothing but which tab the card sits in.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                List(state.templates.templates) { template in
                    row(template)
                }
            }

            if let lastResult {
                Text(lastResult)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.changed)
            }

            HStack {
                Button("New from Question") { newFromQuestion() }
                    .disabled(state.focusedQuestion == nil)
                    .help(state.focusedQuestion == nil
                          ? "Open a question in the panel first"
                          : "Turn the question you're editing into a template")

                Button("New Template…") {
                    state.editingTemplate = nil
                    WindowOpener.open(WindowID.templateEditor)
                }
                Spacer()
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
                        ? "Deleted “\(template.name)”. Its cards are unchanged."
                        : "Deleted “\(template.name)”. \(converted) old question\(converted == 1 ? "" : "s") had its text written down first, so nothing was lost."
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            let count = pendingDelete.map(usageCount) ?? 0
            Text(count == 0
                 ? "Nothing in this lecture is written in that shape."
                 : "\(count) card\(count == 1 ? "" : "s") in this lecture read through it. They keep every word — a template only recognises text, it never holds it — and simply move back to the Basic tab.")
        }
    }

    /// The toggle turns a shape off without losing it: no tab, no card claimed,
    /// still there for next term. Which is also what the built-in shapes get
    /// instead of a delete button -- they come back on the next launch either
    /// way, and a delete that undoes itself is worse than one that isn't offered.
    private func row(_ template: Template) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { template.enabled },
                set: { state.templates.setEnabled($0, for: template) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(template.enabled ? "Turn this template off" : "Turn this template on")

            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(template.enabled ? .primary : .secondary)
                Text(subtitle(template))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { edit(template) }
                .controlSize(.small)
            if template.isBuiltIn {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Built in — turn it off if you don't want it, it can't be deleted")
            } else {
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
        .opacity(template.enabled ? 1 : 0.55)
    }

    /// Kept out of the view body: four interpolations and three ternaries in
    /// one expression is how you get "unable to type-check in reasonable time".
    private func subtitle(_ template: Template) -> String {
        let blanks = Template.keys(in: template.front).count
        let cards = usageCount(template)
        var parts: [String] = []
        switch template.kind {
        case .occlusion: parts.append("Occlusion")
        case .cloze:     parts.append("Cloze")
        case .basic, .template: break
        }
        parts.append("\(blanks) blank\(blanks == 1 ? "" : "s")")
        parts.append("\(cards) card\(cards == 1 ? "" : "s") here")
        if !template.tags.isEmpty { parts.append(template.tags.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Cards currently being read through this shape, which is the number that
    /// answers "what does deleting this change".
    private func usageCount(_ template: Template) -> Int {
        (state.document?.questions ?? [])
            .filter { state.tab(for: $0) == .template(template.id) }.count
    }

    /// Seed a template from the question in the panel.
    ///
    /// From its *rendered* text, which is now the only text there is: a question
    /// written through a template holds its finished words like any other, so
    /// "make another one of these" starts from what is actually on the card.
    /// It arrives with no blanks yet -- select a phrase and press ⌘B for each --
    /// so the editor opens on the front field rather than on an empty shape.
    private func newFromQuestion() {
        guard let question = state.focusedQuestion else { return }
        var template = Template(name: question.summary(template: state.template(for: question))
                                    .prefix(40).trimmingCharacters(in: .whitespacesAndNewlines))
        if template.name.isEmpty { template.name = "Untitled Template" }
        template.front = question.front
        template.back = question.back
        template.tags = question.tags
        state.editingTemplate = template
        WindowOpener.open(WindowID.templateEditor)
    }

    /// Opens the editor as its own window and brings it forward — as a sheet it
    /// appeared behind the Settings window, which looked like nothing happened.
    private func edit(_ template: Template) {
        state.editingTemplate = template
        WindowOpener.open(WindowID.templateEditor)
    }
}
