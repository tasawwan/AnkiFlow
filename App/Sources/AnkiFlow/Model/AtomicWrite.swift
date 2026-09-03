import Foundation

/// Writes that cannot leave a truncated file behind.
///
/// A half-written sidecar is the one failure in this app that loses work in a
/// way nothing recovers from. `Data.write(options: .atomic)` writes to a
/// temporary file in the same directory and then *renames* it over the target,
/// and rename is atomic at the filesystem level: after a crash or a full disk
/// you have either the whole old file or the whole new one, never half of
/// either.
///
/// There is deliberately no `.bak` sibling. It added a second file next to
/// every PDF for a job that `.ankiflow/history/` already does better -- that
/// keeps the last twenty *timestamped* versions per lecture, out of the way,
/// browsable. One stale copy called `.bak` was clutter pretending to be safety.
enum AtomicWrite {
    /// `hidden` sets the Finder hidden flag afterwards. It has to be *after*:
    /// an atomic write replaces the file with a freshly created one, which
    /// doesn't inherit the old file's flags.
    static func write(_ data: Data, to url: URL, hidden: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        setHidden(hidden, at: url)
    }

    /// Uses the filesystem's hidden flag rather than a leading dot, so the file
    /// keeps a readable name, git still tracks it, and nothing has to be
    /// renamed to change the setting.
    static func setHidden(_ hidden: Bool, at url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isHidden = hidden
        try? target.setResourceValues(values)
    }
}
