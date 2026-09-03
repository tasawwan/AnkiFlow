import SwiftUI

/// A labelled row of attached pages.
///
/// Amber means attachment, here and nowhere else in the app. The row doubles as
/// a text field: click it and type "12-18, 22" when you already know the
/// numbers and don't want to scroll at all.
struct ChipRow: View {
    @Environment(\.palette) private var palette

    let label: String
    let pages: [Int]
    let pageCount: Int
    let isArmed: Bool
    let showArmedBadge: Bool
    let ghostPage: Int?
    /// Which of these pages carry a crop. One badge on the row rather than a
    /// mark per page, because chips collapse runs -- "12–18" is one chip
    /// covering seven slides, and there is nowhere honest to hang a per-page
    /// mark on it. Clicking the badge lists them so any one can be removed.
    var croppedPages: [Int] = []
    var onRemoveCrop: (Int) -> Void = { _ in }
    /// Clicking a row arms it. This replaces a keyboard shortcut for swapping
    /// sides -- pointing at the row you mean is self-explanatory, a shortcut for
    /// it was not.
    let onArm: () -> Void
    let onChange: ([Int]) -> Void

    @State private var isEditing = false
    @State private var showingCrops = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private let labelWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if showingCrops, !croppedPages.isEmpty {
                cropEditor
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isArmed ? palette.amber.opacity(0.09) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isArmed ? palette.amber.opacity(0.55) : palette.line, lineWidth: 1)
        )
        .onChange(of: croppedPages) { _, pages in
            if pages.isEmpty { showingCrops = false }
        }
    }

    /// One removable entry per cropped slide. Inline rather than in a popover,
    /// so removing three crops is three clicks in one place.
    private var cropEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(palette.line).padding(.vertical, 6)
            ForEach(croppedPages, id: \.self) { page in
                HStack(spacing: 8) {
                    Text("Slide \(page)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(palette.ink2)
                    Spacer(minLength: 0)
                    Button {
                        onRemoveCrop(page)
                    } label: {
                        Text("Remove crop")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, labelWidth + 10)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                Text(label.uppercased())
                    .font(AppFont.rowLabel)
                    .tracking(0.6)
                    .foregroundStyle(isArmed ? palette.ink2 : palette.dim)
                if showArmedBadge && isArmed {
                    Circle()
                        .fill(palette.amber)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            if isEditing {
                TextField("12-18, 22", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(palette.ink)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                chips
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            if pages.isEmpty && ghostPage == nil {
                Text("none yet")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim.opacity(0.7))
            }

            ForEach(runs, id: \.self) { run in
                Text(run)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(palette.amber.opacity(0.28), in: Capsule())
            }

            // What ⌘E would take if you pressed it now.
            if let ghostPage {
                Text("…\(ghostPage)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .overlay(
                        Capsule().strokeBorder(
                            palette.amber.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                    )
            }

            if !croppedPages.isEmpty {
                // A plain badge, not a menu control: it is a count first and a
                // button second. Clicking opens the list inline, the same way
                // clicking the chips opens the page field.
                Button {
                    showingCrops.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "crop")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("\(croppedPages.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(showingCrops ? palette.ink : palette.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule().fill(showingCrops ? palette.amber.opacity(0.18) : Color.clear)
                    )
                    .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(croppedPages.count == 1
                      ? "1 slide is cropped — click to edit"
                      : "\(croppedPages.count) slides are cropped — click to edit")
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle())
        // Click to arm; click the armed row again to type numbers.
        //
        // It used to do both at once, and that quietly ate keystrokes: arming
        // the row opened the text field, ⌘T toggled a page behind it, and when
        // the field lost focus it wrote its stale draft back over the change. It
        // looked like ⌘T hadn't registered.
        .onTapGesture {
            if isArmed {
                draft = PageSet.describe(pages).replacingOccurrences(of: "–", with: "-")
                isEditing = true
                fieldFocused = true
            } else {
                onArm()
            }
        }
        .help(isArmed ? "Click again to type page numbers" : "Click to aim ⌘E and ⌘T at this row")
    }

    private func commit() {
        // Only write back if the text actually differs from what is there now.
        // Anything else risks a stale draft overwriting a change made by the
        // keyboard while this field happened to be open.
        let parsed = PageSet.parse(draft, pageCount: pageCount)
        if parsed != PageSet.normalise(pages) { onChange(parsed) }
        isEditing = false
    }

    /// Collapse consecutive pages into "12–18", so a fifteen-slide answer is one
    /// chip rather than fifteen.
    private var runs: [String] {
        let described = PageSet.describe(pages)
        guard !described.isEmpty else { return [] }
        return described.components(separatedBy: ", ")
    }
}
