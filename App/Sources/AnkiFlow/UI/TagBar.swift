import SwiftUI

/// Tag checkboxes, sitting at the bottom of the question box they belong to.
///
/// Pinned tags are always visible — no dropdown, no search, no click to reveal.
/// That is the point: tagging has to cost one click or it doesn't happen while
/// you're moving. Which tags are pinned is set in Settings ▸ Tags.
///
/// Takes a `qid` rather than a `Question`, for the same reason QuestionCard
/// does: a captured struct goes stale and the checkbox stops reflecting reality.
struct TagBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    let qid: String

    @State private var showMore = false
    @State private var newTag = ""

    private var question: Question? { state.document?.question(qid: qid) }
    private var tags: [String] { question?.tags ?? [] }
    private var pinned: [TagDefinition] { state.library?.settings.pinnedTags ?? [] }
    private var unpinned: [TagDefinition] { state.library?.settings.unpinnedTags ?? [] }

    /// Tags on this question that aren't in the library's list at all.
    private var strays: [String] {
        let known = Set((state.library?.settings.tags ?? []).map(\.name))
        return tags.filter { !known.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(palette.line).padding(.vertical, 9)

            HStack(alignment: .center, spacing: 10) {
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
        let name = newTag.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        if let library = state.library, !library.settings.tags.contains(where: { $0.name == name }) {
            library.settings.tags.append(TagDefinition(name: name, pinned: false))
        }
        if !tags.contains(name) { toggle(name) }
        newTag = ""
    }

    /// Reads the live question every time, so ticking a box actually sticks.
    /// Whatever is ticked here goes onto the Anki note as a real tag at export.
    /// Routed through AppState so it lands on the undo stack like every other
    /// structural change.
    private func toggle(_ name: String) {
        state.toggleTag(name, on: qid)
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
