import Foundation

/// What a note looks like coming back out of Anki.
struct AnkiNote {
    let noteID: Int64
    /// The QID field -- the same string this app put there, which is how a note
    /// finds its way back to a question.
    let guid: String
    let front: String
    let back: String
    /// User tags only. The AnkiFlow path tag is bookkeeping, not something you
    /// chose, and letting it round-trip would import the deck path as a tag.
    let tags: [String]
    /// Slide images this note shows, by filename.
    let media: [String]
}

/// One question whose text or tags differ between here and Anki.
struct SyncEdit: Identifiable {
    enum Side { case ankiOnly, bothChanged }

    let id: String
    let url: URL
    let lecture: String
    let title: String
    let side: Side
    /// Nil when unchanged on the Anki side.
    let front: (mine: String, theirs: String)?
    let back: (mine: String, theirs: String)?
    let tags: (mine: [String], theirs: [String])?
    /// Cloze markup and occlusion prompts are generated from things Anki has no
    /// view of, so their text is not offered -- only their tags.
    let textIsAppOwned: Bool
}

/// A question Anki no longer has.
struct SyncDeletion: Identifiable {
    let id: String
    let url: URL
    let lecture: String
    let title: String
}

/// A lecture whose notes are mostly or entirely gone. Almost always a deck you
/// deleted or a collection you have not imported into yet -- not a hundred
/// individual deletions -- so its questions are reported and left alone.
struct SyncGuarded: Identifiable {
    let id: String
    let lecture: String
    let missing: Int
    let total: Int
}

struct SyncPlan {
    var edits: [SyncEdit] = []
    var deletions: [SyncDeletion] = []
    var guarded: [SyncGuarded] = []

    var isEmpty: Bool { edits.isEmpty && deletions.isEmpty && guarded.isEmpty }
}

enum AnkiSync {
    /// A lecture's questions, as the caller found them.
    struct LectureQuestions {
        let url: URL
        let name: String
        let questions: [Question]
        /// This lecture's own deck-path tags -- the one its folders compute now
        /// and the one it was last exported under.
        ///
        /// They are this app's bookkeeping written into your collection so a
        /// card can be found again; they were never tags you chose, and reading
        /// them back would file the deck path on the question as though you
        /// had. Matched exactly rather than by shape, so a hierarchical tag you
        /// do keep in Anki -- `pharm::antibiotics` -- still comes home.
        var pathTags: Set<String> = []
    }

    // MARK: - Reading Anki

    /// Everything, with fields. What the sheet uses.
    static func fetchNotes() async throws -> (notes: [AnkiNote], allGuids: Set<String>?) {
        let ids = try await AnkiConnect.findNotesScoped()
        guard !ids.isEmpty else { return ([], []) }
        let notes = try await AnkiConnect.notesInfo(ids)
        return (notes, Set(notes.map(\.guid)))
    }

    /// What the background poll uses: the full id list is cheap and is all the
    /// deletion check needs, while fields -- which are megabytes of image HTML
    /// across a collection -- are fetched only for notes touched recently.
    ///
    /// The narrowing is why this can run on a timer at all. It also means an
    /// edit made days ago and never picked up is invisible here; the sheet does
    /// the full pass, which is the backstop.
    static func fetchRecent(expecting expected: Int) async throws
        -> (notes: [AnkiNote], allGuids: Set<String>?) {
        let all = try await AnkiConnect.findNotesScoped()

        // Deletions are looked for only when the count says there are some.
        // Reading a QID means reading a note's fields, and a collection's worth
        // of image markup is not something to fetch every minute for a check
        // that almost always comes back clean. A count that has not dropped is
        // taken as nothing deleted -- not a proof (a deletion and an unrelated
        // addition would cancel out), which is why the sheet still does the
        // full pass and is the authority.
        let allGuids: Set<String>? = all.count < expected
            ? Set(try await AnkiConnect.guids(of: all))
            : nil

        let recent = await AnkiConnect.findNotesEditedRecently()
        guard !recent.isEmpty else { return ([], allGuids) }
        return (try await AnkiConnect.notesInfo(recent), allGuids)
    }

    // MARK: - The three-way merge

    /// Compares what is here with what Anki has, using the text fingerprint
    /// recorded at export as the common ancestor.
    ///
    /// The three-way part is what makes this safe to run twice. Two-way sync can
    /// only see *that* two sides differ and has to guess which one to keep;
    /// with the ancestor, "they moved", "we moved" and "both moved" are three
    /// distinguishable facts, and only the third needs a human.
    ///
    /// A question with no recorded ancestor -- never exported, or exported
    /// before this existed -- is skipped rather than guessed at.
    /// - Parameters:
    ///   - ankiNotes: notes whose fields were fetched. May be a subset.
    ///   - allGuids: every note Anki currently holds, or nil when that was not
    ///     checked -- in which case no deletions are reported. A question
    ///     missing from this set is deleted; a question missing from
    ///     `ankiNotes` alone is simply one whose fields were not asked for.
    static func plan(lectures: [LectureQuestions],
                     ankiNotes: [AnkiNote],
                     allGuids: Set<String>?,
                     deletionGuard: Double = 0.5) -> SyncPlan {
        var plan = SyncPlan()
        let byGuid = Dictionary(ankiNotes.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })

        for lecture in lectures {
            let exported = lecture.questions.filter { $0.export != nil }
            guard !exported.isEmpty else { continue }

            var missing: [Question] = []
            for question in exported {
                if let allGuids, !allGuids.contains(question.qid) {
                    missing.append(question)
                    continue
                }
                guard let note = byGuid[question.qid] else { continue }
                guard let base = question.export?.textHash else { continue }

                let theirTags = note.tags.filter { !lecture.pathTags.contains($0) }
                let mine = question.textFingerprint
                let theirs = Question.textFingerprint(front: note.front, back: note.back,
                                                      tags: theirTags)
                guard theirs != base else { continue }   // Anki didn't move.

                let appOwned = question.kind == .cloze || question.kind == .occlusion
                plan.edits.append(SyncEdit(
                    id: question.qid,
                    url: lecture.url,
                    lecture: lecture.name,
                    title: title(of: question),
                    side: mine == base ? .ankiOnly : .bothChanged,
                    front: appOwned || same(question.front, note.front)
                        ? nil : (mine: question.front, theirs: note.front),
                    back: appOwned || same(question.back, note.back)
                        ? nil : (mine: question.back, theirs: note.back),
                    tags: sameTags(question.tags, theirTags)
                        ? nil : (mine: question.tags, theirs: theirTags),
                    textIsAppOwned: appOwned
                ))
            }

            // The guard. Deleting a deck to clear space looks exactly like
            // deleting every card in it one at a time, and only one of those is
            // something you want offered back as "shall I remove these here
            // too?". So a lecture that has lost most of its notes is reported
            // rather than acted on; a lecture that has lost a couple is the
            // case this feature is for.
            guard !missing.isEmpty else { continue }
            if Double(missing.count) / Double(exported.count) > deletionGuard {
                plan.guarded.append(SyncGuarded(id: lecture.url.path,
                                                lecture: lecture.name,
                                                missing: missing.count,
                                                total: exported.count))
            } else {
                plan.deletions.append(contentsOf: missing.map {
                    SyncDeletion(id: $0.qid, url: lecture.url,
                                 lecture: lecture.name, title: title(of: $0))
                })
            }
        }
        return plan
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameTags(_ a: [String], _ b: [String]) -> Bool {
        a.map { $0.lowercased() }.sorted() == b.map { $0.lowercased() }.sorted()
    }

    private static func title(of question: Question) -> String {
        let text = question.front.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(no text)" }
        return text.count <= 70 ? text : String(text.prefix(70)) + "…"
    }

    // MARK: - Anki's HTML, back to text

    /// The inverse of the exporter's `paragraphs`, plus the extra shapes Anki's
    /// own editor produces. Typing a newline there gives you a `<div>` or a
    /// `<br>` depending on where you are, and a run of spaces becomes `&nbsp;` --
    /// none of which came from this app, and all of which would otherwise read
    /// as an edit the moment you opened a card and closed it again.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</div>\\s*<div>", "\n"),
            ("(?i)</?div[^>]*>", "\n"),
            ("(?i)</p>\\s*<p[^>]*>", "\n\n"),
            ("(?i)</?p[^>]*>", "\n")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                         options: .regularExpression)
        for (entity, character) in [
            ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")   // ampersand last.
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Anki is free with trailing blank lines; they are not an edit.
        return text.replacingOccurrences(of: "[ \\t]+\n", with: "\n",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
