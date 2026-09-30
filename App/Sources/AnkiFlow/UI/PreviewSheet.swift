import SwiftUI

/// ⌘P — the cards, before they are cards.
///
/// Half proofing, half review. Proofing is the half that earns it: a crop that
/// clipped the label, a mask over the wrong structure, a ⌘E that took 12–18 when
/// you meant 12–8. Those are invisible in the panel and obvious here, and right
/// now the only place you find them is Anki, days later, one at a time.
///
/// No grading buttons. Nothing is saved, and buttons that look like grading but
/// change nothing would be a lie about what this is.
struct PreviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: PreviewSession

    enum Layout: String, CaseIterable, Identifiable {
        case cards, scroll
        var id: String { rawValue }
        var label: String { self == .cards ? "Flashcards" : "Continuous" }
    }

    @State private var layout: Layout = .cards
    /// `.onKeyPress` only fires on a focused view, and a plain VStack is never
    /// focused — which is why none of the keys did anything.
    @FocusState private var keyboard: Bool

    init(settings: AppSettings, cacheDirectory: URL) {
        _session = StateObject(wrappedValue: PreviewSession(settings: settings,
                                                            cacheDirectory: cacheDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)

            if session.items.isEmpty {
                empty
            } else if layout == .cards {
                cardsBody
            } else {
                scrollBody
            }

            Divider().overlay(palette.line)
            footer
        }
        .frame(width: 1120, height: 860)
        .background(palette.panel)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboard)
        .onAppear {
            reload()
            keyboard = true
        }
        .onChange(of: state.previewScope) { _, _ in reload() }
        // Only in card mode: in the continuous scroll, Space and the arrows
        // belong to the scroll view, which is what you want there.
        .onKeyPress(.space) {
            guard layout == .cards else { return .ignored }
            session.advance()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard layout == .cards else { return .ignored }
            session.step(1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard layout == .cards else { return .ignored }
            session.step(-1)
            return .handled
        }
        .onKeyPress(.return) {
            guard layout == .cards else { return .ignored }
            session.advance()
            return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(KeyEquivalent("e")) { editCurrent(); return .handled }
    }

    private func reload() {
        guard let library = state.library else { return }
        session.load(lectures: state.previewLectures(library: library))
        // Open on the card you were working on. `load` resets to the top, so
        // this runs after it, and it quietly does nothing when that question
        // isn't in the scope you are previewing.
        if let qid = state.focusedQID { session.jump(toQuestion: qid) }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $state.previewScope) {
                ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Picker("", selection: $layout) {
                ForEach(Layout.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Spacer(minLength: 0)

            Button("Shuffle") { session.shuffle(); keyboard = true }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(counter)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.dim)
            if let item = session.current {
                Text(item.lecture)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim.opacity(0.85))
            }
            Spacer(minLength: 0)
            Text(layout == .cards
                 ? "Space reveals, then advances · ← → moves · E edits · ⎋ closes"
                 : "E edits the question you're looking at · ⎋ closes")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.dim.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var counter: String {
        guard !session.items.isEmpty else { return "" }
        if layout == .scroll { return "\(session.items.count) cards" }
        return "\(session.index + 1) / \(session.items.count)"
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text("No cards in this scope yet.")
                .font(.system(size: 13))
                .foregroundStyle(palette.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Flashcards

    @ViewBuilder
    private var cardsBody: some View {
        if let item = session.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if item.question.kind == .cloze {
                        clozeCardBody(item, revealed: session.revealed)
                    } else {
                        // An occlusion card's two sides are the same slide, once
                        // covered and once not. Drawing both after the reveal
                        // leaves the covered copy sitting on top of its own
                        // answer -- so on reveal the front gives up its image
                        // and the uncovered slide takes its place. Its prompt
                        // and "region 2 of 5" stay, because those are the
                        // question and the question does not go away.
                        let swapsImage = item.question.kind == .occlusion && session.revealed
                        let keepsFront = !swapsImage || hasFrontText(item) || item.ordinal != nil
                        if keepsFront {
                            side(item, back: false, showsImages: !swapsImage)
                        }
                        if session.revealed {
                            if keepsFront {
                                Rectangle().fill(palette.line).frame(height: 1)
                            }
                            side(item, back: true)
                        } else {
                            showAnswerButton
                        }
                    }
                }
                .padding(26)
            }
            .id(item.id)
        }
    }

    private var showAnswerButton: some View {
        Button { session.advance(); keyboard = true } label: {
            Text("Show answer")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(palette.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Continuous

    private var scrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.items) { item in
                        VStack(alignment: .leading, spacing: 16) {
                            if item.question.kind == .cloze {
                                clozeCardBody(item, revealed: true)
                            } else {
                                side(item, back: false)
                                Rectangle().fill(palette.amber.opacity(0.45)).frame(height: 1)
                                side(item, back: true)
                            }
                        }
                        .padding(26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(item.id)

                        Rectangle().fill(palette.line).frame(height: 6).opacity(0.6)
                    }
                }
            }
            // The scroll opens where the card view would have opened: on the
            // question you were working on. Following `index` afterwards means
            // switching layouts keeps your place rather than throwing you back
            // to the top.
            .onAppear { scroll(proxy) }
            .onChange(of: session.index) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = session.current?.id else { return }
        // Next runloop turn: scrolling a LazyVStack to a row that has not been
        // built yet does nothing, and on first appearance none of them have.
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: - In-place Cloze

    private func clozeAttributed(item: PreviewSession.Item, revealed: Bool) -> AttributedString {
        let ordinal = item.clozeOrdinal ?? 1
        let text = item.question.front
        let deletions = Cloze.deletions(in: text)
        guard !deletions.isEmpty else {
            return AttributedString(text)
        }
        var attr = AttributedString()
        var cursor = text.startIndex
        for deletion in deletions {
            guard deletion.range.lowerBound >= cursor else { continue }
            attr.append(AttributedString(text[cursor..<deletion.range.lowerBound]))
            if deletion.ordinal == ordinal {
                if revealed {
                    var ans = AttributedString("[\(deletion.answer)]")
                    ans.font = .system(size: 17, weight: .bold)
                    ans.foregroundColor = palette.amber
                    attr.append(ans)
                } else {
                    let placeholder = deletion.hint.map { "[\($0)]" } ?? "[...]"
                    var blank = AttributedString(placeholder)
                    blank.font = .system(size: 17, weight: .bold)
                    blank.foregroundColor = palette.amber
                    attr.append(blank)
                }
            } else {
                attr.append(AttributedString(deletion.answer))
            }
            cursor = deletion.range.upperBound
        }
        attr.append(AttributedString(text[cursor...]))
        return attr
    }

    @ViewBuilder
    private func clozeCardBody(_ item: PreviewSession.Item, revealed: Bool) -> some View {
        let composition = session.composition(for: item)
        let backText = item.question.back.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBackExtras = !backText.isEmpty || !composition.back.isEmpty

        VStack(alignment: .leading, spacing: 14) {
            Text(clozeAttributed(item: item, revealed: revealed))
                .font(AppFont.question(17))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let ordinal = item.ordinal, let total = item.ordinalTotal {
                Text("card \(ordinal) of \(total)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.dim)
            }

            slideImages(for: composition.front, in: item.pdfURL)

            if revealed {
                if hasBackExtras {
                    Rectangle().fill(palette.line).frame(height: 1)
                    if !backText.isEmpty {
                        Text(backText)
                            .font(AppFont.question(15))
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    slideImages(for: composition.back, in: item.pdfURL)
                }
            } else {
                showAnswerButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - One side of one card

    private func hasFrontText(_ item: PreviewSession.Item) -> Bool {
        !session.text(for: item, templates: state.templates.templates).front
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func side(_ item: PreviewSession.Item, back: Bool,
                      showsImages: Bool = true) -> some View {
        let text = session.text(for: item, templates: state.templates.templates)
        let composition = session.composition(for: item)
        let body = back ? text.back : text.front
        let specs = back ? composition.back : composition.front

        VStack(alignment: .leading, spacing: 14) {
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(body)
                    .font(AppFont.question(back ? 15 : 17))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let ordinal = item.ordinal, let total = item.ordinalTotal, !back {
                Text("region \(ordinal) of \(total)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.dim)
            }
            if showsImages {
                slideImages(for: specs, in: item.pdfURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func slideImages(for specs: [CardComposition.ImageSpec], in pdfURL: URL) -> some View {
        ForEach(specs, id: \.self) { spec in
            if let image = session.image(spec, in: pdfURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(palette.line, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.surface)
                    .frame(height: 120)
                    .overlay(
                        Text("slide \(spec.page) could not be rendered")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.dim)
                    )
            }
        }
    }

    private func editCurrent() {
        guard let item = session.current else { return }
        dismiss()
        state.jumpToQuestion(qid: item.question.qid, pdfURL: item.pdfURL)
    }
}
