import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            AppIconMark()
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 6) {
                Text("AnkiFlow")
                    .font(.system(size: 26, weight: .semibold))
                Text(versionLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if let buildLine {
                    Text(buildLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Text("Lecture PDFs into Anki review decks.")
                    .font(.system(size: 13))
                    .padding(.top, 6)

                Spacer(minLength: 14)

                Text("Tasawwar Rahman")
                    .font(.system(size: 13, weight: .medium))
                Text("© 2026 Tasawwar Rahman. All rights reserved.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 500, height: 244)
    }

    /// Read from the bundle, never hardcoded -- make-app.sh derives it from the
    /// nearest git tag, so this is the tag by another name. `swift run` has no
    /// bundle to read, which is worth saying out loud rather than showing a
    /// version that isn't real.
    private var versionLine: String {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !short.isEmpty else { return "Running from source" }
        return "Version \(short)"
    }

    /// The exact commit, shown only when it says something the version doesn't:
    /// `1.2-3-gabc1234-dirty` means three commits past v1.2 with uncommitted
    /// changes. Selectable, so it can be pasted into a bug report.
    private var buildLine: String? {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "AFBuild") as? String,
              !build.isEmpty else { return nil }
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return build == short ? nil : build
    }
}

/// The app mark, drawn rather than loaded, so it renders identically whether the
/// app is running from a bundle or straight from `swift run`.
struct AppIconMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let unit = side / 64

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(Theme.navy)

                page(x: 6.5, y: 13, w: 29, h: 38, unit: unit)
                page(x: 38.5, y: 13, w: 19, h: 38, unit: unit)

                block(x: 11, y: 17.5, w: 20, h: 11.5, unit: unit, color: Theme.amber, radius: 1.8)
                block(x: 11, y: 33, w: 20, h: 2.8, unit: unit, color: Theme.slate, radius: 1.4)
                block(x: 11, y: 39.5, w: 13, h: 2.8, unit: unit, color: Theme.slate, radius: 1.4)

                block(x: 41.5, y: 17.5, w: 13, h: 8.5, unit: unit, color: Theme.amber, radius: 2)
                block(x: 41.5, y: 28.5, w: 13, h: 8.5, unit: unit, color: Theme.slate, radius: 2)
                block(x: 41.5, y: 39.5, w: 13, h: 8.5, unit: unit, color: Theme.slate, radius: 2)
            }
            .frame(width: side, height: side)
        }
    }

    private func page(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, unit: CGFloat) -> some View {
        block(x: x, y: y, w: w, h: h, unit: unit, color: Theme.paper, radius: 2.5)
    }

    private func block(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                       unit: CGFloat, color: Color, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius * unit)
            .fill(color)
            .frame(width: w * unit, height: h * unit)
            .offset(x: x * unit, y: y * unit)
    }
}
