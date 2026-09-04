import SwiftUI
import AppKit
import PDFKit

/// Narrow to wide, matching `ResetScope`. Two pickers offering the same three
/// choices in opposite orders is a small thing that makes a sheet feel careless.
enum ExportScope: String, CaseIterable, Identifiable {
    case currentLecture = "This lecture"
    case currentFolder = "This folder"
    case wholeLibrary = "Whole library"
    var id: String { rawValue }
}

struct ExportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scope: ExportScope = .wholeLibrary
    @State private var destination: ExportDestination = .anki
    @State private var ankiReachable: Bool?
    @State private var ankiSituation: AnkiApp.Situation = .notRunning
    @State private var waitingForAnki = false
    @State private var copiedAddOnCode = false
    @State private var archiveResult: ArchiveExporter.Result?
    @State private var deletingRetired = false
    @State private var movingCards = false
    @State private var movedCards: Int?
    @State private var deletedRetired: Int?
    @State private var running = false
    @State private var summary: ExportSummary?
    @State private var errorMessage: String?
    @State private var showReset = false
    @State private var resetScope: ResetScope = .lecture
    @State private var confirmingReset = false
    @State private var resetResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary == nil ? "Export deck" : "Exported")
                .font(.title2.weight(.semibold))

            if let summary {
                results(summary)
            } else if let archiveResult {
                archiveResults(archiveResult)
            } else {
                setup
            }
        }
        .padding(22)
        .frame(width: 600)
        // Selectable throughout: these messages carry things you need to act on
        // -- an add-on code to paste into Anki, a search to paste into the
        // browser, an error to paste to whoever can fix it.
        .textSelection(.enabled)
        .onAppear { probeAnki() }
    }

    // MARK: - Before

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Segmented, matching the Export history picker below. Those two
            // offer the same three choices, and showing one axis as bubbles and
            // the other as a toggle in the same sheet made them look like
            // different kinds of thing.
            HStack(spacing: 10) {
                Text("Include")
                Picker("", selection: $scope) {
                    ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer(minLength: 0)
            }

            Divider()

            Picker("Send to", selection: $destination) {
                ForEach(ExportDestination.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            Text(destinationExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Shown even after the picker has fallen back to .package: the
            // fallback is the reason you want to read it.
            if ankiReachable == false, destination != .archive {
                ankiTrouble
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.retired)
            }

            Divider()

            resetControls

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(running ? "Rendering slides…" : "Export…") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
    }

    /// Resetting belongs here rather than buried in Settings: it only means
    /// anything next to the thing it affects.
    @ViewBuilder
    private var resetControls: some View {
        DisclosureGroup(isExpanded: $showReset) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Forget history for", selection: $resetScope) {
                    ForEach(ResetScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(resetExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(role: .destructive) { confirmingReset = true } label: {
                        Text("Reset Export History").foregroundStyle(.red)
                    }
                    .disabled(resetTargetCount == 0)

                    if let resetResult {
                        Text(resetResult)
                            .font(.caption)
                            .foregroundStyle(Theme.changed)
                    }
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Export history").font(.callout)
        }
        .alert("Reset export history?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                let cleared = state.resetExportHistory(scope: resetScope)
                resetResult = cleared == 0
                    ? "Cleared."
                    : "Cleared — \(cleared) question\(cleared == 1 ? "" : "s") will be rewritten."
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Clears what \(resetTargetLabel) remembers about past exports: the deck it went to, and which questions you deleted. Those reports start fresh, and the next export rewrites those notes rather than only the changed ones.\n\nYour Anki cards are untouched — they're matched by ID, so review history survives.")
        }
    }

    private var resetTargetCount: Int {
        guard let library = state.library else { return 0 }
        return state.lectures(in: resetScope, library: library).count
    }

    private var resetTargetLabel: String {
        switch resetScope {
        case .lecture: return state.document?.title ?? "this lecture"
        case .folder:
            let folder = state.document?.pdfURL.deletingLastPathComponent().lastPathComponent
            return folder ?? "this folder"
        case .library: return state.library?.name ?? "this library"
        }
    }

    private var resetExplanation: String {
        let count = resetTargetCount
        let noun = count == 1 ? "lecture" : "lectures"
        return "Each lecture stores its own export history in its question file. This clears it for \(resetTargetLabel) — \(count) \(noun)."
    }

    // MARK: - After

    private func results(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                stat("\(summary.newNotes)", "new", Theme.added)
                stat("\(summary.changedNotes)", "changed", Theme.changed)
                stat("\(summary.unchangedNotes)", "unchanged", .secondary)
                stat("\(summary.mediaFiles)", "slides", .secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Text("When Anki asks:").font(.callout.weight(.semibold))
                    Label("Update notes — **If newer** (the default)", systemImage: "checkmark")
                    Label("Merge notetypes — **on**", systemImage: "checkmark")
                    Label("Import any learning progress — off (either is safe)", systemImage: "minus")
                }
                .font(.callout)
                .padding(4)
            }

            Text("Your review history on existing cards is preserved. Only the \(summary.changedNotes) changed \(summary.changedNotes == 1 ? "note" : "notes") will be rewritten.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if summary.skippedCloze > 0 {
                // The one thing the exporter leaves behind, so it is said out
                // loud. A cloze note with no deletions imports into Anki and
                // then never appears anywhere -- finding that out weeks later,
                // mid-review, is the outcome this line exists to prevent.
                Text(summary.skippedCloze == 1
                     ? "One cloze question was left out: nothing in it is hidden yet, so Anki would make no cards from it."
                     : "\(summary.skippedCloze) cloze questions were left out: nothing in them is hidden yet, so Anki would make no cards from them.")
                    .font(.callout)
                    .foregroundStyle(Theme.retired)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.moved.isEmpty {
                disclosure(
                    title: "\(summary.moved.count) lecture\(summary.moved.count == 1 ? "" : "s") moved folder",
                    explanation: "Anki never moves existing cards between decks on import. Paste this into the Anki browser, select all, then Change Deck.",
                    searches: summary.moveSearches().map { SearchRow(destination: $0.to, search: $0.search) }
                )
                if ankiReachable == true {
                    HStack(spacing: 10) {
                        Button(movingCards ? "Moving…" : "Move them in Anki") {
                            moveCards(summary.moved.map(\.to))
                        }
                        .disabled(movingCards || movedCards != nil)
                        if let movedCards {
                            Text(movedCards == 0
                                 ? "Nothing needed moving."
                                 : "Moved \(movedCards) card\(movedCards == 1 ? "" : "s").")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !summary.retired.isEmpty {
                disclosure(
                    title: "\(summary.retired.count) question\(summary.retired.count == 1 ? "" : "s") removed since last export",
                    explanation: "Anki has no concept of an upstream deletion — importing a package can add and update cards, never remove one. Paste this into the browser to select those cards, then delete them.",
                    searches: [SearchRow(destination: "Removed", search: summary.retiredSearch)]
                )

                // With Anki running, the same thing without the copy-and-paste.
                // The query is an exact match on the QID field, so it can only
                // ever select notes this app made.
                if ankiReachable == true, let deletedRetired {
                    Text(deletedRetired == 0
                         ? "Anki had none of those cards."
                         : "Deleted \(deletedRetired) card\(deletedRetired == 1 ? "" : "s") from Anki.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let url = summary.packageURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                // Deleting is on the right, where the action you came here to
                // take belongs -- and red, because it removes cards from Anki.
                if !summary.retired.isEmpty, ankiReachable == true {
                    Button(deletingRetired ? "Deleting…" : "Delete \(summary.retired.count) in Anki") {
                        deleteRetired(summary.retired.map(\.qid))
                    }
                    .disabled(deletingRetired || deletedRetired != nil)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    struct SearchRow: Identifiable {
        let destination: String
        let search: String
        var id: String { destination + search }
    }

    private func disclosure(title: String, explanation: String, searches: [SearchRow]) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                ForEach(searches) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.destination).font(.system(size: 10, weight: .medium))
                            Text(row.search)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.search, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    // MARK: - Running

    /// Asked once when the sheet opens, with a two-second timeout, so the Anki
    /// option can say up front whether it is going to work rather than failing
    /// after you have committed to it.
    private func probeAnki() {
        Task {
            let reachable = await AnkiConnect.isAvailable()
            ankiReachable = reachable
            if reachable {
                waitingForAnki = false
            } else {
                // Work out *why* before saying anything. The three reasons want
                // three different buttons, and only one of them is the add-on.
                ankiSituation = AnkiApp.Situation.current
                copiedAddOnCode = false
            }
            // Straight into Anki is the first option and the default, but only
            // when it can actually work -- offering it selected while Anki is
            // closed would make the obvious action the failing one. The notice
            // below stays visible either way, so the switch is never silent.
            if !reachable, destination == .anki { destination = .package }
        }
    }

    /// Launch Anki, then keep asking the port until it answers. Anki takes a
    /// few seconds to come up and load add-ons, so a single re-probe on the
    /// heels of the launch would almost always say no.
    private func openAnki() {
        guard AnkiApp.launch() else {
            ankiSituation = .notInstalled
            return
        }
        waitingForAnki = true
        Task {
            // Roughly 30 seconds. Long enough for a cold start on a slow disk,
            // short enough that a stuck launch doesn't spin forever.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if await AnkiConnect.isAvailable() {
                    ankiReachable = true
                    waitingForAnki = false
                    destination = .anki
                    return
                }
            }
            waitingForAnki = false
            // Anki is up by now and the port still doesn't answer, so the
            // add-on really is the missing piece.
            ankiSituation = AnkiApp.Situation.current
        }
    }

    private func deleteRetired(_ qids: [String]) {
        deletingRetired = true
        Task {
            defer { deletingRetired = false }
            do {
                deletedRetired = try await AnkiConnect.deleteNotes(qids: qids)
                // Clear them wherever they came from. Only clearing the open
                // lecture's meant every other lecture re-offered the same
                // deletions on every future export.
                if let library = state.library {
                    state.clearRetired(in: lecturesInScope(library: library))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func moveCards(_ decks: [String]) {
        movingCards = true
        Task {
            defer { movingCards = false }
            do {
                var total = 0
                for deck in Set(decks) {
                    total += try await AnkiConnect.moveCards(to: deck)
                }
                movedCards = total
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func archiveResults(_ result: ArchiveExporter.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(result.lectures) lecture\(result.lectures == 1 ? "" : "s") and \(result.questionFiles) question file\(result.questionFiles == 1 ? "" : "s"), \(Self.readableSize(result.bytes)).")
                .font(.callout)
            Text("Unzip it anywhere and open that folder as a library — the question files travel with their PDFs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private static func readableSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Anki isn't answering

    /// Shown whenever port 8765 is dead. Says which of the three reasons it is
    /// and offers the one button that fixes that reason -- the point being that
    /// "install the add-on" is useless advice to someone who just has Anki
    /// closed, which is the common case.
    @ViewBuilder
    private var ankiTrouble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ankiTroubleMessage)
                .font(.callout)
                .foregroundStyle(Theme.retired)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                switch ankiSituation {
                case .notInstalled:
                    Button("Get Anki") { NSWorkspace.shared.open(AnkiApp.downloadURL) }
                case .notRunning:
                    Button(waitingForAnki ? "Waiting for Anki…" : "Open Anki") { openAnki() }
                        .disabled(waitingForAnki)
                case .addOnMissing:
                    Button(copiedAddOnCode ? "Code copied" : "Copy add-on code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AnkiConnect.addOnCode, forType: .string)
                        copiedAddOnCode = true
                    }
                    .disabled(copiedAddOnCode)
                }

                Button("Check again") { probeAnki() }
                    .disabled(waitingForAnki)

                if waitingForAnki {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var ankiTroubleMessage: String {
        switch ankiSituation {
        case .notInstalled:
            return "Anki isn't installed on this Mac, so there's nothing to send cards to. Install it, or save a package here and import it wherever Anki lives."
        case .notRunning:
            return waitingForAnki
                ? "Waiting for Anki to finish starting up. This takes a few seconds."
                : "Anki isn't running, so nothing is listening on port 8765. Open it and this will switch back to sending straight into Anki."
        case .addOnMissing:
            return "Anki is running but not answering on port 8765, which means the AnkiConnect add-on isn't installed. In Anki: Tools ▸ Add-ons ▸ Get Add-ons, paste code \(AnkiConnect.addOnCode), then restart Anki."
        }
    }

    private var destinationExplanation: String {
        let root = state.library?.settings.resolvedDeckRoot ?? AnkiIdentity.deckRoot
        switch destination {
        case .package:
            return "One .apkg you open in Anki. Folder structure becomes deck structure under \(root)::."
        case .anki:
            return "The same .apkg, handed straight to a running Anki — no save dialog, no import screen. Identical cards; it only skips the paperwork."
        case .archive:
            return "The lectures themselves: every PDF with its question file beside it, in one zip, folder structure intact. Not for Anki — for handing a course to someone, or keeping a copy that doesn't need this app."
        }
    }

    private func run() {
        guard let library = state.library else { return }
        state.document?.saveNow()
        if destination == .archive {
            runArchive(library: library)
            return
        }
        if destination == .anki {
            runToAnki(library: library)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName(library: library)
        panel.allowedContentTypes = []
        panel.message = "Save the Anki package, then open it in Anki."
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != "apkg" {
            destination = destination.appendingPathExtension("apkg")
        }

        running = true
        errorMessage = nil
        do {
            let plans = try buildPlans(library: library)
            guard !plans.isEmpty else {
                errorMessage = "Nothing to export in this scope yet."
                running = false
                return
            }
            let exporter = AnkiExporter(
                libraryRoot: library.root,
                settings: library.settings,
                templates: state.templates.templates
            )
            let (result, updated) = try exporter.export(plans: plans, to: destination)
            for plan in updated { writeBack(plan) }
            summary = result
            if library.settings.revealAfterExport, let url = result.packageURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        running = false
    }

    /// Builds the package into a temporary file and hands it to Anki. The
    /// exporter is the same one the file export uses -- everything verified
    /// about merging still holds, because nothing about the package changed.
    private func runToAnki(library: Library) {
        running = true
        errorMessage = nil
        Task {
            defer { running = false }
            do {
                let plans = try buildPlans(library: library)
                guard !plans.isEmpty else {
                    errorMessage = "Nothing to export in this scope yet."
                    return
                }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ankiflow-\(UUID().uuidString.prefix(8)).apkg")
                let exporter = AnkiExporter(
                    libraryRoot: library.root,
                    settings: library.settings,
                    templates: state.templates.templates
                )
                let (result, updated) = try exporter.export(plans: plans, to: temporary)
                try await AnkiConnect.importPackage(at: temporary)
                try? FileManager.default.removeItem(at: temporary)
                // Only write the export records back once Anki has actually
                // taken the package: recording a successful export that never
                // arrived would make the next one skip those notes as unchanged.
                for plan in updated { writeBack(plan) }
                summary = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runArchive(library: Library) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.name) lectures.zip"
        panel.message = "Save the lectures and their question files."
        guard panel.runModal() == .OK, var target = panel.url else { return }
        if target.pathExtension.lowercased() != "zip" {
            target = target.appendingPathExtension("zip")
        }

        running = true
        errorMessage = nil
        do {
            // Every lecture in scope, not only the ones with questions: this is
            // an archive of the course, and a lecture you haven't written
            // questions for yet is still part of it.
            let urls = lecturesInScope(library: library)
            guard !urls.isEmpty else {
                errorMessage = "Nothing to export in this scope yet."
                running = false
                return
            }
            let archiver = ArchiveExporter(libraryRoot: library.root)
            archiveResult = try archiver.export(lectures: urls, to: target)
            if let url = archiveResult?.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        running = false
    }

    /// Every lecture the scope covers, whether or not it has questions.
    private func lecturesInScope(library: Library) -> [URL] {
        switch scope {
        case .wholeLibrary:
            return library.allLectures()
        case .currentFolder:
            guard let current = state.document?.pdfURL else { return [] }
            let folder = current.deletingLastPathComponent()
            return library.allLectures().filter { $0.deletingLastPathComponent() == folder }
        case .currentLecture:
            guard let current = state.document?.pdfURL else { return [] }
            return [current]
        }
    }

    private func defaultFileName(library: Library) -> String {
        switch scope {
        case .wholeLibrary:   return "\(library.name).apkg"
        case .currentFolder:  return "\(state.document?.pdfURL.deletingLastPathComponent().lastPathComponent ?? library.name).apkg"
        case .currentLecture: return "\(state.document?.title ?? library.name).apkg"
        }
    }

    private func buildPlans(library: Library) throws -> [LecturePlan] {
        let urls: [URL]
        switch scope {
        case .wholeLibrary:
            urls = library.allLectures()
        case .currentFolder:
            guard let current = state.document?.pdfURL else { return [] }
            let folder = current.deletingLastPathComponent()
            urls = library.allLectures().filter { $0.deletingLastPathComponent() == folder }
        case .currentLecture:
            guard let current = state.document?.pdfURL else { return [] }
            urls = [current]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls.compactMap { url -> LecturePlan? in
            let sidecar = url.deletingPathExtension()
                .appendingPathExtension(AnkiIdentity.sidecarExtension)

            let questions: [Question]
            if state.document?.pdfURL == url {
                questions = state.document?.questions ?? []
            } else {
                guard let data = try? Data(contentsOf: sidecar),
                      let file = try? decoder.decode(SidecarFile.self, from: data) else { return nil }
                questions = file.questions
            }
            guard questions.contains(where: { !$0.isEmpty }) else { return nil }
            guard let pdf = PDFDocument(url: url) else { return nil }

            let sha: String
            if state.document?.pdfURL == url, let open = state.document {
                sha = open.pdfSha256
            } else {
                // Hash the file, don't trust the one recorded last time. The
                // stored value is what the PDF used to be; using it means an
                // annotated lecture keeps the same content hash *and* the same
                // media filenames, so the note counts as unchanged and the cache
                // hands back the old picture. Silent, and exactly the case the
                // fingerprint exists to catch.
                sha = LectureDocument.sha256OfFile(at: url)
            }

            let deckName = library.deckName(for: url)

            let previousDeck: String?
            let retired: [String]
            if state.document?.pdfURL == url, let open = state.document {
                previousDeck = open.lastExportedDeckName
                retired = open.retiredQIDs
            } else if let data = try? Data(contentsOf: sidecar),
                      let file = try? decoder.decode(SidecarFile.self, from: data) {
                previousDeck = file.lastExportedDeckName
                retired = file.retiredQIDs ?? []
            } else {
                previousDeck = nil
                retired = []
            }

            return LecturePlan(
                pdfURL: url,
                pdfSha256: sha,
                deckName: deckName,
                pathTag: library.pathTag(for: url),
                sourceLabel: deckName
                    .replacingOccurrences(of: "\(library.settings.resolvedDeckRoot)::", with: "")
                    .replacingOccurrences(of: "::", with: " / "),
                document: pdf,
                questions: questions.filter { !$0.isEmpty },
                previousDeckName: previousDeck,
                retiredQIDs: retired
            )
        }
    }

    /// Persist the export records so the next export knows what actually changed.
    private func writeBack(_ plan: LecturePlan) {
        if let document = state.document, document.pdfURL == plan.pdfURL {
            var merged = document.questions
            for question in plan.questions {
                if let index = merged.firstIndex(where: { $0.qid == question.qid }) {
                    merged[index].export = question.export
                    // Occlusion questions keep a record per mask. Dropping these
                    // made every mask card look new on every export: re-shipped
                    // media, wrong counts, and no tombstone when one was deleted.
                    merged[index].childExports = question.childExports
                }
            }
            document.questions = merged
            document.recordExport(deckName: plan.deckName)
            document.saveNow()
            return
        }

        let sidecar = plan.pdfURL.deletingPathExtension()
            .appendingPathExtension(AnkiIdentity.sidecarExtension)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecar),
              var file = try? decoder.decode(SidecarFile.self, from: data) else { return }
        for question in plan.questions {
            if let index = file.questions.firstIndex(where: { $0.qid == question.qid }) {
                file.questions[index].export = question.export
                file.questions[index].childExports = question.childExports
            }
        }
        file.lastExportedDeckName = plan.deckName
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let out = try? encoder.encode(file) {
            // An atomic write replaces the file, so the hidden flag has to be
            // reapplied or every export un-hides the question files.
            try? AtomicWrite.write(out, to: sidecar,
                                   hidden: state.library?.settings.hideSidecarFiles ?? true)
        }
    }
}
