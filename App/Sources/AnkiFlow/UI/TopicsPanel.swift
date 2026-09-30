import SwiftUI
import AppKit

/// The topic list at the foot of the library panel.
///
/// A topic is a name and a rating; the writing about it lives in the lecture's
/// notes. Two views of the same data: this lecture on its own, or every lecture
/// in the library with its topics under it, which is the one that answers "what
/// have I still not learned" across a whole course.
struct TopicsPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    enum Scope: String, CaseIterable, Identifiable {
        case lecture, folder, library
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lecture: return "Lecture"
            case .folder:  return "Folder"
            case .library: return "Library"
            }
        }
    }

    @State private var scope: Scope = .lecture
    /// Which folder the Folder scope means. Nil is the lecture's own, which is
    /// the sensible default and what it always used to be -- but a library laid
    /// out as materials ▸ block ▸ class has three answers to "the folder", and
    /// picking one of them silently was picking wrong two thirds of the time.
    @State private var chosenFolder: URL?
    /// Show one section only, or all of them.
    @State private var typeFilter: String?
    /// Bumped by the re-sort button. The lists watch it rather than being told
    /// directly, because each of them reorders itself differently -- one holds
    /// the open lecture's topics, the others hold files.
    @State private var sortTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filters
            Rectangle().fill(palette.lineSoft).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("TOPICS")
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            Spacer(minLength: 6)
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 172)

            // Rating a topic deliberately does not move it: a row that jumped
            // out from under the cursor mid-cycle would make the panel unusable
            // while studying. This is how you fold the ratings back into order
            // when you are ready for it.
            Button { sortTick += 1 } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
            .buttonStyle(.plain)
            .help("Sort by comfort, then name")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The folders "Folder" could mean: the lecture's own, then each one above
    /// it up to the library root.
    private var folderChoices: [URL] {
        guard let library = state.library,
              var folder = state.document?.pdfURL.deletingLastPathComponent() else { return [] }
        var out: [URL] = []
        let root = library.root.standardizedFileURL
        while folder.standardizedFileURL.path.hasPrefix(root.path) {
            out.append(folder)
            if folder.standardizedFileURL == root { break }
            folder = folder.deletingLastPathComponent()
        }
        return out
    }

    private var folderInScope: URL? {
        if let chosenFolder, folderChoices.contains(where: {
            $0.standardizedFileURL == chosenFolder.standardizedFileURL
        }) { return chosenFolder }
        return folderChoices.first
    }

    /// Which folder, and which kind of topic. Both only when they have
    /// something to offer: a lecture at the root of its library has one folder
    /// to choose from, which is not a choice.
    @ViewBuilder
    private var filters: some View {
        let choices = folderChoices
        let types = state.topicTypes.filter(\.enabled).map(\.name)
        if (scope == .folder && choices.count > 1) || types.count > 1 {
            HStack(spacing: 8) {
                if scope == .folder, choices.count > 1 {
                    Menu {
                        ForEach(choices, id: \.path) { folder in
                            Button(folder.finderName) { chosenFolder = folder }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text(folderInScope?.finderName ?? "Folder")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(palette.ink2)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if types.count > 1 {
                    ForEach(types, id: \.self) { type in
                        let on = typeFilter == type
                        Button {
                            typeFilter = on ? nil : type
                        } label: {
                            Text(type)
                                .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? palette.ink : palette.dim)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(on ? palette.amber.opacity(0.22)
                                                             : Color.clear))
                                .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .lecture:
            if let notes = state.notes {
                LectureTopicList(notes: notes, sortTick: sortTick,
                                 typeFilter: typeFilter)
            } else {
                placeholder("Open a lecture to keep topics for it.")
            }
        case .folder:
            if let folder = folderInScope, let library = state.library {
                GroupedTopicList(lectures: library.lectures(under: folder),
                                 caption: folder.finderName,
                                 sortTick: sortTick,
                                 typeFilter: typeFilter)
            } else {
                placeholder("Open a lecture to see the topics in its folder.")
            }
        case .library:
            if let library = state.library {
                GroupedTopicList(lectures: library.allLectures(), caption: nil,
                                 sortTick: sortTick, typeFilter: typeFilter)
            } else {
                placeholder("Open a library to see its topics.")
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11.5))
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - One lecture

private struct LectureTopicList: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    @ObservedObject var notes: LectureNotes
    let sortTick: Int
    /// Show only this section, or all of them when nil.
    var typeFilter: String?
    @State private var entry: [String: String] = [:]
    @State private var adding: String?
    @FocusState private var entryFocused: String?

    /// Every section to draw: the types you have switched on, then any this
    /// lecture still has topics under that you have not.
    ///
    /// The union is what makes switching a type off safe. A type with work
    /// filed under it keeps its section -- marked off, with nothing to add to
    /// it -- rather than taking that work somewhere you cannot see it. The
    /// section goes by itself once the last topic leaves, and the same rule
    /// picks up a heading you wrote by hand in another editor.
    private struct Section: Identifiable {
        let name: String
        let enabled: Bool
        var id: String { name.lowercased() }
    }

    private var sections: [Section] {
        var out = state.topicTypes.filter(\.enabled).map { Section(name: $0.name, enabled: true) }
        for topic in notes.topics
        where !out.contains(where: { $0.name.caseInsensitiveCompare(topic.type) == .orderedSame }) {
            out.append(Section(name: topic.type, enabled: false))
        }
        guard let typeFilter else { return out }
        return out.filter { $0.name.caseInsensitiveCompare(typeFilter) == .orderedSame }
    }

    private var destinations: [String] {
        state.topicTypes.filter(\.enabled).map(\.name)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    sectionView(section.name, enabled: section.enabled)
                }
            }
            .padding(.bottom, 8)
        }
        .onChange(of: sortTick) { notes.resortTopics() }
    }

    @ViewBuilder
    private func sectionView(_ type: String, enabled: Bool) -> some View {
        let inside = notes.topics.filter {
            $0.type.caseInsensitiveCompare(type) == .orderedSame
        }
        let collapsed = state.isTopicSectionCollapsed(type)

        sectionHeader(type, enabled: enabled, count: inside.count, collapsed: collapsed)

        if !collapsed {
            Rectangle().fill(palette.lineSoft).frame(height: 1)
                .padding(.horizontal, 10)

            if adding == type {
                entryField(for: type)
            }

            ForEach(inside) { topic in
                TopicRow(topic: topic,
                         dimmed: !enabled,
                         onCycle: { edit("that rating") { notes.cycleComfort(of: topic) } },
                         onRename: { name in
                             edit("renaming that topic") { notes.renameTopic(topic, to: name) }
                         },
                         onDelete: { edit("deleting that topic") { notes.removeTopic(topic) } },
                         onShowCards: { state.showCards(for: topic) })
                    .contextMenu {
                        Menu("Move to") {
                            ForEach(destinations.filter {
                                $0.caseInsensitiveCompare(type) != .orderedSame
                            }, id: \.self) { destination in
                                Button(destination) {
                                    edit("moving that topic") {
                                        notes.moveTopic(topic, to: destination)
                                    }
                                }
                            }
                        }
                    }
            }

            if inside.isEmpty {
                Text(enabled
                     ? "Nothing here yet."
                     : "Switched off in Settings.")
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else if !enabled {
                Text("Switched off in Settings. This section goes when the last one is moved or deleted.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 3)
                    .padding(.bottom, 6)
            }
        }
    }

    private func sectionHeader(_ type: String, enabled: Bool,
                               count: Int, collapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.dim)
            Text(type.uppercased())
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
                .opacity(enabled ? 1 : 0.6)
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.dim)
                .padding(.horizontal, 5)
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            Spacer(minLength: 4)
            if enabled {
                Button {
                    adding = type
                    entryFocused = type
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .help("Add a topic to \(type)")
            } else {
                // No plus: you cannot file anything new under a type you have
                // switched off, which is the whole meaning of switching it off.
                Text("OFF")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.line, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleTopicSection(type) }
        .contextMenu {
            Menu("Move all \(count) to") {
                ForEach(destinations.filter {
                    $0.caseInsensitiveCompare(type) != .orderedSame
                }, id: \.self) { destination in
                    Button(destination) {
                        edit("moving those topics") {
                            notes.moveTopics(from: type, to: destination)
                        }
                    }
                }
            }
            .disabled(count == 0)
        }
    }

    private func entryField(for type: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.dim)
            TextField("Add to \(type)", text: Binding(
                get: { entry[type] ?? "" },
                set: { entry[type] = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($entryFocused, equals: type)
            .onSubmit { commit(into: type) }
            .onExitCommand { adding = nil }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { entryFocused = type }
    }

    private func edit(_ label: String, _ change: () -> Void) {
        state.notesEdit(label, on: notes.pdfURL, change)
    }

    private func commit(into type: String) {
        let text = entry[type] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            adding = nil
            return
        }
        edit("adding that topic") { notes.addTopic(text, type: type) }
        entry[type] = ""
        // Left open and focused: naming what a lecture covers is something you
        // do several at a time, straight after each other.
        entryFocused = type
    }
}

// MARK: - Every lecture

private struct GroupedTopicList: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    /// The lectures to read, already narrowed to the scope in play.
    let lectures: [URL]
    /// Named when the scope is narrower than the whole library, so the list says
    /// which folder you are looking at rather than leaving you to infer it.
    let caption: String?
    let sortTick: Int
    var typeFilter: String?

    private struct LectureTopics: Identifiable {
        let url: URL
        let name: String
        var topics: [Topic]
        var id: String { url.path }
    }

    @State private var groups: [LectureTopics] = []
    @State private var loading = true

    private var key: String { lectures.map(\.path).joined(separator: "\u{1}") }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let caption {
                    Text(caption.uppercased())
                        .font(AppFont.rowLabel)
                        .tracking(0.6)
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                if loading {
                    Text("Reading your notes…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                } else if groups.isEmpty {
                    Text("Nothing rated here yet. Topics you add to a lecture show up in this list.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                }
                ForEach(groups) { group in
                    let shown = typeFilter.map { wanted in
                        group.topics.filter { $0.type.caseInsensitiveCompare(wanted) == .orderedSame }
                    } ?? group.topics
                    if !shown.isEmpty { lectureHeader(group) }
                    ForEach(shown) { topic in
                        TopicRow(topic: topic, indent: 10,
                                 onCycle: { cycle(topic, in: group) },
                                 onRename: { rename(topic, to: $0, in: group.url) },
                                 onDelete: { remove(topic, in: group) },
                                 onShowCards: { state.showCards(for: topic, in: group.url) })
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .onAppear { reload() }
        .onChange(of: key) { reload() }
        // Re-read rather than re-sort in place: these lists are built from files
        // on disk, so the honest answer to "put this in order" is to go and look
        // at them again -- which also picks up anything edited elsewhere.
        .onChange(of: sortTick) { reload() }
    }

    private func lectureHeader(_ group: LectureTopics) -> some View {
        HStack(spacing: 5) {
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(group.topics.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        // Clicking the name opens that lecture, because the reason you are
        // looking at a list of things you do not know is to go and learn one.
        .onTapGesture { state.open(lecture: group.url) }
        .help("Open \(group.name)")
    }

    /// The open lecture is rated through its own `LectureNotes` -- that object
    /// owns the file and is watching it, and writing round it would mean the
    /// panel and the editor disagreeing until the watcher caught up. Every other
    /// lecture is a read, a change and a write of its notes file.
    private func cycle(_ topic: Topic, in group: LectureTopics) {
        let wanted = topic.comfort.next
        state.notesEdit("that rating", on: group.url) {
            if let notes = state.notes, notes.pdfURL == group.url {
                notes.cycleComfort(of: topic)
            } else {
                try? TopicBlock.rate(topic, to: wanted,
                                     inFileAt: AnkiIdentity.notesURL(for: group.url))
            }
        }
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              let row = groups[index].topics.firstIndex(where: { $0.id == topic.id })
        else { return }
        groups[index].topics[row].comfort = wanted
    }

    /// Read straight through on the main actor. These are a handful of small
    /// text files, and handing them to a background task would mean making the
    /// results Sendable to buy back a millisecond.
    /// Same split as rating: the open lecture goes through the object that owns
    /// its file, everything else is a read, a change and a write.
    private func remove(_ topic: Topic, in group: LectureTopics) {
        state.notesEdit("deleting that topic", on: group.url) {
            if let notes = state.notes, notes.pdfURL == group.url {
                notes.removeTopic(topic)
            } else {
                try? TopicBlock.remove(topic, inFileAt: AnkiIdentity.notesURL(for: group.url))
            }
        }
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].topics.removeAll { $0.id == topic.id }
        // A lecture with nothing left in it stops being a heading with an empty
        // list under it.
        groups.removeAll { $0.topics.isEmpty }
    }

    private func rename(_ topic: Topic, to name: String, in url: URL) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        state.notesEdit("renaming that topic", on: url) {
            if let notes = state.notes, notes.pdfURL == url {
                notes.renameTopic(topic, to: cleaned)
            } else {
                try? TopicBlock.rename(topic, to: cleaned,
                                       inFileAt: AnkiIdentity.notesURL(for: url))
            }
        }
        guard let index = groups.firstIndex(where: { $0.url == url }),
              let row = groups[index].topics.firstIndex(where: { $0.id == topic.id })
        else { return }
        groups[index].topics[row].name = cleaned
    }

    private func reload() {
        loading = true
        groups = lectures.compactMap { url in
            let topics = TopicBlock.topics(inFileAt: AnkiIdentity.notesURL(for: url))
            guard !topics.isEmpty else { return nil }
            return LectureTopics(url: url,
                                 name: url.lectureName,
                                 topics: topics)
        }
        loading = false
    }
}

// MARK: - A row

private struct TopicRow: View {
    @Environment(\.palette) private var palette
    let topic: Topic
    var indent: CGFloat = 0
    /// Drawn back for a section whose type has been switched off.
    var dimmed: Bool = false
    let onCycle: () -> Void
    /// Takes the new name: renaming happens in the row, so there is no sheet to
    /// hold the draft on the row's behalf.
    let onRename: (String) -> Void
    let onDelete: () -> Void
    /// Clicking the name asks "what have I written about this".
    var onShowCards: () -> Void = { }

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        rowBody.opacity(dimmed ? 0.62 : 1)
    }

    private var rowBody: some View {
        HStack(spacing: 7) {
            Button(action: onCycle) {
                HStack(spacing: 4) {
                    Image(systemName: topic.comfort.symbol)
                        .font(.system(size: 9.5))
                    Text(topic.comfort.label)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .frame(width: 84, alignment: .leading)
            .help("Click to move this up to \(topic.comfort.next.label)")

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { if !focused { commit() } }
            } else {
                Text(topic.name)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { onShowCards() }
                    // Two lines before it gives up. A topic is a phrase, and
                    // "Immunoglobulins and an…" is not one -- the half that got
                    // cut is usually the half that told you which topic it was.
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Double-click the words to change them, the way you rename
                    // anything else on this machine.
                    .onTapGesture(count: 2) {
                        draft = topic.name
                        editing = true
                    }
            }

            Spacer(minLength: 4)

            if hovering, !editing {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .help("Remove this topic")
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(hovering ? palette.select.opacity(0.35) : Color.clear)
        .onHover { hovering = $0 }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != topic.name else { return }
        onRename(cleaned)
    }

    private var tint: Color {
        switch topic.comfort {
        case .low:      return Color(red: 0.78, green: 0.31, blue: 0.26)
        case .medium:   return palette.amber
        case .high:     return Color(red: 0.24, green: 0.50, blue: 0.71)
        case .mastered: return Color(red: 0.22, green: 0.54, blue: 0.36)
        }
    }
}
