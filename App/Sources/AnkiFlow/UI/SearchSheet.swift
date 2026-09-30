import SwiftUI

/// The three wider searches. ⌘F stays inline in the lecture you're reading;
/// anything broader gets a list, because a result you have to travel to needs a
/// name and a place printed beside it.
///
/// One sheet with a scope control rather than three sheets: these are two axes
/// of the same question — slides or questions, here or everywhere — so having
/// landed in the wrong one, switching should cost a click rather than a
/// different keystroke you have to remember.
struct SearchSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.dim)
                TextField(placeholder, text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.ink)
                    .focused($focused)
                    .onSubmit { state.submitSearch() }
                    .onExitCommand { dismiss() }
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 10)

            Picker("", selection: $state.searchScope) {
                ForEach(AppState.SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 11)

            if state.searchIsLibraryWide, let lecture = state.searchLecture {
                HStack(spacing: 6) {
                    Button {
                        state.searchLecture = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9, weight: .semibold))
                            Text("All lectures")
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.dim)
                    }
                    .buttonStyle(.plain)
                    Text("·").foregroundStyle(palette.dim.opacity(0.6))
                    Text(lecture)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.ink2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 9)
            }

            Divider().overlay(palette.line)

            content

            Divider().overlay(palette.line)
            HStack {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 740, height: 580)
        .background(palette.panel)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var content: some View {
        if state.searchQuery.trimmingCharacters(in: .whitespaces).count < 2 {
            hint("Type at least two characters.")
        } else if state.searchHits.isEmpty {
            hint(state.searchScope.runsOnSubmitOnly
                 ? "Press Return to search every lecture's slides."
                 : "Nothing matches that.")
        } else if state.searchIsLibraryWide && state.searchLecture == nil {
            // Which lectures mention this, before which lines do. Forty
            // lectures' worth of hits in one flat list is not something anyone
            // reads; the lecture is the unit you actually think in.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.searchLectures, id: \.lecture) { entry in
                        Button {
                            state.searchLecture = entry.lecture
                        } label: {
                            HStack(spacing: 10) {
                                Text(entry.lecture)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(palette.ink)
                                Spacer(minLength: 8)
                                Text("\(entry.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(palette.ink2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.amber.opacity(0.20)))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(palette.dim)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(palette.lineSoft)
                    }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.visibleSearchHits) { hit in
                        Button { state.open(hit) } label: { row(hit) }
                            .buttonStyle(.plain)
                        Divider().overlay(palette.lineSoft)
                    }
                }
            }
        }
    }

    private func row(_ hit: AppState.SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.title)
                .font(AppFont.question(14))
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Text(hit.lecture).foregroundStyle(palette.dim)
                if !hit.detail.isEmpty {
                    Text(hit.detail).foregroundStyle(palette.dim.opacity(0.8))
                }
            }
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12.5)).foregroundStyle(palette.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: String {
        switch state.searchScope {
        case .librarySlides:    return "Search every lecture's slides — Return to run"
        case .libraryQuestions: return "Search every question"
        }
    }

    private var footer: String {
        if state.isSearching { return "Searching…" }
        let count = state.searchHits.count
        guard count > 0 else { return "" }
        let noun = state.searchScope == .librarySlides ? "slide" : "question"
        let hits = count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
        guard state.searchIsLibraryWide, state.searchLecture == nil else { return hits }
        let lectures = state.searchLectures.count
        return "\(hits) in \(lectures) lecture\(lectures == 1 ? "" : "s")"
    }
}
