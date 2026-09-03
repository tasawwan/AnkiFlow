import SwiftUI

/// Shown when the slides in a PDF have moved under the questions that point at
/// them. There is no "not now": every question in this lecture is pointing
/// somewhere, and leaving it unanswered means leaving them pointing at the
/// wrong slides with nothing on screen to say so.
///
/// What it asks for is narrow. Slides whose text still matches are settled and
/// listed as such. The ones that need you are the ones with no readable text —
/// a diagram, a photo, a title card — where the app has worked out where they
/// probably went from how far their neighbours moved, and wants that confirmed.
struct PageShiftSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let shift: PageShift
    let pageCount: Int

    @State private var overrides: [Int: Int?] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !shift.uncertain.isEmpty {
                        sectionLabel("Please check these")
                        ForEach(shift.uncertain) { move in
                            row(move, editable: true)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                    if !shift.confident.isEmpty {
                        sectionLabel("Matched by their text")
                        ForEach(shift.confident) { move in
                            row(move, editable: false)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                }
            }

            Divider().overlay(palette.line)
            footer
        }
        .frame(width: 780, height: 620)
        .background(palette.panel)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Slides have moved")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(shift.headline)
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func row(_ move: PageSketch.Move, editable: Bool) -> some View {
        let chosen = overrides[move.oldPage] ?? move.newPage

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slide \(move.oldPage)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.ink)
                Text("\(move.questionCount) question\(move.questionCount == 1 ? "" : "s") · \(move.basis.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(move.basis.needsConfirmation ? palette.ink2 : palette.dim)
            }
            .frame(width: 300, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.dim)

            if editable {
                Picker("", selection: Binding(
                    get: { chosen },
                    set: { overrides[move.oldPage] = $0 }
                )) {
                    Text("Remove from questions").tag(Int?.none)
                    ForEach(1...max(1, pageCount), id: \.self) { page in
                        Text("Slide \(page)").tag(Int?.some(page))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            } else {
                Text(chosen.map { "Slide \($0)" } ?? "removed")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.ink2)
            }

            Spacer(minLength: 0)

            confidenceDot(move.basis.confidence)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func confidenceDot(_ value: Double) -> some View {
        Circle()
            .fill(value >= 0.75 ? Theme.added : (value >= 0.5 ? palette.amber : Theme.retired))
            .frame(width: 7, height: 7)
            .help(value >= 0.75 ? "Confident" : (value >= 0.5 ? "Fairly sure" : "A guess — please check"))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Open the PDF beside this window if you need to look. Nothing changes until you apply.")
                .font(.system(size: 11))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func apply() {
        var mapping: [Int: Int] = [:]
        var removed: [Int] = []
        for move in shift.moves {
            if let chosen = overrides[move.oldPage] ?? move.newPage {
                mapping[move.oldPage] = chosen
            } else {
                // "Remove from questions" is a deliberate choice, so it is
                // stated rather than left as an absence.
                removed.append(move.oldPage)
            }
        }
        state.document?.applyPageShift(mapping, removing: removed)
        dismiss()
    }
}
