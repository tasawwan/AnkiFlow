import Foundation

/// The other kind of export: the lectures themselves, PDFs and question files
/// side by side in one zip.
///
/// This is not for Anki. It is for handing a course to somebody, moving to
/// another machine, or keeping a copy that does not depend on this app existing
/// — the question files are plain JSON, so the archive is readable with or
/// without AnkiFlow. Folder structure is preserved, so unzipping it somewhere
/// gives you a library you can open directly.
struct ArchiveExporter {
    let libraryRoot: URL
    /// Handed in rather than read from the store, because this runs off the main
    /// actor and the store lives on it.
    var settingsFile: URL?

    struct Result {
        var lectures = 0
        var questionFiles = 0
        var bytes = 0
        var url: URL?
    }

    func export(lectures: [URL], to destination: URL) throws -> Result {
        var zip = ZipWriter()
        var result = Result()

        for pdfURL in lectures {
            let relative = Self.relativePath(of: pdfURL, under: libraryRoot)
            if let data = try? Data(contentsOf: pdfURL) {
                zip.add(name: relative, data: data)
                result.lectures += 1
                result.bytes += data.count
            }
            let sidecar = pdfURL.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)
            if let data = try? Data(contentsOf: sidecar) {
                zip.add(name: Self.relativePath(of: sidecar, under: libraryRoot), data: data)
                result.questionFiles += 1
                result.bytes += data.count
            }
        }

        // Settings travel too, so deck root and tag choices survive the trip.
        // They belong to the app rather than the library now, and go in under a
        // name that says so -- restoring an archive should not silently adopt
        // the preferences of whoever made it.
        if let settingsFile, let data = try? Data(contentsOf: settingsFile) {
            zip.add(name: "AnkiFlow Settings.json", data: data)
        }

        try zip.finish().write(to: destination, options: .atomic)
        result.url = destination
        return result
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
