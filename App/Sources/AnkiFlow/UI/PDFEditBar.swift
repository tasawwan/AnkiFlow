import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Pick a PDF whose pages get inserted after the current slide.
@MainActor
func insertPagesPanel(state: AppState) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.pdf]
    panel.prompt = "Insert"
    panel.message = "Every page of this PDF is inserted after slide \(state.currentPage). Your questions renumber themselves to match."
    if panel.runModal() == .OK, let url = panel.url {
        state.insertPages(from: url)
    }
}

/// The strip across the top of the slide pane.
///
/// Two states in one row, the way Preview's markup bar works: normally just the
/// button that turns editing on, and while editing, the tools themselves. One
/// row either way, so the page underneath never jumps.
struct PDFEditBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Button {
                state.togglePageFlag()
            } label: {
                Image(systemName: state.currentPageIsFlagged ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(state.currentPageIsFlagged ? .blue : palette.dim)
                    .frame(width: 25, height: 22)
            }
            .buttonStyle(.plain)
            .help(state.currentPageIsFlagged ? "Unflag this page" : "Flag this page")
            Button {
                state.openFind()
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(state.findVisible ? palette.ink : palette.dim)
                    .frame(width: 25, height: 22)
            }
            .buttonStyle(.plain)
            .help("Find text in this lecture")
            if state.isEditingPDF {
                tools
            } else {
                Spacer(minLength: 0)
                Button {
                    state.startEditingPDF()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 12))
                        Text("Edit PDF")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .disabled(!state.canEditPDF)
                .help("Mark up, rotate, reorder or trim the slides in this PDF")
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 10)
        .background(state.isEditingPDF ? palette.amber.opacity(0.10) : palette.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    // MARK: - Editing

    @ViewBuilder
    private var tools: some View {
        // Grouped only to stay under the ten-child limit a ViewBuilder imposes.
        // No effect on layout.
        HStack(spacing: 5) {
            Group {
                // No pointer button. Select is the resting state, and every
                // drawing tool puts itself down once used, so clicking a mark
                // just works.
                undoButton
                redoButton
                separator
                toolButton(.select)
                toolButton(.highlight)
                toolButton(.underline)
                toolButton(.strikeOut)
            }
            Group {
                separator
                toolButton(.pen)
                shapeMenu
                toolButton(.text)
                separator
                styleButton
            }
            separator
            toolButton(.trim)
            pageMenu
        }

        Spacer(minLength: 8)

        Text(hint)
            .font(.system(size: 11))
            .foregroundStyle(palette.dim)
            .lineLimit(1)
            .truncationMode(.tail)

        // No `keyboardShortcut(.escape)`: that registers a window key
        // equivalent, resolved before the focused view sees the key, so Esc in
        // the find bar or a page-range field would leave editing mode instead of
        // doing its own job. ContentView puts `.onExitCommand` on the pane.
        // The shortcut lives on the PDF menu's Save item, not here: a
        // `keyboardShortcut` on a view is a window key equivalent, and one
        // attached to a button that comes and goes with a state flag is a key
        // that works only sometimes.
        if state.hasUnsavedPDFEdits {
            Button("Save") { state.savePDFEdits() }
                .font(.system(size: 11.5))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Write these marks into the PDF (⌘S)")
        }

        Button("Done") { state.stopEditingPDF() }
            .font(.system(size: 11.5))
            .help("Stop editing — the slide pane goes back to normal (Esc)")
    }

    private var hint: String {
        if state.hasUnsavedPDFEdits { return "Unsaved marks — ⌘S writes them into the PDF" }
        return state.editTool.help
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.line)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func toolButton(_ tool: PDFEditing.Tool) -> some View {
        button(symbol: tool.symbol, selected: state.editTool == tool,
               help: "\(tool.label) — \(tool.help)") {
            if tool.textMark != nil {
                state.applyTextMarkTool(tool)
            } else {
                state.editTool = state.editTool == tool ? .select : tool
            }
        }
    }

    private var undoButton: some View {
        button(symbol: "arrow.uturn.backward", selected: false,
               help: state.undoLabel.map { "Undo \($0) — ⌘U" } ?? "Undo — ⌘U") {
            state.undo()
        }
        .disabled(!state.canUndo)
    }

    private var redoButton: some View {
        button(symbol: "arrow.uturn.forward", selected: false,
               help: state.redoLabel.map { "Redo \($0) — ⇧⌘U" } ?? "Redo — ⇧⌘U") {
            state.redo()
        }
        .disabled(!state.canRedo)
    }

    private func button(symbol: String, selected: Bool, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .frame(width: 25, height: 22)
                .foregroundStyle(selected ? palette.ink : palette.dim)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? palette.surface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(selected ? palette.line : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The four shapes behind one button, showing whichever you last used —
    /// Preview's arrangement, and it keeps the bar short.
    private var shapeMenu: some View {
        let current = PDFEditing.Tool.shapes.contains(state.editTool) ? state.editTool : .rectangle
        return Menu {
            ForEach(PDFEditing.Tool.shapes) { shape in
                Button {
                    state.editTool = shape
                } label: {
                    if state.editTool == shape {
                        Label(shape.label, systemImage: "checkmark")
                    } else {
                        Label(shape.label, systemImage: shape.symbol)
                    }
                }
            }
            Divider()
            Button {
                state.setEditFill(nil)
            } label: {
                Label("Border Only", systemImage: state.editFill == nil ? "checkmark" : "circle.slash")
            }
            Button {
                state.setEditFill(state.editStroke)
            } label: {
                Label("Filled", systemImage: state.editFill != nil ? "checkmark" : "square.fill")
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: current.symbol)
                    .font(.system(size: 12.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(PDFEditing.Tool.shapes.contains(state.editTool)
                             ? palette.ink : palette.dim)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(PDFEditing.Tool.shapes.contains(state.editTool) ? palette.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(PDFEditing.Tool.shapes.contains(state.editTool) ? palette.line : Color.clear, lineWidth: 1)
        )
        .help("Shapes — Rectangle, oval, line, arrow, and fill options")
    }

    /// Color, fill and thickness together behind one swatch, the way Preview
    /// keeps its shape style behind one button rather than spending four slots
    /// of bar on settings you change once a month.
    private var styleButton: some View {
        Button {
            // Not `toggle()`. A transient popover writes false to this binding
            // as it dismisses, and if that lands before the click does, the
            // toggle turns it straight back on and the popover never closes.
            if !state.showingStylePicker { state.showingStylePicker = true }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(state.editStroke.color)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(palette.line, lineWidth: 1))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
            .frame(width: 30, height: 22)
        }
        .buttonStyle(.plain)
        .help("Color, fill and thickness")
        .popover(isPresented: $state.showingStylePicker, arrowEdge: .bottom) {
            // A popover is its own hosting window, so the palette has to be
            // handed across explicitly — without this it falls back to the light
            // palette and draws light ink on a dark popover.
            StylePicker()
                .environmentObject(state)
                .environment(\.palette, palette)
        }
    }

    private var pageMenu: some View {
        Menu {
            Button("Rotate Left") { state.rotateCurrentPage(by: -90) }
            Button("Rotate Right") { state.rotateCurrentPage(by: 90) }
            Divider()
            Button("Insert Slides…") { insertPagesPanel(state: state) }
            Button("Delete This Slide…") { state.confirmingPageDelete = true }
            Divider()
            Button("Trim Every Slide Like This One") { state.trimAllSlidesLikeThisOne() }
        } label: {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.dim)
        }
        // `.button` + `.borderless`, not the deprecated `.borderlessButton`
        // style: that one draws its own chevron and ignores `menuIndicator`,
        // which would put a disclosure arrow inside a 30pt frame and clip it.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 22)
        .help("Rotate, move, insert, delete or trim slides")
    }
}

/// The popover behind the color swatch.
struct StylePicker: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var palette

    private var selectedKind: String? {
        guard let annotation = state.editSession?.selection?.annotation else { return nil }
        return PDFEditing.kind(of: annotation)
    }

    private var selectedTextBox: Bool { selectedKind == "FreeText" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            swatches(title: "COLOR",
                     selected: state.editStroke,
                     none: false) { if let ink = $0 { state.setEditStroke(ink) } }

            swatches(title: "FILL",
                     selected: state.editFill,
                     none: true) { state.setEditFill($0) }

            if !selectedTextBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THICKNESS")
                        .font(AppFont.rowLabel)
                        .tracking(0.6)
                        .foregroundStyle(palette.dim)
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { state.editLineWidth },
                                              set: { state.setEditLineWidth($0) }),
                               in: 1...8, step: 1)
                            .frame(width: 130)
                        Text("\(Int(state.editLineWidth))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.dim)
                            .frame(width: 14, alignment: .trailing)
                    }
                }
            }

            if selectedTextBox || selectedKind == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TEXT SIZE")
                        .font(AppFont.rowLabel)
                        .tracking(0.6)
                        .foregroundStyle(palette.dim)
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { state.editFontSize },
                                              set: { state.setEditFontSize($0) }),
                               in: 8...36, step: 1)
                            .frame(width: 130)
                        Text("\(Int(state.editFontSize))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.dim)
                            .frame(width: 14, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    state.toggleEditBold()
                } label: {
                    Text("Bold").bold()
                }
                .buttonStyle(.bordered)
                .tint(state.editBold ? palette.ink : palette.dim)

                Button {
                    state.toggleEditItalic()
                } label: {
                    Text("Italic").italic()
                }
                .buttonStyle(.bordered)
                .tint(state.editItalic ? palette.ink : palette.dim)

                Button {
                    state.toggleEditUnderline()
                } label: {
                    Text("Underline").underline()
                }
                .buttonStyle(.bordered)
                .tint(palette.dim)
            }
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
    }

    /// One row of color dots. With `none`, the first one is "no fill".
    private func swatches(title: String, selected: AppState.InkColour?, none: Bool,
                          pick: @escaping (AppState.InkColour?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(AppFont.rowLabel)
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            HStack(spacing: 8) {
                if none {
                    Button { pick(nil) } label: {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 17))
                            .foregroundStyle(selected == nil ? palette.ink : palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help("No fill")
                }
                ForEach(AppState.InkColour.allCases) { ink in
                    Button { pick(ink) } label: {
                        Circle()
                            .fill(ink.color)
                            .frame(width: 19, height: 19)
                            .overlay(
                                Circle()
                                    .stroke(palette.ink.opacity(selected == ink ? 0.9 : 0.15),
                                            lineWidth: selected == ink ? 2.5 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(ink.label)
                }
            }
        }
    }
}
