import SwiftUI

/// The right-hand panel. One card type at a time -- the dropdown governs the
/// whole panel, so a Basic question and a Slide2Slide are never in the same
/// list. That also means ⌘E, ⌘T and ⌘R mean exactly one thing at any moment.
struct QuestionPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)

            if state.document == nil {
                Spacer()
                Text("Open a lecture to start writing questions.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity)
                    .padding()
                Spacer()
            } else {
                questionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.panel)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            typeTabs
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    /// The card type governs the whole panel, so it is a row of tabs rather than
    /// a menu: every type and how many questions it holds is visible at once,
    /// and switching costs one click instead of two. The dropdown that used to
    /// sit above this said the same thing twice.
    ///
    /// Scrolls horizontally, because a library with a dozen templates should
    /// spill off the edge rather than squeeze them into illegible slivers.
    private var typeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(state.counts().enumerated()), id: \.offset) { _, entry in
                    let isCurrent = entry.type == state.panelType
                    Button {
                        state.panelType = entry.type
                        state.focusedQID = state.visibleQuestions.last?.qid
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.label)
                                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? palette.ink : palette.dim)
                            Text("\(entry.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isCurrent ? palette.ink2 : palette.dim.opacity(0.75))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isCurrent ? palette.surface : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isCurrent ? palette.line : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(isCurrent ? "Current card type" : "Switch to \(entry.label) — ⌘Y cycles")
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 34)
    }

    // MARK: - List

    private var questionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.visibleQuestions) { question in
                        QuestionCard(qid: question.qid)
                            .id(question.qid)
                    }

                    Button {
                        state.newQuestion()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                            Text("New question")
                            Text("⌘N").foregroundStyle(palette.dim.opacity(0.7))
                            Spacer()
                        }
                        .font(.system(size: 12.5))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.dim)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: state.focusedQID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - One question

/// Takes a `qid`, not a `Question`.
///
/// This matters. A captured struct goes stale the moment the model changes, and
/// a control bound to a stale copy silently discards what you do to it -- which
/// is why the question box seemed read-only and the tag boxes wouldn't tick.
/// Every read below goes through the document by id.
struct QuestionCard: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    let qid: String

    @FocusState private var textFocused: Bool

    private var question: Question? { state.document?.question(qid: qid) }
    private var isFocused: Bool { state.focusedQID == qid }
    private var template: Template? { state.templates.template(id: question?.templateId) }
    private var pageCount: Int { state.pageCount }
    private var showBack: Bool { state.revealBackField }

    var body: some View {
        Group {
            if let question {
                VStack(alignment: .leading, spacing: 10) {
                    if isFocused {
                        editor(question)
                        // Tags belong to this question, so they live in this box.
                        TagBar(qid: qid)
                    } else {
                        collapsed(question)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.surface.opacity(isFocused ? 1 : 0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? palette.select.opacity(0.6) : palette.line,
                                lineWidth: isFocused ? 1.5 : 1)
                )
                // Only the collapsed card is click-to-focus. A tap gesture on the
                // expanded card swallows clicks meant for its own text fields.
                .onTapGesture { if !isFocused { focus(question) } }
            }
        }
        .onChange(of: state.focusedQID) { _, newValue in
            if newValue == qid { textFocused = true }
        }
        // ⌘⏎. Giving up focus is what pushes a SwiftUI text field's pending
        // edit into the binding; AppState then saves and clears the focused
        // question, which collapses this card.
        .onChange(of: state.commitSignal) { _, _ in
            if state.focusedQID == qid { textFocused = false }
        }
    }

    private func focus(_ question: Question) {
        state.focusedQID = qid
        state.armedRow = state.defaultArmedRow(for: question)
        state.anchorPage = question.answerPages.first ?? state.currentPage
        // Go to the slide this question is about. Clicking a question is saying
        // "I want to work on this one", and working on it means looking at it --
        // otherwise the first ⌘E or ⌘T lands on whatever slide you happened to
        // have been reading.
        if let first = question.allPages.first { state.currentPage = first }
        textFocused = true
    }

    // MARK: Live bindings

    private func bind<V>(_ keyPath: WritableKeyPath<Question, V>, default fallback: V) -> Binding<V> {
        Binding(
            get: { state.document?.question(qid: qid)?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                guard var current = state.document?.question(qid: qid) else { return }
                current[keyPath: keyPath] = newValue
                state.document?.update(current)
            }
        )
    }

    private func bindBlank(_ key: String) -> Binding<String> {
        Binding(
            get: { state.document?.question(qid: qid)?.blanks[key] ?? "" },
            set: { newValue in
                guard var current = state.document?.question(qid: qid) else { return }
                current.blanks[key] = newValue
                state.document?.update(current)
            }
        )
    }

    private func setPages(_ pages: [Int], answerSide: Bool) {
        guard var current = state.document?.question(qid: qid) else { return }
        if answerSide { current.answerPages = pages } else { current.questionPages = pages }
        state.document?.update(current)
    }

    // MARK: Collapsed

    private func collapsed(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.summary(template: template))
                .font(AppFont.question(14))
                .lineLimit(2)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if !question.questionPages.isEmpty {
                    pageBadge("Q", question.questionPages)
                }
                if !question.answerPages.isEmpty {
                    pageBadge("A", question.answerPages)
                }
                Spacer(minLength: 0)
                ForEach(question.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(palette.line.opacity(0.7), in: Capsule())
                }
            }
        }
    }

    private func pageBadge(_ label: String, _ pages: [Int]) -> some View {
        Text("\(label) \(PageSet.describe(pages))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.dim)
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ question: Question) -> some View {
        switch question.kind {
        case .basic:
            questionText(placeholder: "Ask the big question…")
            answerRow(question)
        case .slide2slide:
            questionText(placeholder: "Optional — ask something specific about these slides…")
            questionRow(question)
            answerRow(question)
        case .occlusion:
            questionText(placeholder: "Optional — a prompt above the image…")
            answerRow(question)
            occlusionEditor(question)
        case .template:
            templateFields
            // Which rows appear is the template's choice, made once when the
            // template is written rather than on every question built from it.
            let sides = state.templates.template(id: question.templateId)?.slides ?? .back
            if sides.showsFront { questionRow(question) }
            if sides.showsBack { answerRow(question) }
        }

        backField

        HStack(spacing: 12) {
            Spacer()
            Button {
                state.revealBackField.toggle()
            } label: {
                Text(showBack ? "Hide written answer" : "Add written answer")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.dim)

            Text("⌘B")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.dim.opacity(0.7))

            Button {
                state.focusedQID = qid
                state.deleteFocusedQuestion()
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.dim)
            .help("Delete (⌘⌫)")
        }
    }

    /// TextField with `axis: .vertical` rather than TextEditor: it grows with the
    /// text, has a real placeholder, and puts the caret where the text actually
    /// starts instead of at the container's top-left corner.
    private func questionText(placeholder: String) -> some View {
        TextField(placeholder, text: bind(\.front, default: ""), axis: .vertical)
            .textFieldStyle(.plain)
            .font(AppFont.question(15))
            .foregroundStyle(palette.ink)
            .lineLimit(2...10)
            .focused($textFocused)
    }

    @ViewBuilder
    private var backField: some View {
        if showBack || !(question?.back.isEmpty ?? true) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WRITTEN ANSWER")
                    .font(AppFont.rowLabel)
                    .tracking(0.6)
                    .foregroundStyle(palette.dim)
                TextField("Optional — the slides are usually the answer",
                          text: bind(\.back, default: ""), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppFont.question(13.5))
                    .foregroundStyle(palette.ink)
                    .lineLimit(2...8)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1)
                    )
            }
            .padding(.top, 2)
        }
    }

    // MARK: Template

    @ViewBuilder
    private var templateFields: some View {
        if let template {
            VStack(alignment: .leading, spacing: 9) {
                // Live preview: the card front as it stands, updating with every
                // keystroke, with your answers picked out in amber.
                TemplatePreview(template: template, blanks: question?.blanks ?? [:])

                ForEach(template.blanks) { blank in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(blank.label.uppercased())
                            .font(AppFont.rowLabel)
                            .tracking(0.6)
                            .foregroundStyle(palette.dim)
                            .frame(width: 104, alignment: .leading)
                        TextField("", text: bindBlank(blank.key),
                                  axis: blank.multiline ? .vertical : .horizontal)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }
                }
            }
        } else {
            Text("This question's template is missing. Recreate it in Settings ▸ Templates, or switch the question to Basic.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.78, green: 0.42, blue: 0.44))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The occlusion controls: how it becomes cards, what is hidden, and how
    /// many cards that adds up to.
    @ViewBuilder
    private func occlusionEditor(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Reveal:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.dim)
                Picker("", selection: Binding(
                    get: { question.occlusionMode },
                    set: { state.setOcclusionMode($0) }
                )) {
                    ForEach(OcclusionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if question.masks.isEmpty {
                Text("Hold ⌥ and drag on the slide to hide a region.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.dim)
            } else {
                ForEach(Array(question.masks.enumerated()), id: \.element.id) { index, mask in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.ink2)
                            .frame(width: 18, height: 18)
                            .background(palette.amber.opacity(0.28), in: Circle())
                        Text(mask.rect.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.dim)
                        Spacer(minLength: 0)
                        Button {
                            state.deleteMask(mask.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(palette.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this region")
                    }
                }

                // Occlusion is the only thing here that turns one question into
                // several cards. Saying so beforehand is cheaper than a surprise
                // in tomorrow's queue.
                Text(state.occlusionCardCount == 1
                     ? "Makes 1 card"
                     : "Makes \(state.occlusionCardCount) cards")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1)
        )
    }

    private func questionRow(_ question: Question) -> some View {
        ChipRow(
            label: "Question slides",
            pages: question.questionPages,
            pageCount: pageCount,
            isArmed: state.armedRow == .question,
            showArmedBadge: true,
            ghostPage: state.armedRow == .question ? state.ghostPage : nil,
            croppedPages: question.questionCrops.keys.sorted(),
            onRemoveCrop: { state.clearCrop(page: $0, row: .question) },
            onArm: { state.armedRow = .question }
        ) { pages in
            setPages(pages, answerSide: false)
        }
    }

    private func answerRow(_ question: Question) -> some View {
        // "Is there another row to compete with", not "is this Slide2Slide" --
        // a template with slides on both sides draws two rows too, and both were
        // being shown as armed at once.
        let bothRows = state.showsBothRows(question)
        let armed = !bothRows || state.armedRow == .answer
        return ChipRow(
            label: "Answer slides",
            pages: question.answerPages,
            pageCount: pageCount,
            isArmed: armed,
            showArmedBadge: bothRows,
            ghostPage: armed ? state.ghostPage : nil,
            croppedPages: question.answerCrops.keys.sorted(),
            onRemoveCrop: { state.clearCrop(page: $0, row: .answer) },
            onArm: { state.armedRow = .answer }
        ) { pages in
            setPages(pages, answerSide: true)
        }
    }
}

// MARK: - Template preview

/// Shows the template's prose with your filled-in values in place, so you can
/// see the finished card front as you type it rather than after you save.
struct TemplatePreview: View {
    @Environment(\.palette) private var palette
    let template: Template
    let blanks: [String: String]

    var body: some View {
        Text(attributed)
            .font(AppFont.question(14.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
    }

    /// Filled values are amber and bold; blanks you haven't answered yet show as
    /// a dim rule, so it's obvious what's still missing.
    private var attributed: AttributedString {
        var out = AttributedString()
        var remainder = Substring(template.front)

        while let open = remainder.range(of: "{{"),
              let close = remainder.range(of: "}}", range: open.upperBound..<remainder.endIndex) {
            var literal = AttributedString(String(remainder[remainder.startIndex..<open.lowerBound]))
            literal.foregroundColor = palette.ink
            out.append(literal)

            let key = String(remainder[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = (blanks[key] ?? "").trimmingCharacters(in: .whitespaces)

            // Underscores, not em dashes. A run of dashes reads as a strikethrough
            // or a rule; an underscore run is the universal "write here".
            var filled = AttributedString(value.isEmpty ? "_____" : value)
            filled.foregroundColor = value.isEmpty ? palette.dim : palette.amber
            filled.font = AppFont.question(14.5).weight(value.isEmpty ? .regular : .semibold)
            out.append(filled)

            remainder = remainder[close.upperBound...]
        }

        var tail = AttributedString(String(remainder))
        tail.foregroundColor = palette.ink
        out.append(tail)
        return out
    }
}
