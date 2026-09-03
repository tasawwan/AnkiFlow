import Foundation
import SwiftUI

/// Asks GitHub whether a newer release exists.
///
/// Deliberately the smallest thing that works: it fetches the latest release
/// from the public API, compares the tag to this build's version, and if you're
/// behind it hands you off to SourceUpdater. Nothing is downloaded, nothing is
/// installed, and no code runs as a result — so there is no update path for
/// anyone to attack.
///
/// It does not offer the release page as a download, because there is nothing
/// there to download: this app is built from source, and the release notes are
/// already in the alert.
///
/// Sparkle would do the whole job (background download, signature check, install
/// on quit) but brings an appcast feed, a second signing key you must not lose,
/// and real infrastructure. For an app that gets a handful of releases, a link
/// is the right size of solution.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: String
        let name: String?
        let body: String?
        let prerelease: Bool
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name, body, prerelease, draft
        }

        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
    }

    @Published private(set) var available: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    /// Set only by an explicit check, so an automatic one never nags.
    @Published var showResult = false

    private let lastCheckKey = "lastUpdateCheck"
    private let skipVersionKey = "skippedUpdateVersion"

    /// Empty when running from `swift run`, which has no bundle to read.
    var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var apiURL: URL? {
        URL(string: "https://api.github.com/repos/\(AnkiIdentity.repository)/releases/latest")
    }

    // MARK: - Checking

    /// Called at launch. Quiet: at most once a day, never from a dev build, and
    /// it only sets `available` — nothing appears in your way.
    func checkInBackground() async {
        guard currentVersion != nil else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let day: TimeInterval = 60 * 60 * 24
        guard Date().timeIntervalSince1970 - last > day else { return }
        await check(announce: false)
    }

    /// Called from AnkiFlow ▸ Check for Updates. Always talks back, including to
    /// say you're up to date, because silence after clicking a menu item reads
    /// as a broken menu item.
    func checkNow() async {
        await check(announce: true)
    }

    private func check(announce: Bool) async {
        guard let apiURL, !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.message("No response from GitHub.")
            }
            // 404 is the normal answer for a repo with no releases yet.
            if http.statusCode == 404 {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                available = nil
                if announce { showResult = true }
                return
            }
            guard http.statusCode == 200 else {
                throw UpdateError.message("GitHub answered \(http.statusCode).")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            guard !release.draft, !release.prerelease,
                  let current = currentVersion,
                  Self.isNewer(release.version, than: current) else {
                available = nil
                if announce { showResult = true }
                return
            }

            let skipped = UserDefaults.standard.string(forKey: skipVersionKey)
            if !announce, skipped == release.version { return }

            available = release
            if announce { showResult = true }
        } catch {
            lastError = error.localizedDescription
            if announce { showResult = true }
        }
    }

    func skipCurrentOffer() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: skipVersionKey)
        self.available = nil
    }

    // MARK: - Version comparison

    /// Numeric, component by component, so 1.10 beats 1.9 — which a plain
    /// string comparison gets backwards.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = local.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
