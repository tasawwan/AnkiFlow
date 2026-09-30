import SwiftUI

/// Bringing edits back from Anki.
///
/// Every row is a decision. Nothing here applies until you press Apply, and
/// nothing is pre-decided except where there is genuinely nothing to decide:
/// a card only you changed in Anki defaults to taking that change, a card both
/// sides changed defaults to keeping what is here, and a deletion defaults to
/// off. The defaults are a starting point, not an answer.
struct SyncSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Per row: true means take Anki's version.
    @State private var takeTheirs: [String: Bool] = [:]
    @State private var removeHere: Set<String> = []
    @State private var plan: SyncPlan?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var applied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Changes in Anki")
                .font(.title2.weight(.semibold))

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your collection…").foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.retired)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let applied {
                Text(applied == 0
                     ? "Nothing was changed."
                     : "Applied \(applied) change\(applied == 1 ? "" : "s").")
                    .font(.callout)
            } else if let plan, plan.isEmpty {
                Text("Nothing to bring back — every card matches what's here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !plan.edits.isEmpty { edits(plan.edits) }
                        if !plan.deletions.isEmpty { deletions(plan.deletions) }
                        if !plan.guarded.isEmpty { guarded(plan.guarded) }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 420)
            }

            Divider()

            HStack {
                Button(applied == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if applied == nil, let plan, !plan.isEmpty {
                    Button("Apply") { apply(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(loading)
                }
            }
        }
        .padding(22)
        .frame(width: 640)
        .textSelection(.enabled)
        .task { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func edits(_ rows: [SyncEdit]) -> some View {
        Text("Edited in Anki")
            .font(.callout.weight(.semibold))
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(row.lecture).font(.caption).foregroundStyle(.secondary)
                }

                if row.side == .bothChanged {
                    Label("Changed in both places since the last export",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.retired)
                }
                if row.textIsAppOwned {
                    Text("Cloze markup and occlusion regions are built here, so only this card's tags can come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let front = row.front { comparison("Front", front.mine, front.theirs) }
                if let back = row.back { comparison("Back", back.mine, back.theirs) }
                if let tags = row.tags {
                    comparison("Tags",
                               tags.mine.sorted().joined(separator: ", "),
                               tags.theirs.sorted().joined(separator: ", "))
                }

                Picker("", selection: binding(for: row)) {
                    Text("Keep mine").tag(false)
                    Text("Take Anki's").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .padding(10)
            .background(Theme.slate.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func deletions(_ rows: [SyncDeletion]) -> some View {
        Text("Deleted in Anki")
            .font(.callout.weight(.semibold))
        Text("These cards are gone from your collection. Removing them here too is optional — the questions stay in the lecture until you say so.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { removeHere.contains(row.id) },
                set: { on in
                    if on { removeHere.insert(row.id) } else { removeHere.remove(row.id) }
                }
            )) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.callout)
                    Spacer(minLength: 8)
                    Text(row.lecture).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func guarded(_ rows: [SyncGuarded]) -> some View {
        Text("Left alone")
            .font(.callout.weight(.semibold))
        // The whole point of the guard, said out loud. Deleting a deck to clear
        // space and deleting a handful of cards look identical from here, and
        // only one of them is something you would want offered back.
        Text("These lectures are missing most of their cards in Anki, which usually means the deck was removed rather than the cards deleted one by one. Nothing is offered for them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(rows) { row in
            HStack {
                Text(row.lecture).font(.callout)
                Spacer(minLength: 8)
                Text("\(row.missing) of \(row.total) missing")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func comparison(_ label: String, _ mine: String, _ theirs: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                field(mine.isEmpty ? "(empty)" : mine, tint: Theme.slate)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                field(theirs.isEmpty ? "(empty)" : theirs, tint: Theme.changed)
            }
        }
    }

    private func field(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Wiring

    private func binding(for row: SyncEdit) -> Binding<Bool> {
        Binding(
            get: { takeTheirs[row.id] ?? (row.side == .ankiOnly) },
            set: { takeTheirs[row.id] = $0 }
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let fetched = try await AnkiSync.fetchNotes()
            plan = AnkiSync.plan(lectures: state.lectureQuestionsForSync(),
                                 ankiNotes: fetched.notes,
                                 allGuids: fetched.allGuids)
        } catch {
            errorMessage = "Couldn't read your collection: \(error.localizedDescription)"
        }
    }

    private func apply(_ plan: SyncPlan) {
        var resolutions: [AppState.SyncResolution] = []

        for row in plan.edits where takeTheirs[row.id] ?? (row.side == .ankiOnly) {
            resolutions.append(AppState.SyncResolution(
                url: row.url,
                qid: row.id,
                front: row.textIsAppOwned ? nil : row.front?.theirs,
                back: row.textIsAppOwned ? nil : row.back?.theirs,
                tags: row.tags?.theirs
            ))
        }
        for row in plan.deletions where removeHere.contains(row.id) {
            resolutions.append(AppState.SyncResolution(
                url: row.url, qid: row.id, delete: true
            ))
        }

        let deletions = resolutions.filter(\.delete).count
        applied = state.applySync(resolutions) + deletions
        // Whatever is left after this is no longer waiting on you.
        state.pendingSync = nil
    }
}
