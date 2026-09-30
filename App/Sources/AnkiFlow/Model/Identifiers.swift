import Foundation

/// A ULID: 48 bits of millisecond timestamp followed by 80 bits of randomness,
/// rendered in Crockford base32. Sorts lexicographically by creation time, which
/// is why questions can be ordered by insertion without storing an index.
///
/// This value becomes the Anki note GUID verbatim (see AnkiExporter), so it must
/// never change or be reused once a question has been exported.
enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(date: Date = Date()) -> String {
        var chars = [Character]()
        chars.reserveCapacity(26)

        // 48-bit timestamp -> 10 base32 characters
        var ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var timeChars = [Character]()
        for _ in 0..<10 {
            timeChars.append(alphabet[Int(ms & 0x1F)])
            ms >>= 5
        }
        chars.append(contentsOf: timeChars.reversed())

        // 80 bits of randomness -> 16 base32 characters
        for _ in 0..<16 {
            chars.append(alphabet[Int.random(in: 0..<32)])
        }
        return String(chars)
    }
}

/// Stable identifiers that are baked into every exported deck.
///
/// Changing any of these after a first export breaks merging: Anki matches notes
/// by GUID within a note type, and a changed note type makes updates fail
/// outright. They are constants, deliberately, and Settings shows them read-only.
/// File names as the Finder shows them, rather than as POSIX stores them.
///
/// Classic Mac OS separated paths with `:`, so `/` was an ordinary character in
/// a name; Unix is the exact inverse. macOS reconciles the two by *swapping*
/// them at the file-name layer: type `Cardio 1/2.pdf` into the Finder and the
/// bytes on disk read `Cardio 1:2.pdf`, with the Finder swapping back whenever
/// it draws the name.
///
/// Every name AnkiFlow reads comes off `URL`, which is the POSIX side, so
/// without this a lecture you named with a slash turns up everywhere -- the
/// library list, the deck, the tag, the note's title -- wearing a colon you
/// never typed.
///
/// One direction only. The swap is for *showing* a name and for the names
/// AnkiFlow hands to Anki; it must never be applied to a path, where a slash
/// means what it always meant.
extension URL {
    /// This file's name the way the Finder writes it, extension and all.
    var finderName: String { lastPathComponent.asFinderName }

    /// The same, without the extension -- a lecture's name.
    var lectureName: String { deletingPathExtension().lastPathComponent.asFinderName }
}

extension String {
    var asFinderName: String { replacingOccurrences(of: ":", with: "/") }

    /// The other direction: a name somebody typed, turned into the single path
    /// component the disk will actually hold.
    ///
    /// Without it, renaming a lecture to "Block 1/2" hands
    /// `appendingPathComponent` something it reads as two components, and the
    /// rename either lands in a folder that does not exist or quietly makes
    /// one. The Finder answers this by storing a colon; so does this.
    var asPOSIXName: String { replacingOccurrences(of: "/", with: ":") }
}

enum AnkiIdentity {
    static let appName = "AnkiFlow"

    /// Note type name and id. Fixed forever.
    static let noteTypeName = "AnkiFlow Note v1"
    static let noteTypeID: Int64 = 2094605586

    /// The cloze note type. Same seven fields in the same order; `type: 1` in
    /// the model JSON is the only structural difference, and it is what makes
    /// Anki generate one card per {{cN::}} ordinal.
    static let clozeNoteTypeName = "AnkiFlow Cloze v1"
    static let clozeNoteTypeID: Int64 = 1313277180

    /// An Anki search term matching notes of either AnkiFlow model.
    ///
    /// Every search this app hands to Anki -- retiring questions, moving decks,
    /// deleting notes -- must scope to *both*, or it silently misses every cloze
    /// card the moment one exists.
    static var noteTypeScope: String {
        "(\"note:\(noteTypeName)\" OR \"note:\(clozeNoteTypeName)\")"
    }

    /// Field order is part of the contract. Never reorder, never insert.
    static let fields = ["Front", "FrontMedia", "Back", "BackMedia", "Extra", "Source", "QID"]

    /// Every deck this app produces hangs off this root.
    static let deckRoot = "AnkiFlow"

    /// Tag prefix. Tags update on re-import even when deck placement does not,
    /// so these are the reliable record of where a question belongs.
    static let tagPrefix = "AnkiFlow"

    static let sidecarExtension = "ankiflow.json"

    /// Lecture notes live in a plain Markdown file beside the PDF, named after
    /// it: `Innate Immunity.pdf` gets `Innate Immunity Notes.md`.
    ///
    /// A `.md` rather than another private format so the notes outlive this app:
    /// they open in anything, and deleting AnkiFlow leaves you with a folder of
    /// PDFs and a folder of notes about them. The " Notes" in the name is what
    /// makes that folder readable — a bare `Innate Immunity.md` beside
    /// `Innate Immunity.pdf` says nothing about which is which.
    static let notesExtension = "md"
    static let notesSuffix = " Notes"

    /// Everything that belongs to a lecture besides the PDF itself.
    ///
    /// One list, used by every operation that has to keep the set together --
    /// rename, move, trash, recover. Adding a companion file anywhere else means
    /// finding every one of those call sites again and missing one.
    ///
    /// Each case builds its own name from the PDF's, rather than the set sharing
    /// a stem: the question file appends an extension and the note file appends
    /// a word *and* an extension, so a rename has to ask the case for both ends.
    enum Companion: CaseIterable {
        case questions, notes

        func url(for pdfURL: URL) -> URL {
            let stem = pdfURL.deletingPathExtension()
            switch self {
            case .questions:
                return stem.appendingPathExtension(sidecarExtension)
            case .notes:
                return stem.deletingLastPathComponent()
                    .appendingPathComponent(stem.lastPathComponent + notesSuffix)
                    .appendingPathExtension(notesExtension)
            }
        }
    }

    static func companions(of pdfURL: URL) -> [URL] {
        Companion.allCases.map { $0.url(for: pdfURL) }
    }

    static func notesURL(for pdfURL: URL) -> URL {
        Companion.notes.url(for: pdfURL)
    }

    /// "owner/repo" on GitHub. Used only to look up the latest release when
    /// checking for updates -- change it if you fork.
    static let repository = "tasawwan/ankiflow"
}
