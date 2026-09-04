import SwiftUI

/// Opens when a question file has lost its lecture — you renamed a PDF, or moved
/// one without the file beside it.
///
/// It suggests a pairing and says what the suggestion rests on, but it never
/// applies one on its own. A wrong pairing silently attaches a semester of
/// questions to the wrong slides, and that is a far worse outcome than being
/// asked a question you could have answered in two seconds.
struct RecoverySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var choices: [String: URL] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)

            if state.pendingOrphans.isEmpty {
                VStack {
                    Spacer()
                    Text("Everything is where it should be.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.dim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.pendingOrphans) { orphan in
                            row(orphan)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                }
            }

            Divider().overlay(palette.line)
            HStack {
                Text("Nothing changes until you pair them. Your questions are safe either way.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .frame(width: 760, height: 560)
        .background(palette.panel)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.pendingOrphans.count == 1
                 ? "1 question file has lost its lecture"
                 : "\(state.pendingOrphans.count) question files have lost their lecture")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text("Question files sit beside their PDF and are named after it. Rename or move the PDF on its own and they get separated — pick the lecture each one belongs to and it will be renamed to match.")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func row(_ orphan: OrphanRecovery.Orphan) -> some View {
        let selected = choices[orphan.id] ?? orphan.best?.pdfURL
        let evidence = orphan.candidates.first { $0.pdfURL == selected }?.evidence ?? OrphanRecovery.Evidence.none

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(orphan.oldName)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(palette.ink)
                Text("\(orphan.questionCount) question\(orphan.questionCount == 1 ? "" : "s") · \(orphan.pageCount) slides")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("belongs to")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.dim)

                Picker("", selection: Binding(
                    get: { selected },
                    set: { choices[orphan.id] = $0 }
                )) {
                    ForEach(orphan.candidates) { candidate in
                        Text(candidate.name).tag(Optional(candidate.pdfURL))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(orphan.candidates.isEmpty)

                Text(evidence.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(evidence.rank >= 2 ? palette.ink2 : palette.dim)

                Spacer(minLength: 0)

                Button("Not now") { state.dismissOrphan(orphan) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.dim)

                Button("Pair") {
                    if let selected { state.adopt(orphan, pdfURL: selected) }
                }
                .disabled(selected == nil)

                Button("Delete") {
                    state.trashOrphan(orphan)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if orphan.candidates.isEmpty {
                Text("Every lecture in the library already has its own questions, so there is nowhere for these to go. The lecture they belong to may have been moved out of the library.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if evidence.rank < 2 {
                Text("Weak match — open the PDF and check it's the right lecture before pairing.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.retired)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}
