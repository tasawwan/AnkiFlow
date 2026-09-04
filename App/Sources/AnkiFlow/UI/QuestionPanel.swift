import SwiftUI
import AppKit

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
                        // `show`, not a bare assignment: it arms the slide row
                        // this kind of card uses, so ⌘E and ⌘T work the moment
                        // you land on the tab.
                        state.show(entry.type)
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

    /// Which text field has the caret. Tab moves between them, and the armed
    /// slide row follows — so ⌘E, ⌘T and ⌘R always act on the side you are
    /// writing, with nothing to click and no mode to remember.
    enum Field: Hashable { case question, answer }
    @FocusState private var focusedField: Field?

    private var question: Question? { state.document?.question(qid: qid) }
    private var isFocused: Bool { state.focusedQID == qid }
    private var template: Template? { state.templates.template(id: question?.templateId) }
    private var pageCount: Int { state.pageCount }

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
            if newValue == qid { focusedField = .question }
        }
        // The armed row follows the caret. This is the whole interaction: Tab to
        // the answer, ⌘E, and the slides land on the answer side.
        .onChange(of: focusedField) { _, field in
            guard state.focusedQID == qid, let field,
                  let question = state.document?.question(qid: qid) else { return }
            // Only a card that draws both rows lets the caret choose between
            // them. An occlusion or cloze card has one slide row whatever field
            // you are typing in, and arming the other would send ⌘E to a row the
            // panel never shows and the exporter never reads.
            state.armedRow = (field == .question && state.showsBothRows(question))
                ? .question
                : state.defaultArmedRow(for: question)
            state.anchorPage = state.anchor(for: question, row: state.armedRow)
        }
        // ⌘⏎. Giving up focus is what pushes a SwiftUI text field's pending
        // edit into the binding; AppState then saves and clears the focused
        // question, which collapses this card.
        .onChange(of: state.commitSignal) { _, _ in
            if state.focusedQID == qid { focusedField = nil }
        }
    }

    private func focus(_ question: Question) {
        state.focusedQID = qid
        // Only a starting value: `focusedField`'s onChange re-derives both the
        // moment the caret lands, and it is the one that has the last word.
        state.armedRow = state.defaultArmedRow(for: question)
        state.anchorPage = state.anchor(for: question, row: state.armedRow)
        // Go to the slide this question is about. Clicking a question is saying
        // "I want to work on this one", and working on it means looking at it --
        // otherwise the first ⌘E or ⌘T lands on whatever slide you happened to
        // have been reading.
        if let first = question.allPages.first { state.currentPage = first }
        focusedField = .question
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

    /// The four fields every card has, in the order you fill them: what you are
    /// asking, the slides that go with the question, the answer in words, the
    /// slides that answer it.
    ///
    /// All four are optional and all four are always on screen. They used to
    /// appear and disappear per card type, with a ⌘B to reveal the written
    /// answer, and the cost of that was having to remember which fields this
    /// kind of card had before you could start typing. One shape, always, is
    /// worth more than the few pixels it spends.
    @ViewBuilder
    private func editor(_ question: Question) -> some View {
        switch question.kind {
        case .basic, .slide2slide:
            questionText(placeholder: "Ask the big question…")
            questionRow(question)
            backField
            answerRow(question)
        case .occlusion:
            // No question-slides row: an occlusion card's image *is* the answer
            // slide, and a second row would be a place to put a slide that the
            // card has nowhere to show.
            questionText(placeholder: "Optional — a prompt above the image…")
            backField
            answerRow(question)
            occlusionEditor(question)
        case .cloze:
            clozeEditor(question)
            backField
            answerRow(question)
        case .template:
            templateFields
            // Which slide rows appear is the template's choice, made once when
            // the template is written rather than on every question built from
            // it. The two text fields are always both there.
            let sides = state.templates.template(id: question.templateId)?.slides ?? .back
            if sides.showsFront { questionRow(question) }
            backField
            if sides.showsBack { answerRow(question) }
        }

        HStack(spacing: 12) {
            Spacer()
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
            .focused($focusedField, equals: .question)
    }

    /// The written answer. Always present, always optional — Tab from the
    /// question lands here, and arming the answer slide row is a side effect of
    /// being here rather than something else to press.
    private var backField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ANSWER")
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            TextField("Optional — add anything the slides don't say",
                      text: bind(\.back, default: ""), axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppFont.question(13.5))
                .foregroundStyle(palette.ink)
                .lineLimit(2...8)
                .focused($focusedField, equals: .answer)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1)
                )
        }
        .padding(.top, 2)
    }

    // MARK: Cloze

    /// The cloze text plus the two ways to hide a phrase in it.
    ///
    /// Slides live on the answer row underneath, so a cloze question reads the
    /// same way a Basic one does: the text is the card, the slides are what you
    /// look at once you have answered.
    @ViewBuilder
    private func clozeEditor(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type the sentence, then select the part to hide…",
                      text: bind(\.front, default: ""), axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppFont.question(15))
                .foregroundStyle(palette.ink)
                .lineLimit(2...10)
                .focused($focusedField, equals: .question)

            HStack(spacing: 10) {
                Button("Hide selection") { hideSelection(newCard: true) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Hide the selected words on a card of their own — ⌘⇧C")

                Button("Add to last card") { hideSelection(newCard: false) }
                    .disabled(question.clozeOrdinals.isEmpty)
                    .help("Hide these words on the same card as the previous deletion, so both are blanked together")

                Spacer(minLength: 0)

                Text(clozeCountLabel(question))
                    .font(.system(size: 11))
                    .foregroundStyle(question.clozeHasNoDeletions && !question.front.isEmpty
                                     ? Theme.retired : palette.dim)
            }
            .font(.system(size: 11.5))
        }
    }

    private func clozeCountLabel(_ question: Question) -> String {
        let count = question.clozeOrdinals.count
        if count == 0 {
            return question.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Select words and press ⌘⇧C"
                : "Nothing hidden yet — this makes no cards"
        }
        return count == 1 ? "Makes 1 card" : "Makes \(count) cards"
    }

    /// Wraps whatever is selected in the text field in `{{cN::…}}`.
    ///
    /// The selection is read from the window's field editor rather than from
    /// SwiftUI, which does not expose it. A plain TextField is backed by an
    /// NSTextView while it is focused, so this is the same text the caret sits
    /// in -- and when nothing is focused or nothing is selected, this says so
    /// rather than silently doing nothing.
    private func hideSelection(newCard: Bool) {
        guard let question = state.document?.question(qid: qid), question.kind == .cloze else { return }

        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.selectedRange().length > 0,
              // The field editor's string can lag the model by a keystroke, and
              // offsets taken from one string applied to another land in the
              // wrong place. Better to do nothing than to hide the wrong words.
              editor.string == question.front,
              let range = Range(editor.selectedRange(), in: question.front) else {
            state.statusMessage = "Select the words you want to hide first."
            return
        }

        if !state.hideCloze(range: range, newCard: newCard) {
            state.statusMessage = "That selection is already hidden."
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

                ForEach(Array(template.blanks.enumerated()), id: \.element.id) { index, blank in
                    templateBlank(blank, isFirst: index == 0)
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

    /// One blank of a template.
    ///
    /// The first one carries this card's question focus, so the caret has
    /// somewhere to land on ⌘N and Tab has somewhere to go. `.focused` cannot be
    /// applied conditionally with a nil value -- the modifier takes a
    /// non-optional -- so the two cases are separate branches.
    @ViewBuilder
    private func templateBlank(_ blank: TemplateBlank, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(blank.label.uppercased())
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
                .frame(width: 104, alignment: .leading)
            let field = TextField("", text: bindBlank(blank.key),
                                  axis: blank.multiline ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            if isFirst {
                field.focused($focusedField, equals: .question)
            } else {
                field
            }
        }
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
