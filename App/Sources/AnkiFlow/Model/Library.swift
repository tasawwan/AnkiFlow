import Foundation
import Combine
import PDFKit

/// The `.ankiflow` folder AnkiFlow used to keep inside every library.
///
/// Nothing is written here any more. The settings that lived in `library.json`
/// belong to the app now, the image cache moved to the system cache directory
/// where a cache belongs, and the save snapshots are gone. What remains is the
/// name — so a folder left over from an older version is still recognised and
/// skipped when the library is scanned, and its settings can still be read once
/// on the way past.
enum LibraryPaths {
    static let dotDirectoryName = ".ankiflow"

    static func dotDirectory(inLibrary root: URL) -> URL {
        root.appendingPathComponent(dotDirectoryName, isDirectory: true)
    }

    /// Read once, by `SettingsStore.adoptOldLibraryFile`. Never written.
    static func settingsURL(inLibrary root: URL) -> URL {
        dotDirectory(inLibrary: root).appendingPathComponent("library.json")
    }

    /// True when an old folder is still sitting in the library, so the app can
    /// say it is now safe to throw away.
    static func hasLeftovers(inLibrary root: URL) -> Bool {
        FileManager.default.fileExists(atPath: dotDirectory(inLibrary: root).path)
    }
}

/// Where AnkiFlow keeps its own files, none of them inside your lectures.
enum AppPaths {
    /// Rendered slide images.
    ///
    /// `~/Library/Caches`, which is what a cache directory is for: the system
    /// reclaims it under disk pressure and Time Machine skips it, neither of
    /// which was true when this sat inside somebody's coursework folder. One
    /// cache for every library — the filenames already carry the PDF's own hash,
    /// so two libraries cannot collide.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(AnkiIdentity.appName, isDirectory: true)
            .appendingPathComponent("slides", isDirectory: true)
    }
}

// MARK: - Tags

/// How much a card matters: three levels, two tags.
///
/// Normal is the default and carries no tag at all, which is the whole point.
/// Most cards are ordinary, a tag every card wears says nothing, and a
/// collection where `-normal-yield` matches nine cards in ten is a search term
/// you can never use. So the two ends are marked and the middle is simply the
/// absence of a mark -- which also means a card written before yields existed
/// already reads as normal, with nothing to migrate.
enum Yield: String, CaseIterable, Identifiable {
    case normal, high, low

    var id: String { rawValue }

    /// Nil for normal, which is what makes it the default.
    var tag: String? { self == .normal ? nil : "\(rawValue)-yield" }

    var label: String {
        switch self {
        case .high:   return "High yield"
        case .normal: return "Normal yield"
        case .low:    return "Low yield"
        }
    }

    /// The button walks the rungs and wraps. Ordered so the common answer is one
    /// click from the default: most of what you mark is high-yield.
    var next: Yield {
        let rungs = Yield.allCases
        return rungs[((rungs.firstIndex(of: self) ?? 0) + 1) % rungs.count]
    }

    var symbol: String {
        switch self {
        case .high:   return "circle.fill"
        case .normal: return "circle.lefthalf.filled"
        case .low:    return "circle"
        }
    }

    /// What a set of tags says the yield is. Unmarked means normal.
    static func of(_ tags: [String]) -> Yield {
        if tags.contains("high-yield") { return .high }
        if tags.contains("low-yield") { return .low }
        return .normal
    }
}

/// A short label you can put on a slide, drawn beside the flag in the corner
/// of the page and written into the PDF as an annotation -- so it is there in
/// Preview, on the iPad, and in the exported slide image.
struct PageTagDefinition: Codable, Identifiable, Equatable {
    var label: String
    var enabled: Bool = true

    var id: String { label }
}

/// A tag you can put on cards. `pinned` tags get a permanent checkbox at the
/// bottom of the question panel; the rest live behind the "More tags" field.
struct TagDefinition: Codable, Identifiable, Equatable {
    var name: String
    var pinned: Bool
    /// Off means it stays in the list and stops being offered anywhere else --
    /// no checkbox, no filter chip. For the tag you use in one course and not
    /// the next, which is not the same as being finished with it.
    var enabled: Bool

    var id: String { name }

    init(name: String, pinned: Bool = true, enabled: Bool = true) {
        self.name = name
        self.pinned = pinned
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The tags the app ships with. Editable and switchable off, but not
    /// deletable -- they would come back on the next launch anyway, and a delete
    /// that quietly undoes itself is worse than one that isn't offered.
    static let defaults: [String] = yields + ["clinical-correlation", "drug-info"]

    var isDefault: Bool { TagDefinition.defaults.contains(name) }

    /// A tag never contains a space.
    ///
    /// Anki splits a note's tag field on whitespace, so "high yield" typed here
    /// arrives there as two tags, `high` and `yield`, and neither is the one you
    /// meant to search for. Hyphenating on the way in means the tag you see in
    /// this app is the tag you get in your collection. Everywhere a tag can be
    /// typed goes through here.
    static func normalise(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// The yield tags that actually exist.
    ///
    /// Two, not three -- see `Yield`. Kept here rather than in the panel because
    /// it is a fact about the vocabulary, not about one control: the filter row,
    /// the template editor and the tag bar all need to know that picking one of
    /// these unpicks the other.
    static let yields = Yield.allCases.compactMap(\.tag)

    /// The same rule, applied while someone is still typing.
    ///
    /// `normalise` trims, which is right on commit and wrong on every keystroke
    /// before it: the space in "high yield" is a trailing space at the moment it
    /// is typed, so trimming ate it and the field filled up with "highyield".
    /// This one only ever substitutes, so the text can still be finished.
    static func normaliseLive(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// `normal-yield` is in here and not in `yields`: it is not a tag this app
    /// hands out any more, but one written by an earlier build has to be swept
    /// away when a yield is set rather than left sitting alongside the new one.
    static func isYield(_ name: String) -> Bool {
        yields.contains(name) || name == "normal-yield"
    }
}

// MARK: - Settings

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case auto, webp, jpeg, png
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .webp: return "WebP"
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        }
    }
}

/// Settings, stored once for the app rather than once per folder of lectures.
///
/// They used to live in `.ankiflow/library.json` inside each library, and none
/// of them were really about a folder: image width, whether question files are
/// hidden, and the tag vocabulary are answers you give once and want everywhere.
/// The tag list in particular was never load-bearing -- a card's tags are on the
/// card -- so a per-library copy of it was a second place for the same fact to
/// drift.
struct AppSettings: Codable, Equatable {
    var imageWidth: Int = 1600
    var imageFormat: ImageFormat = .auto
    var jpegQuality: Double = 0.82
    var revealAfterExport: Bool = true
    /// Bumped when rendering settings change, so cached images and content
    /// hashes both invalidate together.
    /// Bump when the drawing changes, so cards already in Anki get the new
    /// picture. 2: highlights are multiplied into the slide rather than laid
    /// over it, which changes every slide carrying one.
    var renderVersion: Int = 2
    /// The deck everything hangs off, above the library.
    ///
    /// The library folder's own name comes next, then its folders, then the
    /// lecture -- so one root can hold several libraries side by side without
    /// their decks running together. Leave it empty and there is no level above
    /// the library at all.
    ///
    /// Editable, but see the warning in Settings: existing cards never move deck
    /// on re-import, so changing this after an export splits your collection.
    var deckRoot: String = AnkiIdentity.deckRoot
    /// Keep the per-lecture question files out of Finder's way. They sit beside
    /// your PDFs, so by default they're hidden rather than doubling the
    /// apparent contents of every folder.
    var hideSidecarFiles: Bool = true
    /// Watch Anki while it is open, and pull back edits that only happened
    /// there. Conflicts and deletions are never applied on their own; see
    /// `AppState.pollAnki`.
    var autoSyncFromAnki: Bool = true
    /// Sections of the topics panel, in the order they are shown.
    var topicTypes: [TopicType] = TopicType.defaults
    /// Tags offered in the question panel. Order here is the order shown.
    var tags: [TagDefinition] = AppSettings.starterTags
    /// Short labels you can put on a *slide*, beside the flag. Nothing to do
    /// with the tags above: those go on cards and reach Anki, these are marks
    /// on the PDF itself and stay in the PDF.
    var pageTags: [PageTagDefinition] = AppSettings.starterPageTags

    static let starterPageTags: [PageTagDefinition] = [
        PageTagDefinition(label: "CC"), PageTagDefinition(label: "HY")
    ]

    /// What the menu offers. A tag switched off keeps every mark you have
    /// already made -- it is still drawn on the slides that carry it and can
    /// still be taken off -- it just stops being offered for new ones.
    var activePageTags: [PageTagDefinition] { pageTags.filter(\.enabled) }

    static let starterTags: [TagDefinition] = TagDefinition.defaults.map {
        // Yield has its own button, so pinning it would only put it in the
        // checkbox row twice.
        TagDefinition(name: $0, pinned: !TagDefinition.isYield($0))
    }

    /// Defaults are always in the list, however the file arrived.
    static func withDefaults(_ tags: [TagDefinition]) -> [TagDefinition] {
        var out = tags
        for tag in starterTags where !out.contains(where: { $0.name == tag.name }) {
            out.append(tag)
        }
        return out
    }

    /// What the checkboxes and the filter row offer.
    var activeTags: [TagDefinition] { tags.filter(\.enabled) }

    /// May be empty -- that means no level above the library. Never contains
    /// "::", which is what separates deck levels.
    var resolvedDeckRoot: String {
        AppSettings.sanitisedDeckRoot(deckRoot)
    }

    static func sanitisedDeckRoot(_ raw: String) -> String {
        raw.replacingOccurrences(of: "::", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    var pinnedTags: [TagDefinition] { activeTags.filter(\.pinned) }
    var unpinnedTags: [TagDefinition] { activeTags.filter { !$0.pinned } }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth) ?? 1600
        imageFormat = try c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat) ?? .auto
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.82
        revealAfterExport = try c.decodeIfPresent(Bool.self, forKey: .revealAfterExport) ?? true
        renderVersion = try c.decodeIfPresent(Int.self, forKey: .renderVersion) ?? 2
        deckRoot = try c.decodeIfPresent(String.self, forKey: .deckRoot) ?? AnkiIdentity.deckRoot
        hideSidecarFiles = try c.decodeIfPresent(Bool.self, forKey: .hideSidecarFiles) ?? true
        tags = AppSettings.withDefaults(
            try c.decodeIfPresent([TagDefinition].self, forKey: .tags) ?? AppSettings.starterTags)
        // These three were being written to the file and never read back, so
        // every launch quietly restored the defaults over whatever you had set.
        autoSyncFromAnki = try c.decodeIfPresent(Bool.self, forKey: .autoSyncFromAnki) ?? true
        topicTypes = try c.decodeIfPresent([TopicType].self, forKey: .topicTypes)
            ?? TopicType.defaults
        pageTags = try c.decodeIfPresent([PageTagDefinition].self, forKey: .pageTags)
            ?? AppSettings.starterPageTags
    }
}

// MARK: - Folder tree

/// One node of the lecture library. Folders become deck levels; PDFs become decks.
struct LibraryNode: Identifiable, Equatable {
    let url: URL
    let isFolder: Bool
    var children: [LibraryNode]

    var id: String { url.path }
    var name: String {
        isFolder ? url.finderName : url.lectureName
    }
}

/// The one place settings live.
///
/// A singleton because there is one app and one set of preferences in it, and
/// threading a store through `Library`, `PageRenderer`, the exporter and every
/// view that shows a checkbox would be a lot of plumbing to express "there is
/// only one of these".
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            // The file writer reads the order from here rather than being handed
            // it at every call site.
            TopicType.order = settings.topicTypes.map(\.name)
            save()
        }
    }

    let fileURL: URL

    init(directory: URL? = nil) {
        let root: URL
        if let directory {
            root = directory
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            root = support.appendingPathComponent(AnkiIdentity.appName, isDirectory: true)
        }
        self.fileURL = root.appendingPathComponent("Settings.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           var loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // A default tag added in a later version has to reach a settings
            // file written by an earlier one, or it exists in the source and
            // nowhere you can see it. Appended, never reordered, and only when
            // missing -- a default you have switched off stays off.
            let known = Set(loaded.tags.map(\.name))
            for name in TagDefinition.defaults where !known.contains(name) {
                loaded.tags.append(TagDefinition(name: name))
            }
            // Highlights are drawn differently now, so every slide carrying one
            // has to be re-rendered and re-exported. Bumping the stored version
            // once is what reaches cards already in Anki; leaving it at 1 would
            // have fixed the screen and left the cards muddy.
            if loaded.renderVersion < 2 { loaded.renderVersion = 2 }
            // Same for topic types, and for the same reason.
            let types = Set(loaded.topicTypes.map(\.id))
            for type in TopicType.defaults where !types.contains(type.id) {
                loaded.topicTypes.append(type)
            }
            self.settings = loaded
        } else {
            self.settings = AppSettings()
        }
        TopicType.order = self.settings.topicTypes.map(\.name)
    }

    /// Take over from a library's own `library.json`, once.
    ///
    /// Everything but the deck root comes across as it stands. The deck root
    /// does not, because it used to mean "the top level" and now means "the
    /// level above the library" -- carrying it over would name a library after
    /// itself twice. `hasMigrated` is what the change notice reads to tell you
    /// your deck names gained a level.
    @discardableResult
    func adoptOldLibraryFile(inLibrary root: URL) -> Bool {
        let old = LibraryPaths.settingsURL(inLibrary: root)
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: old),
              let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
        var adopted = loaded
        adopted.deckRoot = AnkiIdentity.deckRoot
        settings = adopted
        hasMigrated = true
        return true
    }

    /// Set for the run in which settings were lifted out of a library, and
    /// cleared by the first reader -- it is a notice to deliver once, not a
    /// state to be in, and left standing it re-announced itself every time
    /// another library was opened.
    private var hasMigrated = false

    func consumeMigrationNotice() -> Bool {
        defer { hasMigrated = false }
        return hasMigrated
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? AtomicWrite.write(data, to: fileURL)
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var root: URL
    @Published private(set) var tree: [LibraryNode] = []
    /// Settings are the app's, not this folder's -- this is a passthrough so
    /// that `library.settings.x` still reads the way it always did.
    var settings: AppSettings {
        get { SettingsStore.shared.settings }
        set { SettingsStore.shared.settings = newValue }
    }

    private var settingsObserver: AnyCancellable?

    init(root: URL) {
        self.root = root
        // Views watch the library, and settings no longer live on it, so a
        // change to one has to reach them through here or nothing redraws.
        settingsObserver = SettingsStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        SettingsStore.shared.adoptOldLibraryFile(inLibrary: root)
        rescan()
    }

    var name: String { root.finderName }

    /// A cheap summary of the library's shape on disk, for noticing that
    /// something changed outside the app.
    ///
    /// Folder modification dates only. A folder's date changes whenever a file
    /// inside it is added, removed or renamed, so this catches everything that
    /// matters without stat-ing every PDF — which is what makes it cheap enough
    /// to check every couple of seconds.
    func contentsSignature() -> Int {
        var hasher = Hasher()
        let manager = FileManager.default
        var directories: [URL] = [root]
        if let walker = manager.enumerator(at: root,
                                           includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if url.lastPathComponent == LibraryPaths.dotDirectoryName {
                    walker.skipDescendants()
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    directories.append(url)
                }
            }
        }
        for url in directories.sorted(by: { $0.path < $1.path }) {
            hasher.combine(url.path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            hasher.combine(date?.timeIntervalSince1970 ?? 0)
        }
        return hasher.finalize()
    }

    // MARK: - Rearranging the library

    /// Renaming and moving lectures from inside the app, so the question file
    /// travels with its PDF.
    ///
    /// This is the real fix for orphaned question files: recovery exists because
    /// Finder does not know the two belong together, and every move made here
    /// keeps them together in the first place.
    enum FileError: LocalizedError {
        case exists(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .exists(let name):  return "\"\(name)\" already exists here."
            case .failed(let why):   return why
            }
        }
    }

    /// Returns the lecture's new URL.
    @discardableResult
    func rename(_ pdfURL: URL, to newName: String) throws -> URL {
        // A slash you typed is a colon on disk, the same swap the Finder makes.
        // Handed straight to `appendingPathComponent` it would read as a path
        // separator and the rename would land somewhere else entirely.
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines).asPOSIXName
        guard !trimmed.isEmpty else { throw FileError.failed("A lecture needs a name.") }
        let folder = pdfURL.deletingLastPathComponent()
        let target = folder.appendingPathComponent(trimmed).appendingPathExtension("pdf")
        guard target != pdfURL else { return pdfURL }
        return try relocate(pdfURL, to: target)
    }

    @discardableResult
    func move(_ pdfURL: URL, toFolder folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(pdfURL.lastPathComponent)
        guard target != pdfURL else { return pdfURL }
        return try relocate(pdfURL, to: target)
    }

    private func relocate(_ pdfURL: URL, to target: URL) throws -> URL {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: target.path) else {
            throw FileError.exists(target.finderName)
        }
        let newSidecar = target.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)

        // A leftover question file at the destination name is the usual reason a
        // move fails, and it is almost always an empty husk from an earlier
        // rename. Clear it out of the way if it holds nothing.
        if manager.fileExists(atPath: newSidecar.path), Self.isEmptySidecar(newSidecar) {
            try? manager.removeItem(at: newSidecar)
        }
        guard !manager.fileExists(atPath: newSidecar.path) else {
            throw FileError.exists(newSidecar.finderName
                + " — there are already questions filed under that name")
        }

        do {
            try manager.moveItem(at: pdfURL, to: target)
        } catch {
            throw FileError.failed("Couldn't move \(pdfURL.finderName): \(error.localizedDescription)")
        }
        // The questions and notes follow. If any of it fails the set is
        // separated, so everything already moved goes back rather than leaving a
        // mess recovery has to clean up.
        var undo: [(from: URL, to: URL)] = [(from: target, to: pdfURL)]
        for kind in AnkiIdentity.Companion.allCases {
            let companion = kind.url(for: pdfURL)
            guard manager.fileExists(atPath: companion.path) else { continue }
            // Both ends from the same case. The question file appends an
            // extension and the note file appends a word too, so a destination
            // rebuilt from the source's own path extension gets one of them
            // wrong -- and getting it wrong orphans the file.
            let destination = kind.url(for: target)
            do {
                try manager.moveItem(at: companion, to: destination)
                undo.append((from: destination, to: companion))
            } catch {
                for step in undo { try? manager.moveItem(at: step.from, to: step.to) }
                throw FileError.failed("Couldn't move \(companion.finderName): "
                    + "\(error.localizedDescription) Nothing was moved.")
            }
        }
        rescan()
        return target
    }

    /// Moves a lecture and its questions to the Trash, reporting where each file
    /// went so the action can be undone.
    ///
    /// The Trash rather than a real delete: it needs no confirmation dialog,
    /// undo can put it straight back, and if the app's undo history is ever lost
    /// the files are still sitting there.
    @discardableResult
    func trash(_ pdfURL: URL) throws -> [UndoLog.TrashedFile] {
        let manager = FileManager.default
        var moved: [UndoLog.TrashedFile] = []
        do {
            for url in [pdfURL] + AnkiIdentity.companions(of: pdfURL)
            where manager.fileExists(atPath: url.path) {
                var destination: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &destination)
                if let destination = destination as URL? {
                    moved.append(.init(inTrash: destination.path, original: url.path))
                }
            }
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
        rescan()
        return moved
    }

    @discardableResult
    func trashFolder(_ folder: URL) throws -> [UndoLog.TrashedFile] {
        guard folder != root else { throw FileError.failed("That's the library itself.") }
        var destination: NSURL?
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &destination)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
        rescan()
        guard let destination = destination as URL? else { return [] }
        return [.init(inTrash: destination.path, original: folder.path)]
    }

    /// Puts trashed files back where they came from.
    func restore(_ files: [UndoLog.TrashedFile]) {
        let manager = FileManager.default
        for file in files {
            let from = URL(fileURLWithPath: file.inTrash)
            let to = URL(fileURLWithPath: file.original)
            guard manager.fileExists(atPath: from.path),
                  !manager.fileExists(atPath: to.path) else { continue }
            try? manager.createDirectory(at: to.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            try? manager.moveItem(at: from, to: to)
        }
        rescan()
    }

    /// How many questions a lecture holds, read straight off disk. For telling
    /// someone what they are about to lose.
    func questionCount(at pdfURL: URL) -> Int {
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecar),
              let file = try? decoder.decode(SidecarFile.self, from: data) else { return 0 }
        return file.questions.filter { !$0.isEmpty }.count
    }

    /// Lectures inside a folder, at any depth.
    func lectures(under folder: URL) -> [URL] {
        allLectures().filter { $0.path.hasPrefix(folder.path + "/") }
    }

    /// A question file holding nothing worth keeping: no questions, no record of
    /// anything deleted since the last export.
    static func isEmptySidecar(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(SidecarFile.self, from: data) else { return false }
        return !file.questions.contains(where: { !$0.isEmpty })
            && (file.retiredQIDs ?? []).isEmpty
    }

    /// Sweeps away question files that hold nothing. They accumulate from
    /// renames and from deleting every question in a lecture, and an empty file
    /// beside a PDF looks exactly like questions you have lost.
    private func removeEmptySidecars() {
        let manager = FileManager.default
        let suffix = "." + AnkiIdentity.sidecarExtension
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            if url.lastPathComponent == LibraryPaths.dotDirectoryName {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(suffix),
                  !url.lastPathComponent.hasSuffix(".conflict" + suffix),
                  Self.isEmptySidecar(url) else { continue }
            try? manager.removeItem(at: url)
        }
    }

    @discardableResult
    func createFolder(named name: String, in parent: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).asPOSIXName
        guard !trimmed.isEmpty else { throw FileError.failed("A folder needs a name.") }
        let target = parent.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileError.exists(trimmed.asFinderName)
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
        rescan()
        return target
    }

    @discardableResult
    func renameFolder(_ folder: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, folder != root else {
            throw FileError.failed("A folder needs a name.")
        }
        let target = folder.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: true)
        guard target != folder else { return folder }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileError.exists(trimmed)
        }
        do {
            try FileManager.default.moveItem(at: folder, to: target)
        } catch {
            throw FileError.failed(error.localizedDescription)
        }
        rescan()
        return target
    }

    /// Every folder in the library, for a "move to" menu.
    func allFolders() -> [URL] {
        var out: [URL] = [root]
        func walk(_ nodes: [LibraryNode]) {
            for node in nodes where node.isFolder {
                out.append(node.url)
                walk(node.children)
            }
        }
        walk(tree)
        return out
    }


    /// Question files whose lecture has gone missing. Populated on every scan;
    /// the recovery window opens when this is not empty.
    @Published private(set) var orphans: [OrphanRecovery.Orphan] = []

    func rescan() {
        tree = Self.scan(directory: root)
        removeEmptySidecars()
        orphans = OrphanRecovery.scan(root: root, lectures: allLectures())
    }

    /// Puts a question file beside the lecture you chose, then rescans so the
    /// pair is correctly named on disk and cannot drift apart again.
    @discardableResult
    func adopt(_ orphan: OrphanRecovery.Orphan, pdfURL: URL) -> Bool {
        do {
            try OrphanRecovery.adopt(orphan, pdfURL: pdfURL)
        } catch {
            return false
        }
        rescan()
        return true
    }

    /// Moves an orphaned question file to the macOS Trash, then rescans the
    /// library so it is removed from recovery.
    @discardableResult
    func trashOrphan(_ orphan: OrphanRecovery.Orphan) -> Bool {
        do {
            var destination: NSURL?
            try FileManager.default.trashItem(at: orphan.sidecarURL, resultingItemURL: &destination)
        } catch {
            return false
        }
        rescan()
        return true
    }


    /// Deck name for a lecture: `AnkiFlow::<library>::<folders>::<pdf name>`.
    ///
    /// The root is the father, the library folder is its child, and the folders
    /// inside the library are the grandchildren -- so the shape of your decks in
    /// Anki is the shape of your folders on disk, with one name above them that
    /// says where they came from. The library's own name is taken from the
    /// folder rather than stored anywhere, which is what lets the app keep
    /// nothing per library at all.
    func deckName(for pdfURL: URL) -> String {
        var components: [String] = []
        let deckRoot = settings.resolvedDeckRoot
        if !deckRoot.isEmpty { components.append(deckRoot) }
        components.append(name)
        let rootParts = root.standardizedFileURL.pathComponents
        let pdfParts = pdfURL.standardizedFileURL.deletingLastPathComponent().pathComponents
        if pdfParts.count > rootParts.count {
            // Path components, so the Finder's spelling has to be put back the
            // same way it is for the lecture itself: a folder you called
            // "Block 1/2" is stored as "Block 1:2", and the deck should carry
            // the name you gave it.
            components.append(contentsOf: pdfParts[rootParts.count...].map(\.asFinderName))
        }
        components.append(pdfURL.lectureName)
        // "::" separates deck levels in Anki, so it cannot appear inside a name.
        return components.map { $0.replacingOccurrences(of: "::", with: "-") }
                         .joined(separator: "::")
    }

    /// Tag mirroring the deck path. Tags update on re-import even when deck
    /// placement does not, so this is the reliable record of where a card belongs.
    func pathTag(for pdfURL: URL) -> String {
        deckName(for: pdfURL)
            .replacingOccurrences(of: " ", with: "-")
    }

    func allLectures() -> [URL] {
        var out: [URL] = []
        func walk(_ nodes: [LibraryNode]) {
            for node in nodes {
                if node.isFolder { walk(node.children) } else { out.append(node.url) }
            }
        }
        walk(tree)
        return out
    }

    private static func scan(directory: URL) -> [LibraryNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [LibraryNode] = []
        var files: [LibraryNode] = []

        for url in entries {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if url.lastPathComponent == LibraryPaths.dotDirectoryName { continue }
                // Empty folders are shown. They used to be hidden as clutter,
                // which was defensible when the only folders were ones you had
                // already filled -- but you can make one in here now, and a
                // folder that vanishes the moment you create it is not clutter,
                // it is a bug.
                folders.append(LibraryNode(url: url, isFolder: true,
                                           children: scan(directory: url)))
            } else if url.pathExtension.lowercased() == "pdf" {
                files.append(LibraryNode(url: url, isFolder: false, children: []))
            }
        }

        let byName: (LibraryNode, LibraryNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }
}
