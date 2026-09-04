import Foundation
import PDFKit

/// Where AnkiFlow keeps its own files inside a lecture library.
enum LibraryPaths {
    static let dotDirectoryName = ".ankiflow"

    static func dotDirectory(inLibrary root: URL) -> URL {
        root.appendingPathComponent(dotDirectoryName, isDirectory: true)
    }

    static func settingsURL(inLibrary root: URL) -> URL {
        dotDirectory(inLibrary: root).appendingPathComponent("library.json")
    }

    static func cacheDirectory(inLibrary root: URL) -> URL {
        dotDirectory(inLibrary: root).appendingPathComponent("cache", isDirectory: true)
    }

    /// Walk up from a sidecar until we find the library root (the folder holding
    /// `.ankiflow`), so history lands in one place per library.
    static func historyDirectory(forSidecar sidecar: URL) -> URL? {
        var dir = sidecar.deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(dotDirectoryName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.appendingPathComponent("history", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

// MARK: - Tags

/// A tag you can put on cards. `pinned` tags get a permanent checkbox at the
/// bottom of the question panel; the rest live behind the "More tags" field.
struct TagDefinition: Codable, Identifiable, Equatable {
    var name: String
    var pinned: Bool

    var id: String { name }

    init(name: String, pinned: Bool = true) {
        self.name = name
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
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

/// Per-library settings, stored in `.ankiflow/library.json`.
struct LibrarySettings: Codable, Equatable {
    var imageWidth: Int = 1600
    var imageFormat: ImageFormat = .auto
    var jpegQuality: Double = 0.82
    var revealAfterExport: Bool = true
    /// Bumped when rendering settings change, so cached images and content
    /// hashes both invalidate together.
    var renderVersion: Int = 1
    /// The top-level Anki deck everything hangs off. Editable, but see the
    /// warning in Settings: existing cards never move deck on re-import, so
    /// changing this after an export splits your collection in two.
    var deckRoot: String = AnkiIdentity.deckRoot
    /// Keep the per-lecture question files out of Finder's way. They sit beside
    /// your PDFs, so by default they're hidden rather than doubling the
    /// apparent contents of every folder.
    var hideSidecarFiles: Bool = true
    /// Tags offered in the question panel. Order here is the order shown.
    var tags: [TagDefinition] = LibrarySettings.starterTags

    static let starterTags: [TagDefinition] = [
        TagDefinition(name: "high-yield"),
        TagDefinition(name: "clinical-correlation")
    ]

    /// Never empty, and never containing "::" -- that separates deck levels.
    var resolvedDeckRoot: String {
        LibrarySettings.sanitisedDeckRoot(deckRoot)
    }

    static func sanitisedDeckRoot(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "::", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? AnkiIdentity.deckRoot : cleaned
    }

    /// What a brand-new library starts with: its own folder name.
    ///
    /// Applied only when there is no settings file yet. A library that has one
    /// keeps whatever it says, even if that is the old "AnkiFlow" default --
    /// changing an existing library's deck root would leave every card already
    /// in Anki sitting under the old name, because Anki never moves existing
    /// cards between decks on import. Splitting someone's collection in two is
    /// not a thing to do on their behalf.
    static func defaultDeckRoot(for root: URL) -> String {
        sanitisedDeckRoot(root.lastPathComponent)
    }

    var pinnedTags: [TagDefinition] { tags.filter(\.pinned) }
    var unpinnedTags: [TagDefinition] { tags.filter { !$0.pinned } }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth) ?? 1600
        imageFormat = try c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat) ?? .auto
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.82
        revealAfterExport = try c.decodeIfPresent(Bool.self, forKey: .revealAfterExport) ?? true
        renderVersion = try c.decodeIfPresent(Int.self, forKey: .renderVersion) ?? 1
        deckRoot = try c.decodeIfPresent(String.self, forKey: .deckRoot) ?? AnkiIdentity.deckRoot
        hideSidecarFiles = try c.decodeIfPresent(Bool.self, forKey: .hideSidecarFiles) ?? true
        tags = try c.decodeIfPresent([TagDefinition].self, forKey: .tags) ?? LibrarySettings.starterTags
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
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var root: URL
    @Published private(set) var tree: [LibraryNode] = []
    @Published var settings: LibrarySettings { didSet { saveSettings() } }

    init(root: URL) {
        self.root = root
        let settingsURL = LibraryPaths.settingsURL(inLibrary: root)
        if let data = try? Data(contentsOf: settingsURL),
           let loaded = try? JSONDecoder().decode(LibrarySettings.self, from: data) {
            self.settings = loaded
        } else {
            var fresh = LibrarySettings()
            fresh.deckRoot = LibrarySettings.defaultDeckRoot(for: root)
            self.settings = fresh
        }
        rescan()
    }

    var name: String { root.lastPathComponent }

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
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            throw FileError.exists(target.lastPathComponent)
        }
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let newSidecar = target.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)

        // A leftover question file at the destination name is the usual reason a
        // move fails, and it is almost always an empty husk from an earlier
        // rename. Clear it out of the way if it holds nothing.
        if manager.fileExists(atPath: newSidecar.path), Self.isEmptySidecar(newSidecar) {
            try? manager.removeItem(at: newSidecar)
        }
        guard !manager.fileExists(atPath: newSidecar.path) else {
            throw FileError.exists(newSidecar.lastPathComponent
                + " — there are already questions filed under that name")
        }

        do {
            try manager.moveItem(at: pdfURL, to: target)
        } catch {
            throw FileError.failed("Couldn't move \(pdfURL.lastPathComponent): \(error.localizedDescription)")
        }
        // The questions follow. If this half fails the pair is separated, so put
        // the PDF back rather than leaving a mess recovery has to clean up.
        if manager.fileExists(atPath: sidecar.path) {
            do {
                try manager.moveItem(at: sidecar, to: newSidecar)
            } catch {
                try? manager.moveItem(at: target, to: pdfURL)
                throw FileError.failed("Couldn't move \(sidecar.lastPathComponent): "
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
        let sidecar = pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        var moved: [UndoLog.TrashedFile] = []
        do {
            for url in [pdfURL, sidecar] where manager.fileExists(atPath: url.path) {
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileError.failed("A folder needs a name.") }
        let target = parent.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileError.exists(trimmed)
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


    /// Deck name for a lecture: `AnkiFlow::<folders>::<pdf name>`.
    /// Folder structure is the deck structure.
    func deckName(for pdfURL: URL) -> String {
        var components: [String] = [settings.resolvedDeckRoot]
        let rootParts = root.standardizedFileURL.pathComponents
        let pdfParts = pdfURL.standardizedFileURL.deletingLastPathComponent().pathComponents
        if pdfParts.count > rootParts.count {
            components.append(contentsOf: pdfParts[rootParts.count...])
        }
        components.append(pdfURL.deletingPathExtension().lastPathComponent)
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

    private func saveSettings() {
        let url = LibraryPaths.settingsURL(inLibrary: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? AtomicWrite.write(data, to: url)
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
