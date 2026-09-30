import Foundation

/// Talks to a running Anki through the AnkiConnect add-on on localhost:8765.
///
/// The design decision worth knowing: this does **not** create notes field by
/// field. It builds exactly the same `.apkg` the file export builds, hands it to
/// Anki, and asks Anki to import it. So the GUID matching, the `mod` discipline
/// and the frozen note type — the parts that must never be wrong, and that the
/// round-trip test verifies — stay on one code path. AnkiConnect only replaces
/// the save dialog and the import screen.
///
/// The add-on is third party and Anki must be running. Everything here fails
/// softly: if nobody answers on the port, the file export is still right there.
enum AnkiConnect {
    static let endpoint = URL(string: "http://127.0.0.1:8765")!

    /// The AnkiConnect add-on's code on ankiweb.net. Lives here so the export
    /// window, the error text and the README can't drift apart.
    static let addOnCode = "2055492159"

    enum Failure: LocalizedError {
        case unreachable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "Anki isn't answering on port 8765. Open Anki, and make sure the AnkiConnect add-on is installed (Tools ▸ Add-ons ▸ Get Add-ons, code \(addOnCode))."
            case .refused(let message):
                return "Anki refused the import: \(message)\n\nSaving an .apkg and importing it by hand always works, and produces exactly the same cards."
            }
        }
    }

    private struct Response: Decodable {
        let result: AnyCodableValue?
        let error: String?
    }

    /// AnkiConnect returns differently-shaped results per action, and we only
    /// ever need "did it work" and the odd string.
    struct AnyCodableValue: Decodable {
        let string: String?
        let bool: Bool?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            string = try? container.decode(String.self)
            bool = try? container.decode(Bool.self)
        }
    }

    private static func call(_ action: String, params: [String: Any] = [:],
                             timeout: TimeInterval = 30) async throws -> AnyCodableValue? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action, "version": 6, "params": params
        ])

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let error = decoded.error, !error.isEmpty { throw Failure.refused(error) }
        return decoded.result
    }

    /// True when Anki is running with the add-on installed. Used to decide
    /// whether to offer the option at all, so it is short and never throws.
    static func isAvailable() async -> Bool {
        // Reachability is "did it answer", not "did it answer with something".
        // A do/catch says that; `try? != nil` would also report false for an
        // action whose result is legitimately null.
        do {
            _ = try await call("version", timeout: 2)
            return true
        } catch {
            return false
        }
    }

    /// Finds and deletes notes by their AnkiFlow id.
    ///
    /// Safe to point at a live collection because the query is an exact match on
    /// the QID field, which only notes this app made ever carry. Anki's package
    /// import can never delete anything -- this is the only way a question you
    /// removed here can stop existing there.
    /// The last search used, so a "found nothing" can be pasted into Anki's
    /// browser rather than argued about.
    private(set) static var lastQuery = ""

    static func deleteNotes(qids: [String]) async throws -> Int {
        guard !qids.isEmpty else { return 0 }
        // Quote the *value*, not the whole term. `"QID:abc"` is a search for
        // the literal text QID:abc in any field, which matches nothing --
        // `QID:"abc"` is the field search we actually want. That one character
        // of misplaced quoting is why deleting reported "Anki had none of them".
        // Scoped to our note type so it can only ever reach cards this app made.
        let clauses = qids.map { "QID:\"\($0)\"" }.joined(separator: " OR ")
        let query = "\(AnkiIdentity.noteTypeScope) (\(clauses))"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": "findNotes", "version": 6, "params": ["query": query]
        ])

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let found = try JSONDecoder().decode(NoteIDs.self, from: data)
        if let error = found.error, !error.isEmpty { throw Failure.refused(error) }
        let ids = found.result ?? []
        guard !ids.isEmpty else { return 0 }
        lastQuery = query

        _ = try await call("deleteNotes", params: ["notes": ids], timeout: 60)
        return ids.count
    }

    /// Puts cards that belong to a deck into it. The counterpart of
    /// `deleteNotes`: importing a package can neither delete a card nor move
    /// one, and these two are the only way to do either without the browser.
    static func moveCards(from oldDeck: String, to deck: String) async throws -> Int {
        let query = ExportSummary.moveSearch(from: oldDeck, to: deck)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": "findCards", "version": 6, "params": ["query": query]
        ])

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let found = try JSONDecoder().decode(NoteIDs.self, from: data)
        if let error = found.error, !error.isEmpty { throw Failure.refused(error) }
        let ids = found.result ?? []
        guard !ids.isEmpty else { return 0 }
        lastQuery = query

        // The notes have to be collected *before* the move: the query is
        // "tagged as living there, not in the deck we want", and the moment
        // changeDeck runs it matches nothing.
        let notes = await findNotes(matching: query)

        _ = try await call("changeDeck", params: ["cards": ids, "deck": deck], timeout: 60)

        // And carry the path tag with them. The tag is not part of a note's
        // content hash, so the next export only rewrites the notes you actually
        // edited -- every untouched note would keep claiming it lives in the old
        // deck, and the *next* move would search under a tag that half the cards
        // no longer have and quietly leave them behind.
        let tag = oldDeck.replacingOccurrences(of: " ", with: "-")
        let newTag = deck.replacingOccurrences(of: " ", with: "-")
        if newTag != tag, !notes.isEmpty {
            // Best-effort: a collection that refuses the rename still got its
            // cards moved, which is the part you asked for.
            _ = try? await call("replaceTags", params: [
                "notes": notes, "tag_to_replace": tag, "replace_with_tag": newTag
            ], timeout: 60)
        }
        return ids.count
    }

    /// Removes a deck once nothing is left in it.
    ///
    /// Checked rather than assumed, and checked without our note-type scope on
    /// purpose: the question is whether *anything* is in there, including cards
    /// this app never made. A deck that still holds something is left alone.
    static func deleteDeckIfEmpty(_ deck: String) async {
        let remaining = await findCards(matching: "\"deck:\(deck)\"")
        guard remaining.isEmpty else { return }
        _ = try? await call("deleteDecks",
                            params: ["decks": [deck], "cardsToo": true],
                            timeout: 60)
    }

    // MARK: - Reading back

    /// Every note this app has ever made, as Anki currently holds it.
    static func findNotesScoped(query extra: String = "") async throws -> [Int64] {
        let search = extra.isEmpty
            ? AnkiIdentity.noteTypeScope
            : "\(AnkiIdentity.noteTypeScope) \(extra)"
        return await find("findNotes", matching: search)
    }

    static func guids(of ids: [Int64]) async throws -> [String] {
        try await notesInfo(ids).map(\.guid)
    }

    /// Notes edited in the last day. Best-effort: if the collection refuses the
    /// search -- an older Anki that doesn't know `edited:` -- this returns
    /// nothing rather than throwing, and the poll simply finds no edits until
    /// the sheet is opened.
    static func findNotesEditedRecently(days: Int = 1) async -> [Int64] {
        await find("findNotes", matching: "\(AnkiIdentity.noteTypeScope) edited:\(days)")
    }

    /// Fields and tags for the given notes.
    ///
    /// Asked for in batches: `notesInfo` returns every field of every note,
    /// including the image stacks, and a whole collection in one response is
    /// megabytes of HTML for the sake of two short text fields.
    static func notesInfo(_ ids: [Int64]) async throws -> [AnkiNote] {
        var out: [AnkiNote] = []
        for batch in stride(from: 0, to: ids.count, by: 200).map({
            Array(ids[$0..<min($0 + 200, ids.count)])
        }) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "action": "notesInfo", "version": 6, "params": ["notes": batch]
            ])

            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                throw Failure.unreachable
            }
            let decoded = try JSONDecoder().decode(NotesInfo.self, from: data)
            if let error = decoded.error, !error.isEmpty { throw Failure.refused(error) }

            for note in decoded.result ?? [] {
                let guid = note.fields["QID"]?.value ?? ""
                guard !guid.isEmpty else { continue }
                out.append(AnkiNote(
                    noteID: note.noteId,
                    guid: guid,
                    front: AnkiSync.plainText(fromHTML: note.fields["Front"]?.value ?? ""),
                    back: AnkiSync.plainText(fromHTML: note.fields["Back"]?.value ?? ""),
                    // The path tag is this app's bookkeeping. Letting it back in
                    // would turn the deck path into a tag you never chose.
                    tags: note.tags.filter { !$0.hasPrefix(AnkiIdentity.tagPrefix) },
                    media: Self.imageNames(in: (note.fields["FrontMedia"]?.value ?? "")
                                           + (note.fields["BackMedia"]?.value ?? ""))
                ))
            }
        }
        return out
    }

    private static func imageNames(in html: String) -> [String] {
        let pattern = "src=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                return text.substring(with: match.range(at: 1))
            }
    }

    /// Removes slide images in Anki's media folder that nothing points at.
    ///
    /// Every image AnkiFlow makes is named from the PDF's hash, so annotating a
    /// lecture and re-exporting gives its slides new filenames and strands the
    /// old ones. Nothing in Anki removes them, and for a lecture you annotate
    /// every week that is most of what the collection weighs.
    ///
    /// Scoped by the `af_` prefix and checked against what the notes actually
    /// reference, so it can only ever reach files this app wrote and is not
    /// using. Anki's own Check Media is the blunt version of this; it also
    /// catches everything else in your collection, which is why this one is
    /// narrow enough to run on its own.
    static func deleteUnusedMedia() async -> Int {
        guard let ours = try? await mediaFileNames(matching: "af_*"), !ours.isEmpty else { return 0 }
        guard let ids = try? await findNotesScoped() else { return 0 }
        guard let notes = try? await notesInfo(ids) else { return 0 }

        let referenced = Set(notes.flatMap(\.media))
        let orphans = ours.filter { !referenced.contains($0) }
        guard !orphans.isEmpty else { return 0 }

        var removed = 0
        for name in orphans {
            let result = try? await call("deleteMediaFile",
                                         params: ["filename": name], timeout: 30)
            _ = result
            removed += 1
        }
        return removed
    }

    private static func mediaFileNames(matching pattern: String) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": "getMediaFilesNames", "version": 6, "params": ["pattern": pattern]
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw Failure.unreachable
        }
        struct Names: Decodable { let result: [String]?; let error: String? }
        let decoded = try JSONDecoder().decode(Names.self, from: data)
        if let error = decoded.error, !error.isEmpty { throw Failure.refused(error) }
        return decoded.result ?? []
    }

    private struct NotesInfo: Decodable {
        struct Note: Decodable {
            struct Field: Decodable { let value: String }
            let noteId: Int64
            let tags: [String]
            let fields: [String: Field]
        }
        let result: [Note]?
        let error: String?
    }

    private static func findCards(matching query: String) async -> [Int64] {
        await find("findCards", matching: query)
    }

    private static func findNotes(matching query: String) async -> [Int64] {
        await find("findNotes", matching: query)
    }

    private static func find(_ action: String, matching query: String) async -> [Int64] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": action, "version": 6, "params": ["query": query]
        ])
        guard let response = try? await URLSession.shared.data(for: request),
              let found = try? JSONDecoder().decode(NoteIDs.self, from: response.0) else {
            return []
        }
        return found.result ?? []
    }

    private struct NoteIDs: Decodable {
        let result: [Int64]?
        let error: String?
    }

    /// Hands a built package to Anki.
    static func importPackage(at url: URL) async throws {
        // Tried in order, cheapest first.
        //
        // The add-on's docs say the path is relative to collection.media, but
        // builds differ: some hand the string straight to Anki's importer, where
        // an absolute path just works and a bare filename fails with "No such
        // file or directory" — which is exactly what we were getting. So try the
        // file where it already is, then staged in the media folder by absolute
        // path, then by the bare name the docs describe.
        var lastError = ""

        if try await attemptImport(path: url.path) { return }

        // Staging: copy into collection.media if Anki will say where that is.
        if let result = try? await call("getMediaDirPath"),
           let directory = result.string, !directory.isEmpty,
           FileManager.default.fileExists(atPath: directory) {
            let name = "ankiflow-import-\(UUID().uuidString.prefix(8)).apkg"
            let target = URL(fileURLWithPath: directory).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                defer { try? FileManager.default.removeItem(at: target) }
                if try await attemptImport(path: target.path) { return }
                if try await attemptImport(path: name) { return }
                lastError = "Anki could not read the package from its media folder."
            }
        } else {
            // No media path available, so upload it. Anki reports the name it
            // actually used, which is not always the one we asked for.
            let name = "ankiflow-import-\(UUID().uuidString.prefix(8)).apkg"
            let data = try Data(contentsOf: url)
            let stored = try await call("storeMediaFile", params: [
                "filename": name,
                "data": data.base64EncodedString()
            ], timeout: 300)
            let actual = stored?.string.flatMap { $0.isEmpty ? nil : $0 } ?? name
            defer { Task { _ = try? await call("deleteMediaFile", params: ["filename": actual]) } }
            if try await attemptImport(path: actual) { return }
            lastError = "Anki stored the package as \(actual) but could not import it."
        }

        throw Failure.refused(lastError.isEmpty
            ? "none of the import paths worked. Your AnkiConnect version may be older than importPackage."
            : lastError)
    }

    /// True on success. A refusal is a "no" to try the next path with, not an
    /// error to abandon the whole attempt for; anything else (Anki gone away)
    /// still throws.
    private static func attemptImport(path: String) async throws -> Bool {
        do {
            let result = try await call("importPackage", params: ["path": path], timeout: 300)
            return result?.bool != false
        } catch Failure.refused {
            return false
        }
    }
}
