import SwiftUI

/// Tag checkboxes, sitting at the bottom of the thing they belong to.
///
/// Pinned tags are always visible — no dropdown, no search, no click to reveal.
/// That is the point: tagging has to cost one click or it doesn't happen while
/// you're moving. Which tags are pinned is set in Settings ▸ Tags.
///
/// Takes the tags and a way to toggle one, rather than reaching for a question
/// itself. A card and a lecture question are tagged identically and keep their
/// tags in different places, and one bar serving both is what stops the two from
/// drifting apart. Whoever hands the tags in is responsible for reading them
/// live — a captured struct goes stale and the checkbox stops reflecting
/// reality.
struct TagBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    let tags: [String]
    /// A rule above the bar. Wanted on a card, where it separates the tags from
    /// the fields; not wanted inside a lecture question, which is already inside
    /// a box of its own.
    var showsDivider = true
    let onToggle: (String) -> Void
    /// Yield is one choice, not three tags, so it gets its own channel: the
    /// caller swaps whichever yield is on for the new one in a single edit.
    /// Done through `onToggle` it would be two or three, which is two or three
    /// presses of ⌘Z to undo picking a radio button.
    let onSetYield: (String?) -> Void

    @State private var showMore = false
    @State private var newTag = ""

    /// Yield never appears as a checkbox -- it is the button beside them.
    private var pinned: [TagDefinition] {
        (state.library?.settings.pinnedTags ?? []).filter { !TagDefinition.isYield($0.name) }
    }
    private var unpinned: [TagDefinition] {
        (state.library?.settings.unpinnedTags ?? []).filter { !TagDefinition.isYield($0.name) }
    }

    /// Tags on this question that aren't in the library's list at all.
    private var strays: [String] {
        let known = Set((state.library?.settings.tags ?? []).map(\.name))
        return tags.filter { !known.contains($0) && !TagDefinition.isYield($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                Divider().overlay(palette.line).padding(.vertical, 9)
            }

            HStack(alignment: .center, spacing: 10) {
                YieldButton(tags: tags, onSet: onSetYield)
                FlowLayout(spacing: 10) {
                    ForEach(pinned) { checkbox($0.name) }
                    ForEach(strays, id: \.self) { checkbox($0) }
                }

                Spacer(minLength: 0)

                Button {
                    showMore.toggle()
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.dim)
                .help("Other tags")
                .popover(isPresented: $showMore, arrowEdge: .bottom) { morePopover }
            }
        }
    }

    private func checkbox(_ name: String) -> some View {
        let isOn = tags.contains(name)
        return Button {
            toggle(name)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? palette.select : palette.dim.opacity(0.75))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? palette.ink : palette.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var morePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if unpinned.isEmpty {
                Text("Every tag is pinned.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
            } else {
                Text("NOT PINNED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(unpinned) { checkbox($0.name) }
            }

            Divider()

            HStack(spacing: 6) {
                TextField("New tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(addNewTag)
                Button("Add", action: addNewTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Manage the list in Settings ▸ Tags (⌘,)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minWidth: 220)
    }

    private func addNewTag() {
        let name = TagDefinition.normalise(newTag)
        guard !name.isEmpty else { return }
        if let library = state.library, !library.settings.tags.contains(where: { $0.name == name }) {
            library.settings.tags.append(TagDefinition(name: name, pinned: false))
        }
        if !tags.contains(name) { onToggle(name) }
        newTag = ""
    }

    /// Whatever is ticked here goes onto the Anki note as a real tag at export.
    private func toggle(_ name: String) { onToggle(name) }
}

/// How much this card matters, as one button that says so.
///
/// A button rather than three checkboxes, and one rather than a segmented row:
/// yield is a single value, the control should read as that value, and the
/// answer is nearly always the default. Clicking walks Normal → High → Low and
/// round again, the way the comfort button in the topics panel does — a misclick
/// costs two more clicks rather than a trip into a menu.
struct YieldButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    let tags: [String]
    let onSet: (String?) -> Void

    private var yield: Yield { Yield.of(tags) }

    /// Amber for high, because amber is this app's word for "this matters".
    /// Normal is deliberately unremarkable — it is the state most cards are in,
    /// and colouring it would make every card look flagged.
    private var tint: Color {
        switch yield {
        case .high:   return palette.amber
        case .normal: return palette.dim
        case .low:    return palette.dim.opacity(0.8)
        }
    }

    var body: some View {
        Button {
            let wanted = yield.next
            if let tag = wanted.tag { register(tag) }
            onSet(wanted.tag)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: yield.symbol)
                    .font(.system(size: 9.5))
                Text(yield.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(yield == .normal ? palette.dim : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(yield == .normal ? Color.clear : tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(yield == .normal ? palette.line : tint.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Click for \(yield.next.label) — normal is the default and carries no tag")
    }

    /// A library made before yields existed has never heard of them. Using one
    /// puts it in the list, so it shows up in Settings and in the filter row
    /// alongside every other tag.
    private func register(_ name: String) {
        guard let library = state.library,
              !library.settings.tags.contains(where: { $0.name == name }) else { return }
        library.settings.tags.append(TagDefinition(name: name, pinned: false))
    }
}

/// Wraps its children onto as many lines as they need. Tag lists grow, and a
/// horizontal scroller for two checkboxes would be silly.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
