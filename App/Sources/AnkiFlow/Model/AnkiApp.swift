import Foundation
import AppKit

/// Finding, launching and recognising the Anki desktop app.
///
/// This exists so "Anki isn't answering" can be turned into a specific reason
/// with a specific button. Port 8765 being dead has three quite different
/// causes, and telling someone to install an add-on when Anki simply isn't
/// running — or isn't installed — is worse than saying nothing.
enum AnkiApp {
    /// Anki has used more than one bundle identifier over its life, and a fork
    /// or a repackaged build may use another. Checked in order.
    static let bundleIdentifiers = ["net.ankiweb.dtop", "net.ichi2.anki"]

    static let downloadURL = URL(string: "https://apps.ankiweb.net")!

    /// Where Anki is on disk, if it is.
    static var location: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: "/Applications/Anki.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static var isInstalled: Bool { location != nil }

    static var isRunning: Bool {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { bundleIdentifiers.contains($0.bundleIdentifier ?? "") }) {
            return true
        }
        // A build with an identifier we don't know still shows up by name.
        return running.contains { $0.localizedName == "Anki" }
    }

    /// Launches Anki and brings it forward. Returns false if it isn't installed.
    @discardableResult
    static func launch() -> Bool {
        guard let location else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: location, configuration: configuration)
        return true
    }

    /// What to say when the port doesn't answer.
    enum Situation {
        /// Anki isn't on this Mac.
        case notInstalled
        /// Installed but closed — one button fixes it.
        case notRunning
        /// Running and still not answering, so the add-on is the missing part.
        /// Only concluded when Anki is definitely up: telling someone to install
        /// an add-on because they had Anki closed is the wrong advice loudly.
        case addOnMissing

        static var current: Situation {
            if !AnkiApp.isInstalled { return .notInstalled }
            return AnkiApp.isRunning ? .addOnMissing : .notRunning
        }
    }
}
