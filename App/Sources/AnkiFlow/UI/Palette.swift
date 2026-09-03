import SwiftUI

/// The app's two skins: **Editorial** in light, **Studio** in dark.
///
/// The *structure* is the same in both — hairlines instead of boxes, a serif for
/// question text, small-caps labels — because switching appearance shouldn't
/// rearrange the furniture. What changes is the palette, and one thing that
/// matters: in light the PDF page sits on warm paper behind a hairline; in dark
/// it floats on near-black with a shadow, so the slide is the only lit object
/// on screen.
struct Palette {
    /// Toolbar.
    let chrome: Color
    /// Sidebar ground.
    let sidebar: Color
    /// The field the PDF page sits on.
    let field: Color
    /// Question panel ground.
    let panel: Color
    /// A raised surface — menus, popovers, the focused question.
    let surface: Color

    let ink: Color
    let ink2: Color
    let dim: Color

    let line: Color
    let lineSoft: Color

    /// Selection and "this is on" — never the accent, which is reserved.
    let select: Color
    /// Attachment, and only attachment.
    let amber: Color

    /// Light draws a hairline round the page; dark drops a shadow instead.
    let pageBorder: Color
    let pageShadow: Color
    let pageShadowRadius: CGFloat

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .studio : .editorial
    }

    /// Editorial — warm paper, ink, hairlines. A writing tool that holds a PDF.
    static let editorial = Palette(
        chrome:     Color(red: 0.969, green: 0.961, blue: 0.941),   // #F7F5F0
        sidebar:    Color(red: 0.957, green: 0.949, blue: 0.925),   // #F4F2EC
        field:      Color(red: 0.937, green: 0.922, blue: 0.886),   // #EFEBE2
        panel:      Color(red: 0.984, green: 0.980, blue: 0.969),   // #FBFAF7
        surface:    Color(red: 1.000, green: 1.000, blue: 1.000),
        ink:        Color(red: 0.114, green: 0.106, blue: 0.086),   // #1D1B16
        ink2:       Color(red: 0.286, green: 0.271, blue: 0.239),
        dim:        Color(red: 0.502, green: 0.478, blue: 0.431),   // #807A6E
        line:       Color(red: 0.878, green: 0.859, blue: 0.820),   // #E0DBD1
        lineSoft:   Color(red: 0.925, green: 0.910, blue: 0.878),
        select:     Color(red: 0.549, green: 0.353, blue: 0.169),   // #8C5A2B
        amber:      Color(red: 0.878, green: 0.627, blue: 0.227),   // #E0A03A
        pageBorder: Color(red: 0.855, green: 0.831, blue: 0.780),
        pageShadow: Color.clear,
        pageShadowRadius: 0
    )

    /// Studio — navy chrome, the page on near-black. A lightbox for slides.
    static let studio = Palette(
        chrome:     Color(red: 0.090, green: 0.122, blue: 0.188),   // #171F30
        sidebar:    Color(red: 0.114, green: 0.153, blue: 0.235),   // #1D273C
        // The field stays the darkest thing on screen and lifts least: a slide
        // can only read as the lit object if what surrounds it does not.
        field:      Color(red: 0.055, green: 0.078, blue: 0.125),   // #0E1420
        panel:      Color(red: 0.102, green: 0.137, blue: 0.204),   // #1A2334
        surface:    Color(red: 0.149, green: 0.192, blue: 0.282),   // #263148
        ink:        Color(red: 0.914, green: 0.925, blue: 0.953),   // #E9ECF3
        ink2:       Color(red: 0.788, green: 0.820, blue: 0.886),
        dim:        Color(red: 0.596, green: 0.635, blue: 0.722),   // #98A2B8
        line:       Color(red: 0.200, green: 0.247, blue: 0.357),   // #333F5B
        lineSoft:   Color(red: 0.165, green: 0.208, blue: 0.314),   // #2A3550
        select:     Color(red: 0.431, green: 0.608, blue: 0.839),   // #6E9BD6
        amber:      Color(red: 0.878, green: 0.627, blue: 0.227),
        pageBorder: Color.white.opacity(0.07),
        pageShadow: Color.black.opacity(0.75),
        pageShadowRadius: 26
    )
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.editorial
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Shared type

enum AppFont {
    /// Question text is set in a serif, because writing questions is the job.
    static func question(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    /// Small-caps row labels: "ANSWER SLIDES".
    static let rowLabel = Font.system(size: 10, weight: .semibold)

    static let pageNumber = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

// MARK: - Appearance

/// Follows the system by default; Settings ▸ Appearance can pin it either way.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light:  return "Editorial (Light)"
        case .dark:   return "Studio (Dark)"
        }
    }

    /// nil hands the decision back to macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    func resolved(system: ColorScheme) -> ColorScheme {
        colorScheme ?? system
    }
}

/// Applies the chosen appearance and hands the matching palette down the tree.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let scheme = state.appearance.resolved(system: systemScheme)
        ContentView()
            .environment(\.palette, Palette.of(scheme))
            .preferredColorScheme(state.appearance.colorScheme)
    }
}
