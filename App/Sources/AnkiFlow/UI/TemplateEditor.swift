import SwiftUI
import AppKit

/// Templates are built here, not by hand-editing JSON. The JSON is the save
/// format, the same way you don't hand-edit an Anki note type to add a field.
///
/// Type prose on the left, select a phrase and press ⌘B to turn it into a blank.
/// The preview on the right shows the card as it will actually render.
struct TemplateEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State var template: Template
    @State private var selection: NSRange?
    @State private var showBackSection = false

    private var derivedBlanks: [TemplateBlank] {
        let keys = Template.keys(in: template.front) + Template.keys(in: template.back)
        var seen = Set<String>()
        return keys.compactMap { key in
            guard seen.insert(key).inserted else { return nil }
            return template.blanks.first { $0.key == key } ?? TemplateBlank(key: key)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HSplitView {
                editorSide
                previewSide
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Clinical Correlation", text: $template.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Spacer()
            Text("Select a phrase, then ⌘B to make it a blank")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var editorSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FRONT")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            BlankAwareTextView(text: $template.front, selection: $selection)
                .frame(minHeight: 120)

            if showBackSection || !template.back.isEmpty {
                Text("BACK")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                BlankAwareTextView(text: $template.back, selection: .constant(nil))
                    .frame(minHeight: 70)
            } else {
                Button("+ Back section") { showBackSection = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Text("SLIDES ON")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $template.slides) {
                    ForEach(TemplateSlides.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer(minLength: 0)
            }

            Divider()

            Text("BLANKS")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            if derivedBlanks.isEmpty {
                Text("None yet. Select a phrase above and press ⌘B.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(derivedBlanks) { blank in
                            blankRow(blank)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 340)
    }

    private func blankRow(_ blank: TemplateBlank) -> some View {
        HStack(spacing: 8) {
            Text(blank.key)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.amber.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 110, alignment: .leading)

            Toggle("multiline", isOn: binding(for: blank, keyPath: \.multiline))
                .font(.system(size: 10))
            Toggle("optional", isOn: binding(for: blank, keyPath: \.optional))
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
    }

    private func binding(for blank: TemplateBlank, keyPath: WritableKeyPath<TemplateBlank, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                (template.blanks.first { $0.key == blank.key } ?? blank)[keyPath: keyPath]
            },
            set: { newValue in
                if let index = template.blanks.firstIndex(where: { $0.key == blank.key }) {
                    template.blanks[index][keyPath: keyPath] = newValue
                } else {
                    var copy = blank
                    copy[keyPath: keyPath] = newValue
                    template.blanks.append(copy)
                }
            }
        )
    }

    /// Drawn on whichever side the template actually puts them. It used to sit
    /// between the front and the back regardless, which read as "on the front"
    /// when the app only ever put them on the back.
    private var slidePlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 90)
            .overlay(
                Text("attached slides")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            )
    }

    private var previewSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREVIEW")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                previewText(template.front)
                if template.slides.showsFront { slidePlaceholder }
                if !template.back.isEmpty || template.slides.showsBack {
                    Divider()
                }
                if template.slides.showsBack { slidePlaceholder }
                if !template.back.isEmpty {
                    previewText(template.back)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 300)
    }

    /// Blanks render as filled slots, so you can see the shape of the card.
    private func previewText(_ text: String) -> some View {
        var display = text
        for key in Template.keys(in: text) {
            display = display.replacingOccurrences(of: "{{\(key)}}", with: "▒▒▒▒▒▒")
        }
        return Text(display.isEmpty ? "…" : display)
            .font(AppFont.question(14))
            .foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Make Blank") { makeBlank() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled((selection?.length ?? 0) == 0)

            Spacer()

            if !template.name.isEmpty && !derivedBlanks.isEmpty {
                Text("\(derivedBlanks.count) blank\(derivedBlanks.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Button("Save") {
                template.blanks = derivedBlanks
                state.templates.save(template)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    /// Replace the selected phrase with a `{{key}}` placeholder named after it.
    private func makeBlank() {
        guard let range = selection, range.length > 0 else { return }
        let ns = template.front as NSString
        guard range.location + range.length <= ns.length else { return }
        let selected = ns.substring(with: range)

        var key = selected
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if key.count > 24 { key = String(key.prefix(24)) }
        if key.isEmpty { key = "blank\(derivedBlanks.count + 1)" }

        var unique = key
        var suffix = 2
        while derivedBlanks.contains(where: { $0.key == unique }) {
            unique = "\(key)-\(suffix)"
            suffix += 1
        }

        template.front = ns.replacingCharacters(in: range, with: "{{\(unique)}}")
        template.blanks.append(TemplateBlank(key: unique, label: selected.capitalized))
        selection = nil
    }
}

/// An NSTextView wrapper, because SwiftUI's TextEditor doesn't report the
/// selected range and ⌘B needs to know what you highlighted.
struct BlankAwareTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        scrollView.borderType = .lineBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: BlankAwareTextView
        init(_ parent: BlankAwareTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selection = textView.selectedRange()
        }
    }
}
