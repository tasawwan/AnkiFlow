import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The lecture library. The folder tree here is the deck tree in Anki.
///
/// Hand-rolled rather than `List(.sidebar)` on purpose. That style paints a
/// translucent macOS material, which composited over our own ground gave the
/// grey-beige smear behind the folder names -- two backgrounds fighting. One
/// ground, ours, and nothing to fight with.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    @State private var expanded: Set<String> = []

    /// One visible line of the tree.
    ///
    /// The tree is flattened into an array rather than drawn by a recursive
    /// `@ViewBuilder`. A view builder that calls itself makes its own opaque
    /// return type self-referential, which the compiler rejects; recursion in a
    /// plain function returning `[Row]` has no such problem, and a flat array
    /// is what LazyVStack wants anyway.
    private struct Row: Identifiable {
        let node: LibraryNode
        let depth: Int
        var id: String { node.id }
    }

    private func flatten(_ nodes: [LibraryNode], depth: Int = 0) -> [Row] {
        var out: [Row] = []
        for node in nodes {
            out.append(Row(node: node, depth: depth))
            if node.isFolder, expanded.contains(node.id) {
                out.append(contentsOf: flatten(node.children, depth: depth + 1))
            }
        }
        return out
    }

    struct Rename: Identifiable {
        var id: String { url.path }
        let url: URL
        let isFolder: Bool
        var text: String
    }

    struct NewFolder: Identifiable {
        var id: String { parent.path }
        let parent: URL
        var text: String
    }

    @State private var renaming: Rename?
    @State private var creating: NewFolder?
    /// The folder row currently under a drag.
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let library = state.library {
                header(library)
                Divider().overlay(palette.line)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(flatten(library.tree)) { row in
                            if row.node.isFolder {
                                folderRow(row.node, depth: row.depth)
                            } else {
                                lectureRow(row.node, depth: row.depth)
                            }
                        }
                        // Right-clicking below the last row means the library
                        // itself, the way empty space in a Finder window does.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .contentShape(Rectangle())
                            .contextMenu { rootMenu(library) }
                            .onDrop(of: [.fileURL], isTargeted: Binding(
                                get: { dropTarget == "__root__" },
                                set: { dropTarget = $0 ? "__root__" : nil }
                            )) { providers in
                                accept(providers, into: library.root)
                            }
                            .background(
                                dropTarget == "__root__"
                                    ? palette.amber.opacity(0.12) : Color.clear
                            )
                    }
                    .padding(.vertical, 8)
                }
            } else {
                emptyState
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
        // On the whole panel, not just the header and the strip under the rows.
        // A row's own menu is nested inside this one and still wins.
        .contextMenu {
            if let library = state.library { rootMenu(library) }
        }
        .sheet(item: $renaming) { item in
            NameSheet(title: item.isFolder ? "Rename folder" : "Rename lecture",
                      note: item.isFolder
                        ? "Everything inside moves with it."
                        : "The question file is renamed to match, so they stay together.",
                      text: item.text) { newName in
                guard let library = state.library else { return }
                let wasOpen = state.document?.pdfURL == item.url
                perform {
                    if item.isFolder {
                        try library.renameFolder(item.url, to: newName)
                    } else {
                        let moved = try library.rename(item.url, to: newName)
                        state.undoLog?.relocate(from: item.url, to: moved)
                        if wasOpen { state.open(lecture: moved) }
                    }
                }
            }
            .environment(\.palette, palette)
        }
        .sheet(item: $creating) { item in
            NameSheet(title: "New folder", note: "Folders become deck levels in Anki.",
                      text: item.text) { name in
                guard let library = state.library else { return }
                perform { try library.createFolder(named: name, in: item.parent) }
            }
            .environment(\.palette, palette)
        }
    }

    private func header(_ library: Library) -> some View {
        HStack(spacing: 6) {
            Text(library.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        // No buttons. The library watches its folder, so there is nothing to
        // refresh; making a folder is a right-click, like it is in Finder.
        .contentShape(Rectangle())
        .contextMenu { rootMenu(library) }
        // The leading inset the old sidebar was missing, which is why the
        // header ran off the left edge of the window.
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func folderRow(_ node: LibraryNode, depth: Int) -> some View {
        let isOpen = expanded.contains(node.id)
        return Button {
            if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.dim)
                    .frame(width: 10)
                Text(node.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(14 + depth * 14))
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { folderMenu(node) }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(dropTarget == node.id ? palette.amber.opacity(0.22) : Color.clear)
                .padding(.horizontal, 8)
        )
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropTarget == node.id },
            set: { dropTarget = $0 ? node.id : nil }
        )) { providers in
            accept(providers, into: node.url)
        }
    }

    private func lectureRow(_ node: LibraryNode, depth: Int) -> some View {
        let isOpen = state.document?.pdfURL == node.url
        let count = questionCount(for: node.url)
        return Button {
            state.open(lecture: node.url)
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(isOpen ? palette.amber : Color.clear)
                    .frame(width: 2.5)
                    .padding(.vertical, 1)
                Text(node.name)
                    .font(.system(size: 12.5, weight: isOpen ? .semibold : .regular))
                    .foregroundStyle(isOpen ? palette.ink : palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.dim)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(11 + depth * 14))
            .padding(.trailing, 12)
            .background(isOpen ? palette.amber.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { lectureMenu(node) }
        // Drag a lecture onto a folder to move it. The question file follows,
        // which is the whole reason this is worth doing in here rather than in
        // Finder.
        .onDrag { NSItemProvider(object: node.url as NSURL) }
    }

    // MARK: - Rearranging

    /// Renaming and moving from in here rather than in Finder, because the app
    /// knows the question file belongs with its PDF and Finder does not. Every
    /// move made here keeps the pair together; that is the fix orphan recovery
    /// exists to clean up after.
    @ViewBuilder
    private func lectureMenu(_ node: LibraryNode) -> some View {
        Button("Rename…") { renaming = Rename(url: node.url, isFolder: false, text: node.name) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        // No confirmation: it goes to the Trash, and ⌘U puts it straight back.
        Button("Move to Trash") {
            state.trash(node.url, isFolder: false, name: node.name)
        }
    }

    @ViewBuilder
    private func rootMenu(_ library: Library) -> some View {
        Button("New Folder…") { creating = NewFolder(parent: library.root, text: "") }
        Divider()
        Button("Reveal Library in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([library.root])
        }
    }

    @ViewBuilder
    private func folderMenu(_ node: LibraryNode) -> some View {
        Button("New Folder Inside…") { creating = NewFolder(parent: node.url, text: "") }
        Button("Rename…") { renaming = Rename(url: node.url, isFolder: true, text: node.name) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Button("Move to Trash") {
            state.trash(node.url, isFolder: true, name: node.name)
        }
    }

    /// Takes a dropped lecture into a folder.
    ///
    /// The URL comes across as a file-URL data representation rather than as a
    /// `URL` object; `loadObject(ofClass: URL.self)` is not available, so this
    /// unpacks the item by type identifier instead.
    private func accept(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        guard let library = state.library else { return false }
        var accepted = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in
                    guard url.deletingLastPathComponent() != folder else { return }
                    let wasOpen = state.document?.pdfURL == url
                    do {
                        let moved = try library.move(url, toFolder: folder)
                        state.undoLog?.relocate(from: url, to: moved)
                        if wasOpen { state.open(lecture: moved) }
                    } catch {
                        state.statusMessage = error.localizedDescription
                    }
                }
            }
        }
        return accepted
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            state.statusMessage = error.localizedDescription
        }
    }

    /// Cheap read of the sidecar so the sidebar can show how many questions a
    /// lecture already has without opening it.
    private func questionCount(for pdfURL: URL) -> Int? {
        if state.document?.pdfURL == pdfURL { return state.document?.questions.count }
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SidecarFile.self, from: data))?.questions.count
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No library")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text("Open the folder your lecture PDFs live in. Subfolders become deck levels.")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Library…") { openLibraryPanel(state: state) }
                .controlSize(.small)
        }
        .padding(16)
    }
}

@MainActor
func openLibraryPanel(state: AppState) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open Library"
    panel.message = "Pick the folder your lecture PDFs live in. Subfolders become deck levels in Anki."
    if panel.runModal() == .OK, let url = panel.url {
        state.openLibrary(at: url)
    }
}

/// One text field and two buttons, for renaming a lecture or naming a folder.
struct NameSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    let title: String
    let note: String
    @State var text: String
    let onCommit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink)

            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)

            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(palette.panel)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
