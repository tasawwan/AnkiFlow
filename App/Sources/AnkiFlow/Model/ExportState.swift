import Foundation

/// What an export actually did, shown on the export sheet.
///
/// There is no central export database. Each lecture's `.ankiflow.json` carries
/// its own history -- which deck it last went to, and which of its questions
/// have been deleted since. That works because a question belongs to *one* PDF:
/// it cites that PDF's pages, so it cannot move to another lecture. The only
/// thing that moves is the lecture file itself, and a lecture always knows
/// where it last went.
/// How far a "forget what was exported" action reaches.
enum ResetScope: String, CaseIterable, Identifiable {
    case lecture, folder, library
    var id: String { rawValue }

    var label: String {
        switch self {
        case .lecture: return "This lecture"
        case .folder:  return "This folder"
        case .library: return "Whole library"
        }
    }
}

/// Where an export goes. All three produce the same questions; they differ in
/// what lands and where.
enum ExportDestination: String, CaseIterable, Identifiable {
    /// First because it is what you want when it works: no dialog, no import
    /// screen. Falls back to the package when Anki isn't answering.
    case anki
    /// A file. The only one that needs nothing else installed.
    case package
    /// The lectures themselves — PDFs plus question files — zipped.
    case archive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anki:    return "Straight into Anki (recommended)"
        case .package: return "Anki package (.apkg) — last resort"
        case .archive: return "Lectures + questions (.zip)"
        }
    }
}

struct ExportSummary {
    var deckCount: Int = 0
    var newNotes: Int = 0
    var changedNotes: Int = 0
    var unchangedNotes: Int = 0
    var mediaFiles: Int = 0
    /// Cloze questions left behind because their text has no {{cN::}} in it
    /// yet. Reported rather than silently dropped: the note would have imported
    /// and then been invisible, which is a much worse way to find out.
    var skippedCloze: Int = 0
    var packageURL: URL?

    /// Questions removed from a lecture since it was last exported. Anki will
    /// not delete these; the sheet offers a search that selects them.
    var retired: [(qid: String, lecture: String)] = []
    /// Lectures whose folder changed. Anki will not move their cards either.
    var moved: [DeckMove] = []
    /// Slide images removed from Anki's media folder because nothing pointed at
    /// them any more. Only set when the export went straight into Anki.
    var mediaRemoved = 0

    var totalNotes: Int { newNotes + changedNotes + unchangedNotes }

    /// Paste into Anki's browser to select every card of a removed question.
    var retiredSearch: String {
        guard !retired.isEmpty else { return "" }
        // QID:"value" -- the value is quoted, not the whole term, or Anki reads
        // it as a search for literal text rather than as a field match.
        let clause = retired.map { "QID:\"\($0.qid)\"" }.joined(separator: " OR ")
        return "\(AnkiIdentity.noteTypeScope) (\(clause))"
    }

    /// Selects the cards that should be moved, then use Change Deck.
    ///
    /// Searches the *new* path tag, not the old one. Tags are rewritten on
    /// import while deck placement is not — that asymmetry is the whole reason
    /// this report exists — so after the export these cards already carry the
    /// new tag and are still sitting in the old deck. The old tag no longer
    /// exists on them, and searching for it found nothing.
    /// The ones that need you to decide. The automatic ones have already been
    /// applied by the time you see this sheet, so offering them again would be
    /// asking about work that is done.
    var offeredMoves: [DeckMove] { moved.filter { !$0.isAutomatic } }

    func moveSearches() -> [(to: String, search: String)] {
        offeredMoves.map { move in
            (to: move.to, search: Self.moveSearch(from: move.from, to: move.to))
        }
    }

    /// Everything belonging to this lecture that is not already in the deck it
    /// should be in.
    ///
    /// Three clauses because a card can be in three states after an export that
    /// changed the deck name. Unchanged notes were not re-imported at all, so
    /// they still carry the old tag. Changed notes *were* re-imported and took
    /// the new tag -- but Anki still refused to move the card, so they sit in
    /// the old deck wearing the new tag. And a card you dragged somewhere by
    /// hand in the browser has neither deck. Matching on any of the three and
    /// excluding the destination catches all of them exactly once.
    ///
    /// It can't reach another lecture: every one of these names ends in this
    /// lecture's own file name, which is the deepest level of the path.
    static func moveSearch(from oldDeck: String, to newDeck: String) -> String {
        let oldTag = oldDeck.replacingOccurrences(of: " ", with: "-")
        let newTag = newDeck.replacingOccurrences(of: " ", with: "-")
        return "\(AnkiIdentity.noteTypeScope) "
            + "(\"deck:\(oldDeck)\" OR \"tag:\(oldTag)\" OR \"tag:\(newTag)\") "
            + "-\"deck:\(newDeck)\""
    }
}

/// A lecture whose cards are not where its folders say they should be.
struct DeckMove: Identifiable {
    let lecture: String
    let url: URL
    let from: String
    let to: String
    /// True when the two names agreed about everything they both knew and the
    /// new one simply knows more -- you opened a wider folder. Those are applied
    /// during the export instead of being offered, because there is nothing to
    /// decide. A rename or a moved lecture is false, and gets asked about.
    let isAutomatic: Bool

    var id: String { url.path + "→" + to }
}
