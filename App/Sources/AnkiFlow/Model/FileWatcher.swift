import Foundation

/// Notices when a file is changed by something other than this app.
///
/// Polls rather than using a vnode dispatch source, deliberately. The files
/// this watches are the ones a cloud folder rewrites -- a lecture annotated on
/// an iPad and synced back -- and sync does not edit a file in place, it writes
/// a new one and swaps it over. A vnode source is attached to a file
/// descriptor, so the swap shows up as a delete and the source then watches a
/// file that no longer exists, which is exactly the case this has to handle.
/// A `stat` every couple of seconds costs nothing and cannot be fooled by it.
@MainActor
final class FileWatcher {
    private var task: Task<Void, Never>?
    private var url: URL?
    private var known: Stamp?

    /// Modification date and size together: a sync that restores a file can
    /// give it a date the app has already seen, and a file edited within the
    /// same second keeps its date while changing length.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int
    }

    private static let interval: Duration = .seconds(2)

    /// Starts watching `url`, forgetting whatever it was watching before.
    /// `onChange` runs on the main actor, once per change that settles.
    func watch(_ url: URL, onChange: @escaping () -> Void) {
        stop()
        self.url = url
        known = Self.stamp(of: url)

        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self, let url = self.url else { return }
                let now = Self.stamp(of: url)
                guard now != self.known, now?.size ?? 0 > 0 else { continue }

                // Wait for it to stop moving. A file being written arrives in
                // pieces, and reading it mid-write gets you a document that is
                // either broken or half the lecture.
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, self.url == url else { return }
                let settled = Self.stamp(of: url)
                guard settled == now else { continue }   // still being written

                self.known = settled
                onChange()
            }
        }
    }

    /// Takes the current state as read, without calling back. For after this
    /// app writes the file itself -- saved markup is not news.
    func acknowledgeOwnWrite() {
        guard let url else { return }
        known = Self.stamp(of: url)
    }

    func stop() {
        task?.cancel()
        task = nil
        url = nil
        known = nil
    }

    deinit { task?.cancel() }

    private static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                             .fileSizeKey]) else { return nil }
        return Stamp(modified: values.contentModificationDate, size: values.fileSize ?? 0)
    }
}
