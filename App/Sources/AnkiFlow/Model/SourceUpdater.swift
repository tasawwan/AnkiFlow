import AppKit
import SwiftUI

/// Updating a self-built app means two commands in a terminal: pull the new
/// source, rebuild the bundle. This puts them one menu item away.
///
/// It copies the command and opens Terminal in the right folder. It does not
/// run anything. That is the whole design: an app that can silently execute a
/// shell command it assembled itself is an app that can be talked into
/// executing a different one, and `git pull` fetches code from the network.
/// You see the command, you press Return, and if it looks wrong you don't.
///
/// The checkout path comes from `AFSourcePath`, which make-app.sh writes into
/// Info.plist at build time -- the build script is standing in the source
/// folder, so it knows the answer without anyone being asked. If the key is
/// missing (a `swift run` build) or the folder has since moved, it falls back
/// to asking once and remembering.
@MainActor
final class SourceUpdater: ObservableObject {
    @Published var showResult = false
    @Published private(set) var copiedCommand: String?
    @Published private(set) var problem: String?

    private let savedPathKey = "sourceCheckoutPath"

    /// Written by make-app.sh. Absent when running from `swift run`.
    private var bundledPath: String? {
        Bundle.main.object(forInfoDictionaryKey: "AFSourcePath") as? String
    }

    private var savedPath: String? {
        UserDefaults.standard.string(forKey: savedPathKey)
    }

    /// A remembered answer wins: if the folder moved and you pointed the app at
    /// the new place, the stale build-time path shouldn't override that.
    var checkoutURL: URL? {
        for path in [savedPath, bundledPath].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: path)
            if Self.looksLikeCheckout(url) { return url }
        }
        return nil
    }

    /// Both files, not either: `.git` alone could be any repository, and
    /// make-app.sh alone could be a copy with no remote to pull from.
    static func looksLikeCheckout(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appendingPathComponent("App/make-app.sh").path)
            && manager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func command(for url: URL) -> String {
        "cd \(shellQuoted(url.path)) && git pull && cd App && ./make-app.sh --install"
    }

    /// Paths contain spaces far more often than anyone expects. Inside single
    /// quotes the shell treats everything literally except another single
    /// quote, which has to be closed, escaped, and reopened.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The menu action

    func begin() {
        if let url = checkoutURL {
            handOff(url)
        } else {
            locateCheckout()
        }
    }

    /// Offered in the result sheet, for when the source folder has moved.
    func locateCheckout() {
        let panel = NSOpenPanel()
        panel.title = "Locate the AnkiFlow source"
        panel.message = "Choose the folder you cloned from GitHub — the one containing App and README.md."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        guard Self.looksLikeCheckout(chosen) else {
            copiedCommand = nil
            problem = "\(chosen.lastPathComponent) doesn't look like an AnkiFlow checkout — "
                + "it has no App/make-app.sh, or it isn't a git repository. "
                + "Choose the folder you ran git clone into."
            showResult = true
            return
        }

        UserDefaults.standard.set(chosen.path, forKey: savedPathKey)
        handOff(chosen)
    }

    private func handOff(_ url: URL) {
        let command = Self.command(for: url)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        // Opening the *folder* with Terminal starts the new window already in
        // it, so the command is correct even if the paste goes astray.
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                    configuration: configuration) { _, _ in }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        problem = nil
        copiedCommand = command
        showResult = true
    }
}
