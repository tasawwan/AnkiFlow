import SwiftUI

/// ⌘F. A thin bar above the PDF, not a floating panel: it belongs to the
/// lecture you're reading, and a panel would cover the slide you're searching.
///
/// It searches the PDF, not your questions. Finding the slide that mentions a
/// term is what you do *while writing* a question, so the result is a jump to
/// that page with the hit highlighted, leaving your cursor free to come back to
/// the text box.
struct FindBar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.dim)

            TextField("Find in this lecture", text: $state.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.ink)
                .focused($focused)
                .onSubmit { state.stepFind(1) }
                .onExitCommand { state.closeFind() }

            if !state.findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(countLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
                    .monospacedDigit()
            }

            Button { state.stepFind(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(state.findMatchCount == 0)

            Button { state.stepFind(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(state.findMatchCount == 0)

            Button { state.closeFind() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.ink2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
        .onAppear { focused = true }
    }

    private var countLabel: String {
        state.findMatchCount == 0 ? "none" : "\(state.findIndex + 1) of \(state.findMatchCount)"
    }
}
