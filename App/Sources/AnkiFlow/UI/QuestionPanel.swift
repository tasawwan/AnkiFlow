import SwiftUI
import AppKit

/// The right-hand panel. One card type at a time -- the dropdown governs the
/// whole panel, so a Basic question and an Occlusion are never in the same
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
            if let topic = state.topicFilter {
                topicFilterBanner(topic)
            } else {
                typeTabs
                if !state.filterTags.isEmpty { tagFilterRow }
                // Once, above the cards -- not inside each of them. It says what
                // this tab writes, which is a fact about the tab.
                if let shape = state.templates.template(id: state.panelType.templateId) {
                    TemplateShape(template: shape)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    /// What you clicked, and the way back.
    ///
    /// It replaces the tab row rather than sitting under it, because while a
    /// topic is in hand the tabs are not what the list is showing -- leaving
    /// them up, with one of them looking selected, would say something untrue
    /// about what is underneath.
    private func topicFilterBanner(_ topic: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(palette.amber)
            Text("Cards mentioning")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.dim)
            Text(topic)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button { state.topicFilter = nil } label: {
                Text("Show all")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.select)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(palette.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(palette.amber.opacity(0.4), lineWidth: 1))
    }

    /// Narrow the list to what you are working on.
    ///
    /// Tags, not a search box: they are the vocabulary you already keep, they
    /// cost one click, and a filter you can see the state of at a glance is one
    /// you will remember you left on. Selecting two means both, not either --
    /// filtering is for making a long list short, and "either" makes it longer.
    /// The counts on the tabs above follow, so a tab reading zero really is
    /// empty under this filter.
    private var tagFilterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: state.tagFilter.isEmpty
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(state.tagFilter.isEmpty ? palette.dim : palette.select)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(state.filterTags, id: \.self) { tag in
                        let isOn = state.tagFilter.contains(tag)
                        Button {
                            state.toggleTagFilter(tag)
                        } label: {
                            Text(tag)
                                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? palette.ink : palette.dim)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule().fill(isOn ? palette.select.opacity(0.22) : Color.clear)
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isOn ? palette.select.opacity(0.55) : palette.line,
                                        lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(isOn ? "Stop filtering by \(tag)" : "Show only cards tagged \(tag)")
                    }
                }
                .padding(.vertical, 1)
            }

            if !state.tagFilter.isEmpty {
                Button {
                    state.clearTagFilter()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .help("Show everything again")
            }
        }
        .frame(height: 22)
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
                    if state.visibleQuestions.isEmpty, !state.tagFilter.isEmpty {
                        Text("Nothing here is tagged "
                             + state.tagFilter.sorted().joined(separator: " + ")
                             + ". A new question will be.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                    }
                    ForEach(state.visibleQuestions) { question in
                        QuestionCard(qid: question.qid)
                            .id(question.qid)
                    }

                    // Hidden rather than disabled on a switched-off shape: its
                    // tab is here to read old cards in, and a greyed button
                    // would only invite the click it refuses.
                    if state.canAddQuestions(to: state.panelType) {
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
    typealias Field = QuestionField
    /// Plain state, not `@FocusState`: the written fields are `NSTextView`s now
    /// (they have to be, to draw a completion that is not in the string), and
    /// SwiftUI focus does not reach into an `NSViewRepresentable`. The text
    /// views read this to take first responder and write it when they get it.
    ///
    /// It lives on `AppState` rather than here so that something outside the
    /// card -- ⌘F, opening a sheet -- can take the keyboard away from it.
    private var focusedField: Field? {
        get { state.focusedField }
        nonmutating set { state.focusedField = newValue }
    }

    /// `$focusedField` is not available on a computed property, so the text
    /// views are handed this instead.
    private var focusBinding: Binding<Field?> {
        Binding(get: { state.focusedField }, set: { state.focusedField = $0 })
    }
    /// The one SwiftUI field left -- the first template blank -- still needs
    /// real focus, so it keeps its own and follows the line above.
    @FocusState private var blankFocused: Bool

    /// Which cloze card the pointer is over mid-drag. -1 is the new-card well.
    @State private var dropTarget: Int?

    private var question: Question? { state.document?.question(qid: qid) }
    private var isFocused: Bool { state.focusedQID == qid }
    /// The shape this card is being read through, if its text fits one.
    /// Nothing on the card says so -- it is a Basic card either way.
    private var template: Template? { question.flatMap { state.template(for: $0) } }
    private var pageCount: Int { state.pageCount }

    /// The card itself, kept apart from the modifiers below it.
    ///
    /// Not a style choice: as one expression, `body` was more than the type
    /// checker would finish -- "unable to type-check this expression in
    /// reasonable time". Splitting the content from the chain of `onChange`
    /// handlers gives it two smaller problems instead of one enormous one.
    @ViewBuilder private var card: some View {
        Group {
            if let question {
                VStack(alignment: .leading, spacing: 10) {
                    if isFocused {
                        editor(question)
                        // Tags belong to this question, so they live in this box.
                        TagBar(tags: question.tags,
                               onToggle: { state.toggleTag($0, on: qid) },
                               onSetYield: { state.setYield($0, on: qid) })
                    } else {
                        // The tap lives here, on the collapsed card itself,
                        // rather than on the container below.
                        //
                        // It used to be a `.onTapGesture` on the whole card
                        // whose *action* checked `isFocused`. But a conditional
                        // body does not make a conditional gesture: the
                        // recogniser was installed over the expanded card too,
                        // where it competed with the text fields for the
                        // mouse-down-and-drag sequence. Clicking to place the
                        // caret still worked, because that is a tap -- dragging
                        // to select did not, because the container took the
                        // drag first. Attaching it only to the view that wants
                        // it leaves the expanded card with no competing
                        // gesture at all.
                        collapsed(question)
                            .contentShape(Rectangle())
                            .onTapGesture { focus(question) }
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
            }
        }
    }

    var body: some View {
        card
        // A view does not get an `onChange` for the value it was born with, and
        // ⌘N's card is born already focused -- so the row below never ran for
        // it: the question field was not given the caret, and the armed-row
        // derivation, which hangs off that focus, never happened either. This
        // covers the first render; the `onChange` covers every card that was
        // already on screen when focus moved to it.
        .onAppear {
            if state.focusedQID == qid { focusedField = .question }
        }
        // The template card's first blank is the one field still drawn by
        // SwiftUI, so it needs its own focus kept in step with the card's.
        .onChange(of: state.focusedField) { _, field in
            blankFocused = field == .question
        }
        .onChange(of: state.focusedQID) { _, newValue in
            if newValue == qid { focusedField = .question }
        }
        // The armed row follows the caret. This is the whole interaction: Tab to
        // the answer, ⌘E, and the slides land on the answer side.
        .onChange(of: state.focusedField) { _, field in
            guard state.focusedQID == qid, let field,
                  let question = state.document?.question(qid: qid) else { return }
            // On a card that draws both rows the armed row simply follows the
            // caret: typing in the question arms the question's slides, Tab to
            // the answer arms the answer's.
            //
            // It used to send anything that was not the question field through
            // `defaultArmedRow`, which for a Basic card answers `.question` --
            // so tabbing to the answer left the slides still pointed at the
            // front, and ⌘T put them on the wrong side of the card.
            //
            // The fallback is for the kinds that draw one slide row whatever you
            // are typing in. An occlusion or cloze card has nowhere else to put
            // them, and arming a row the panel never shows would send ⌘E
            // somewhere the exporter never reads.
            // Working in a card takes the slide keys back off the lecture
            state.armedRow = state.showsBothRows(question)
                ? (field == .question ? .question : .answer)
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

    /// Typing into a blank edits the card's own text. `value` is read back out
    /// of that text by the caller, so the field always shows what is really on
    /// the card rather than a second copy of it that could drift.
    private func bindBlank(_ key: String, template: Template, value: String) -> Binding<String> {
        Binding(
            get: { value },
            set: { state.setBlank(key, to: $0, on: qid, template: template) }
        )
    }

    private func setPages(_ pages: [Int], answerSide: Bool) {
        guard var current = state.document?.question(qid: qid) else { return }
        if answerSide { current.answerPages = pages } else { current.questionPages = pages }
        state.document?.update(current)
    }

    // MARK: Collapsed

    /// The answer as it reads, for the closed card.
    ///
    /// Always the written answer, and for a cloze that means the explanation or
    /// nothing. A cloze's "answer" is its own sentence with the blanks filled
    /// in, which is exactly what `summary` already puts on the line above -- so
    /// falling back to it printed the sentence twice, once in black and once in
    /// grey, and said nothing the second time.
    private func answerText(_ question: Question) -> String {
        question.back.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Yield on a closed card: a dot in the corner, or nothing.
    ///
    /// In the corner rather than down among the tag chips because it is not a
    /// tag you are reading, it is a property of the card you are scanning past.
    /// Down there it was one word among several, in the same grey, at the far
    /// end of the row — which is the last place your eye goes and the first
    /// thing it stops distinguishing once a card has three tags on it.
    ///
    /// Nothing at all for normal, which is most cards. A mark every card wears
    /// is a mark you stop seeing, and the whole reason normal carries no tag is
    /// that it is the unremarkable state.
    @ViewBuilder
    private func yieldDot(_ question: Question) -> some View {
        let yield = Yield.of(question.tags)
        if yield != .normal {
            Circle()
                // Loud for high, quiet for low. Amber is this app's word for
                // "this matters"; low-yield is asking to be skimmed past, and a
                // colour that recedes is the honest way to say so.
                .fill(yield == .high ? palette.amber : palette.dim.opacity(0.5))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .help(yield.label)
        }
    }

    private func collapsed(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // No line limit on the question: it is what you are scanning for,
            // and a card whose wording runs to four lines is a card you want to
            // read four lines of. Blank lines inside it stay, because they were
            // put there.
            HStack(alignment: .top, spacing: 8) {
                Text(question.summary(template: template))
                    .font(AppFont.question(14))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                yieldDot(question)
            }

            // The answer is the half you already know, so it is dimmer, smaller,
            // and the only half allowed to trail off.
            if !answerText(question).isEmpty {
                Text(answerText(question))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.dim)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if !question.questionPages.isEmpty {
                    pageBadge("Q", question.questionPages)
                }
                if !question.answerPages.isEmpty {
                    pageBadge("A", question.answerPages)
                }
                Spacer(minLength: 0)
                ForEach(question.tags.filter { !TagDefinition.isYield($0) }.prefix(3),
                        id: \.self) { tag in
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
        if let template {
            templateEditor(question, template)
        } else {
            plainEditor(question)
        }

        editorFooter
    }

    /// A card read through a template shape.
    ///
    /// It is still whichever kind of card the shape makes -- occlusion cards get
    /// their regions, cloze cards their deletions -- so the only thing the
    /// template replaces is how the wording gets typed. Blanks and a free text
    /// field are alternatives, never both: two controls writing the same string
    /// is how you end up editing one and watching the other undo you.
    @ViewBuilder
    private func templateEditor(_ question: Question, _ template: Template) -> some View {
        let hasBlanks = !Template.keys(in: template.front).isEmpty
            || !Template.keys(in: template.back).isEmpty

        // A cloze shape always edits its sentence directly, blanks or not. The
        // deletions live in that sentence, and a card with no way to make one
        // exports a note Anki generates nothing from -- so the blanks give way
        // to the cloze editor, and the shape's wording arrives as the seed you
        // start from instead.
        if !template.enabled {
            Text("This shape is switched off in Settings. Its cards still open here; turn it back on to write more.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }

        if hasBlanks && template.kind != .cloze {
            templateFields(template)
        } else {
            switch template.kind {
            case .cloze:
                clozeEditor(question)
            case .occlusion:
                questionText(placeholder: "Optional — a prompt above the image…",
                             suggestions: Self.occlusionPrompts)
            case .basic, .template:
                questionText(placeholder: "Ask the big question…")
            }
        }

        switch template.kind {
        case .occlusion:
            // No question-slides row, for the same reason a plain occlusion card
            // has none: the image is the answer, and there is nowhere to show a
            // second one.
            if template.back.isEmpty { backField }
            answerRow(question)
            occlusionEditor(question)
        case .cloze:
            if template.back.isEmpty { backField }
            answerRow(question)
        case .basic, .template:
            // Both rows, always -- the same shape a Basic card has.
            //
            // The template's "slides on" choice used to hide one of them, and
            // that was wrong twice over: you could not attach a question slide
            // to a card whose shape said "back", and slides already attached to
            // a hidden row were simply invisible, still in the file and still on
            // the exported card. What that setting decides now is which row is
            // *armed* when you arrive, which is the part worth deciding once.
            questionRow(question)
            // A template with a back of its own writes the answer; only a
            // front-only template leaves you a field to write it yourself.
            if template.back.isEmpty { backField }
            answerRow(question)
        }
    }

    @ViewBuilder
    private func plainEditor(_ question: Question) -> some View {
        switch question.kind {
        case .basic, .template:
            questionText(placeholder: "Ask the big question…")
            questionRow(question)
            backField
            answerRow(question)
        case .occlusion:
            // No question-slides row: an occlusion card's image *is* the answer
            // slide, and a second row would be a place to put a slide that the
            // card has nowhere to show.
            questionText(placeholder: "Optional — a prompt above the image…",
                             suggestions: Self.occlusionPrompts)
            backField
            answerRow(question)
            occlusionEditor(question)
        case .cloze:
            clozeEditor(question)
            backField
            answerRow(question)
        }
    }

    private var editorFooter: some View {
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
    private func questionText(placeholder: String, suggestions: [String] = []) -> some View {
        CompletingTextView(
            text: bind(\.front, default: ""),
            focus: focusBinding,
            placeholder: placeholder,
            field: .question,
            tabTarget: .answer,
            fontSize: 15,
            minLines: 2, maxLines: 10,
            corpus: state.completionCorpus(for: question),
            suggestions: suggestions,
            textColour: palette.ink
        )
    }

    /// What an occlusion prompt nearly always says. Offered as a ghost in the
    /// empty field, taken with ⇧Space like any other suggestion.
    private static let occlusionPrompts = ["Label these features"]

    /// The written answer. Always present, always optional — Tab from the
    /// question lands here, and arming the answer slide row is a side effect of
    /// being here rather than something else to press.
    private var backField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ANSWER")
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            CompletingTextView(
                text: bind(\.back, default: ""),
                focus: focusBinding,
                placeholder: "Optional — add anything the slides don't say",
                field: .answer,
                tabTarget: .question,
                fontSize: 13.5,
                minLines: 2, maxLines: 8,
                corpus: state.completionCorpus(for: question),
                textColour: palette.ink
            )
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
            CompletingTextView(
                text: bind(\.front, default: ""),
                focus: focusBinding,
                placeholder: "Type the sentence, then select the part to hide…",
                field: .question,
                tabTarget: .answer,
                fontSize: 15,
                minLines: 2, maxLines: 10,
                corpus: state.completionCorpus(for: question),
                textColour: palette.ink
            )

            HStack(spacing: 10) {
                hideButton(question)

                groupingBar

                Spacer(minLength: 0)

                Text(clozeCountLabel(question))
                    .font(.system(size: 11))
                    .foregroundStyle(question.clozeHasNoDeletions && !question.front.isEmpty
                                     ? Theme.retired : palette.dim)
            }
            .font(.system(size: 11.5))

            deletionList(question)
        }
    }

    /// One card per blank, or one card for all of them.
    ///
    /// This replaced a second button — "add to last card" — that decided which
    /// card a blank went on at the moment you made it. That is the wrong moment:
    /// you find out whether these belong together after you have hidden them
    /// both, and by then the choice was spent. A mode you can flip afterwards
    /// re-groups what is already there, so it is never too late to change your
    /// mind. Neither segment is lit when you have built a grouping by hand in
    /// the list below; clicking one then takes the whole sentence back to it.
    private var groupingBar: some View {
        let actual = question.flatMap { state.actualClozeGrouping(of: $0) }
        return HStack(spacing: 0) {
            ForEach(AppState.ClozeGrouping.allCases) { mode in
                let isOn = actual == mode
                Button {
                    state.setClozeGrouping(mode)
                } label: {
                    Text(mode.label)
                        .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? palette.ink : palette.dim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(isOn ? palette.amber.opacity(0.28) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode == .separate
                      ? "Test each blank on its own card"
                      : "Blank all of them together, on one card")

                if mode == .separate {
                    Rectangle().fill(palette.line).frame(width: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line, lineWidth: 1))
    }

    /// The blanks, grouped by the card they are on.
    ///
    /// Grouped rather than listed flat, because the grouping *is* the thing you
    /// cannot see anywhere else: c1 and c3 four lines apart in a sentence look
    /// identical at a glance, and a flat list with a repeated number beside each
    /// row asks you to reconstruct the groups in your head. Here each card is a
    /// heading with its blanks under it, and moving one is a drag.
    ///
    /// The number beside each blank keeps its menu. Dragging is the fast way and
    /// a menu is the reliable one -- a small target on a trackpad, or a hand that
    /// does not want to hold a button down, should not be locked out of the only
    /// way to regroup.
    @ViewBuilder
    private func deletionList(_ question: Question) -> some View {
        let deletions = Cloze.deletions(in: question.front)
        let cards = Cloze.ordinals(in: question.front)
        if !deletions.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(cards, id: \.self) { card in
                    cardGroup(card, of: cards, deletions: deletions)
                }
                newCardWell(nextCard: (cards.max() ?? 0) + 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1))
        }
    }

    private func cardGroup(_ card: Int, of cards: [Int],
                           deletions: [Cloze.Deletion]) -> some View {
        let mine = deletions.enumerated().filter { $0.element.ordinal == card }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("CARD \(card)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(palette.ink2)
                Text(mine.count == 1 ? "1 blank" : "\(mine.count) blanks")
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 0)
            }

            ForEach(mine, id: \.offset) { index, deletion in
                blankRow(index: index, deletion: deletion, cards: cards)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dropTarget == card ? palette.amber.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropTarget == card ? palette.amber.opacity(0.6) : palette.lineSoft,
                        lineWidth: 1)
        )
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let index = Self.draggedBlank(items.first) else { return false }
            state.setClozeCard(card, forDeletionAt: index)
            return true
        } isTargeted: { over in
            dropTarget = over ? card : (dropTarget == card ? nil : dropTarget)
        }
    }

    private func blankRow(index: Int, deletion: Cloze.Deletion, cards: [Int]) -> some View {
        HStack(spacing: 7) {
            // The drag lives on the grip, not on the row.
            //
            // A Menu swallows the press that reaches it, so a `.draggable` on
            // the whole row would only actually start a drag from the few pixels
            // of margin the menu does not cover — which reads as "dragging
            // sometimes works". A handle you can see is also a handle you know
            // is there.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(palette.dim.opacity(0.75))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .draggable("\(Self.dragPrefix)\(index)")
                .help("Drag onto another card")

            Menu {
                ForEach(cards, id: \.self) { ordinal in
                    Button("Card \(ordinal)") { state.setClozeCard(ordinal, forDeletionAt: index) }
                }
                Divider()
                Button("New card") { state.setClozeCard(nil, forDeletionAt: index) }
            } label: {
                Text(deletion.answer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer(minLength: 0)

            Button {
                state.removeCloze(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
            .buttonStyle(.plain)
            .help("Stop hiding these words")
        }
        .padding(.vertical, 1)
        .help("Drag the handle onto another card, or click the words to pick one")
    }

    /// Drop a blank here to give it a card of its own.
    private func newCardWell(nextCard: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .semibold))
            Text("Drag here for card \(nextCard)")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(dropTarget == -1 ? palette.ink2 : palette.dim)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dropTarget == -1 ? palette.amber.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTarget == -1 ? palette.amber.opacity(0.6) : palette.line,
                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let index = Self.draggedBlank(items.first) else { return false }
            state.setClozeCard(nil, forDeletionAt: index)
            return true
        } isTargeted: { over in
            dropTarget = over ? -1 : (dropTarget == -1 ? nil : dropTarget)
        }
    }

    /// The payload is a plain string because String is already Transferable and
    /// a custom type would want a UTType declared in the app's Info.plist for
    /// one in-process drag. The prefix is what stops a paragraph dragged in from
    /// another app being read as a blank index.
    private static let dragPrefix = "ankiflow-cloze-blank:"

    private static func draggedBlank(_ payload: String?) -> Int? {
        guard let payload, payload.hasPrefix(dragPrefix) else { return nil }
        return Int(payload.dropFirst(dragPrefix.count))
    }

    /// Hide the selection -- on a new card by default, or on one you name.
    ///
    /// A split button rather than two: the plain half is what you want almost
    /// every time and keeps its keyboard shortcut, and the chevron is there for
    /// the sentence where this blank belongs with one you already made. The menu
    /// only appears once there is a card to choose, so it costs nothing until it
    /// is useful.
    @ViewBuilder
    private func hideButton(_ question: Question) -> some View {
        let cards = Cloze.ordinals(in: question.front)
        HStack(spacing: 0) {
            Button("Hide selection") { hideSelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Hide the selected words — ⌘⇧C")

            if !cards.isEmpty {
                Menu {
                    Button("New card") { hideSelection(onCard: nil, forceNew: true) }
                    Divider()
                    ForEach(cards, id: \.self) { card in
                        Button(cardLabel(card, in: question)) { hideSelection(onCard: card) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.leading, 3)
                .help("Hide the selected words on a card you choose")
            }
        }
    }

    /// "Card 1 · Protein A" -- the number alone is not something anyone
    /// remembers, so the menu says what is already on that card.
    private func cardLabel(_ ordinal: Int, in question: Question) -> String {
        let first = Cloze.deletions(in: question.front).first { $0.ordinal == ordinal }
        guard let answer = first?.answer.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { return "Card \(ordinal)" }
        let short = answer.count > 24 ? answer.prefix(24) + "…" : answer[...]
        return "Card \(ordinal) · \(short)"
    }

    private func hideSelection(onCard: Int? = nil, forceNew: Bool = false) {
        guard let question = state.document?.question(qid: qid),
              question.kind == .cloze else { return }

        // The window's field editor, whether or not it still holds first
        // responder. Clicking a button can take focus off the text field before
        // the action runs, and reading only the first responder is why the old
        // second button never worked -- ⌘⇧C did, because a key equivalent fires
        // without moving focus anywhere. The chevron menu would have inherited
        // exactly that bug.
        let editor = (NSApp.keyWindow?.firstResponder as? NSTextView)
            ?? (NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView)
        guard let editor,
              editor.selectedRange().length > 0,
              // The field editor's string can lag the model by a keystroke, and
              // offsets taken from one string applied to another land in the
              // wrong place. Better to do nothing than to hide the wrong words.
              editor.string == question.front,
              let range = Range(editor.selectedRange(), in: question.front) else {
            state.statusMessage = "Select the words you want to hide first."
            return
        }

        // `forceNew` is the menu's "New card" saying so outright, which has to
        // win over a mode bar set to One card.
        let card = onCard ?? (forceNew ? Cloze.nextOrdinal(in: question.front) : nil)
        if !state.hideCloze(range: range, onCard: card) {
            state.statusMessage = "That selection is already hidden."
        }
    }

    private func clozeCountLabel(_ question: Question) -> String {
        let count = question.clozeOrdinals.count
        if count == 0 {
            return question.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Select words and press ⌘⇧C"
                : "Nothing hidden yet — this makes no cards"
        }
        let blanks = Cloze.deletions(in: question.front).count
        let cards = count == 1 ? "1 card" : "\(count) cards"
        // Only worth saying when they differ -- "3 blanks · 2 cards" is the whole
        // point of grouping, and "1 blank · 1 card" is noise.
        guard blanks != count else { return "Makes \(cards)" }
        return "\(blanks) blanks · \(cards)"
    }

    // MARK: Template

    /// The blanks, read back out of the card's own text.
    ///
    /// `Template.blanks` is the authored list; the keys the text actually
    /// contains are the truth, and a template edited by hand can leave the two
    /// disagreeing. Drawing the fields from the text means every blank you can
    /// see is one that will actually go somewhere.
    @ViewBuilder
    private func templateFields(_ template: Template) -> some View {
        let values = question.map { state.blankValues(for: $0, template: template) } ?? [:]
        let on = question.map { template.selectedOptions(inFront: $0.front) } ?? []
        let shape = template.composed(options: on)
        let keys = Template.keys(in: shape.front) + Template.keys(in: shape.back)
        let fields: [TemplateBlank] = keys.reduce(into: []) { out, key in
            guard !out.contains(where: { $0.key == key }) else { return }
            out.append(template.blanks(options: on).first { $0.key == key }
                       ?? TemplateBlank(key: key))
        }
        VStack(alignment: .leading, spacing: 9) {
            // Live preview: the card front as it stands, updating with every
            // keystroke, with your answers picked out in amber.
            TemplatePreview(template: template, blanks: values, options: on)

            if !template.options.isEmpty { optionChecks(template, on: on) }

            ForEach(Array(fields.enumerated()), id: \.element.id) { index, blank in
                templateBlank(blank, template: template, value: values[blank.key] ?? "",
                              isFirst: index == 0)
            }
        }
    }

    /// The optional questions, as checkboxes.
    ///
    /// Ticking one writes its sentence into the card and unticking takes it
    /// back out: there is nowhere else the state could live, because a card
    /// carries nothing but its own words. Reword the sentence afterwards and
    /// the box goes clear -- your words stay exactly as typed, they are simply
    /// no longer the ones it looks for.
    @ViewBuilder
    private func optionChecks(_ template: Template, on: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ALSO ASK")
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            ForEach(template.options) { option in
                Toggle(isOn: Binding(
                    get: { on.contains(option.key) },
                    set: { want in
                        guard let qid = question?.qid else { return }
                        state.setOption(option.key, on: want, for: qid, template: template)
                    }
                )) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink2)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 2)
    }

    /// The occlusion controls: how it becomes cards, what is hidden, and how
    /// many cards that adds up to.
    @ViewBuilder
    /// The regions, grouped by the card that hides them.
    ///
    /// The same shape as the cloze list, because it is the same question asked
    /// of a different kind of card: which of these are revealed together. The
    /// two named shapes are a bar you can flip at any time, anything else you
    /// build by dragging a region onto another card, and the count underneath
    /// says what it all adds up to.
    private func occlusionEditor(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            occlusionModeBar(question)

            if question.masks.isEmpty {
                Text("Hold ⌥ and drag on the slide to hide a region.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.dim)
            } else {
                maskGroups(question)

                // Occlusion is the only thing here that turns one question into
                // several cards. Saying so beforehand is cheaper than a surprise
                // in tomorrow's queue.
                Text(occlusionCountLabel(question))
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

    private func occlusionCountLabel(_ question: Question) -> String {
        let cards = state.occlusionCardCount
        let regions = question.masks.count
        let plural = cards == 1 ? "1 card" : "\(cards) cards"
        guard regions != cards else { return "Makes \(plural)" }
        return "\(regions) regions · \(plural)"
    }

    private func occlusionModeBar(_ question: Question) -> some View {
        let actual = state.maskGrouping(of: question)
        return HStack(spacing: 8) {
            Text("Reveal:")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.dim)
            HStack(spacing: 0) {
                ForEach(OcclusionMode.allCases) { mode in
                    let isOn = actual == mode
                    Button {
                        state.setOcclusionMode(mode)
                    } label: {
                        Text(mode.label)
                            .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? palette.ink : palette.dim)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(isOn ? palette.amber.opacity(0.28) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if mode == OcclusionMode.allCases.first {
                        Rectangle().fill(palette.line).frame(width: 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line, lineWidth: 1))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func maskGroups(_ question: Question) -> some View {
        let groups = question.maskGroups
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                maskGroup(group, card: index + 1, question: question)
            }
            if groups.count > 1 || question.masks.count > 1 {
                newMaskCardWell(nextCard: groups.count + 1)
            }
        }
    }

    private func maskGroup(_ group: [Mask], card: Int, question: Question) -> some View {
        let number = group.first?.group ?? card
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("CARD \(card)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(palette.ink2)
                Text(group.count == 1 ? "1 region" : "\(group.count) regions")
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 0)
            }

            ForEach(group) { mask in
                maskRow(mask, question: question)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dropTarget == number ? palette.amber.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropTarget == number ? palette.amber.opacity(0.6) : palette.lineSoft,
                        lineWidth: 1)
        )
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let id = Self.draggedMask(items.first) else { return false }
            state.setMaskGroup(number, for: id)
            return true
        } isTargeted: { over in
            dropTarget = over ? number : (dropTarget == number ? nil : dropTarget)
        }
    }

    private func maskRow(_ mask: Mask, question: Question) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(palette.dim.opacity(0.75))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .draggable("\(Self.maskDragPrefix)\(mask.id)")
                .help("Drag onto another card")

            Menu {
                ForEach(Array(question.maskGroups.enumerated()), id: \.offset) { index, group in
                    Button("Card \(index + 1)") {
                        state.setMaskGroup(group.first?.group, for: mask.id)
                    }
                }
                Divider()
                Button("New card") { state.setMaskGroup(nil, for: mask.id) }
            } label: {
                Text(mask.rect.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

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
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(state.hoveredMaskID == mask.id
                      ? palette.amber.opacity(0.22)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        // Both directions: this lights the rectangle on the slide, and the
        // rectangle's own hover lights this row.
        .onHover { inside in
            if inside { state.hoveredMaskID = mask.id }
            else if state.hoveredMaskID == mask.id { state.hoveredMaskID = nil }
        }
    }

    private func newMaskCardWell(nextCard: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .semibold))
            Text("Drag here for card \(nextCard)")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(dropTarget == -2 ? palette.ink2 : palette.dim)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dropTarget == -2 ? palette.amber.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTarget == -2 ? palette.amber.opacity(0.6) : palette.line,
                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let id = Self.draggedMask(items.first) else { return false }
            state.setMaskGroup(nil, for: id)
            return true
        } isTargeted: { over in
            dropTarget = over ? -2 : (dropTarget == -2 ? nil : dropTarget)
        }
    }

    /// Its own prefix, so a cloze blank cannot be dropped onto a card of
    /// regions and the other way round.
    private static let maskDragPrefix = "ankiflow-mask:"

    private static func draggedMask(_ payload: String?) -> String? {
        guard let payload, payload.hasPrefix(maskDragPrefix) else { return nil }
        return String(payload.dropFirst(maskDragPrefix.count))
    }

    /// One blank of a template.
    ///
    /// The first one carries this card's question focus, so the caret has
    /// somewhere to land on ⌘N and Tab has somewhere to go. `.focused` cannot be
    /// applied conditionally with a nil value -- the modifier takes a
    /// non-optional -- so the two cases are separate branches.
    @ViewBuilder
    private func templateBlank(_ blank: TemplateBlank, template: Template,
                               value: String, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(blank.label.uppercased())
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
                .frame(width: 104, alignment: .leading)
            let field = TextField("", text: bindBlank(blank.key, template: template, value: value),
                                  axis: blank.multiline ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            if isFirst {
                field.focused($blankFocused)
                    .onKeyPress(.tab) {
                        focusedField = .answer
                        return .handled
                    }
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
            showingCrops: state.expandedCropRow == .question,
            isCropping: state.croppingRow == .question,
            onToggleCrops: {
                // One click does both: opens the list, and arms the next drag.
                let wasOpen = state.expandedCropRow == .question
                state.expandedCropRow = wasOpen ? nil : .question
                state.croppingRow = wasOpen ? nil : .question
            },
            onArm: { state.armedRow = .question }
        ) { pages in
            setPages(pages, answerSide: false)
        }
    }

    private func answerRow(_ question: Question) -> some View {
        // "Is there another row to compete with", not "is this Basic" --
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
            showingCrops: state.expandedCropRow == .answer,
            isCropping: state.croppingRow == .answer,
            onToggleCrops: {
                // One click does both: opens the list, and arms the next drag.
                let wasOpen = state.expandedCropRow == .answer
                state.expandedCropRow = wasOpen ? nil : .answer
                state.croppingRow = wasOpen ? nil : .answer
            },
            onArm: { state.armedRow = .answer }
        ) { pages in
            setPages(pages, answerSide: true)
        }
    }
}

// MARK: - Template preview

/// Shows the template's prose with your filled-in values in place, so you can
/// see the finished card front as you type it rather than after you save.
/// The shape itself, unfilled, at the top of its tab.
///
/// Deliberately not card-shaped. It is a diagram of what you are about to
/// write, not a thing you have written -- so it gets a dashed edge, no fill of
/// its own and a smaller setting, and cannot be mistaken for the card below it
/// or for a blank card someone left behind.
struct TemplateShape: View {
    @Environment(\.palette) private var palette
    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 9))
                Text("SHAPE")
                    .font(AppFont.rowLabel)
                    .tracking(0.6)
            }
            .foregroundStyle(palette.dim)

            Text(TemplateShape.outline(of: template))
                .font(AppFont.question(12.5))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(palette.line,
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .allowsHitTesting(false)
    }

    /// The wording with its blanks left as their own labels, so the shape reads
    /// as a form rather than as a half-finished card.
    static func outline(of template: Template) -> String {
        let on = Set(template.options.filter(\.defaultOn).map(\.key))
        let composed = template.composed(options: on)
        let named = template.blanks(options: on)
        var values: [String: String] = [:]
        for key in Template.keys(in: composed.front) + Template.keys(in: composed.back) {
            let label = named.first { $0.key == key }?.label ?? key.capitalized
            values[key] = "[\(label.lowercased())]"
        }
        let rendered = template.render(blanks: values, options: on)
        return rendered.back.isEmpty
            ? rendered.front
            : rendered.front + "\n→ " + rendered.back
    }
}

struct TemplatePreview: View {
    @Environment(\.palette) private var palette
    let template: Template
    let blanks: [String: String]
    var options: Set<String> = []

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
        var remainder = Substring(template.composed(options: options).front)

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

private extension View {
    /// Tab moves between the question and the answer and back again, instead of
    /// walking out of the card into whatever control happens to come next.
    ///
    /// With two fields there is nothing to distinguish forward from backward, so
    /// Shift-Tab is deliberately left to do the same thing: from either field,
    /// the other one is both the next and the previous.
    func tabCycles<Field: Hashable>(to field: Field,
                                    _ focus: FocusState<Field?>.Binding) -> some View {
        onKeyPress(.tab) {
            focus.wrappedValue = field
            return .handled
        }
    }
}
