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
enum AnkiIdentity {
    static let appName = "AnkiFlow"

    /// Note type name and id. Fixed forever.
    static let noteTypeName = "AnkiFlow Note v1"
    static let noteTypeID: Int64 = 2094605586

    /// Reserved for future cloze support so the field set never has to change.
    static let clozeNoteTypeName = "AnkiFlow Cloze v1"
    static let clozeNoteTypeID: Int64 = 1313277180

    /// Field order is part of the contract. Never reorder, never insert.
    static let fields = ["Front", "FrontMedia", "Back", "BackMedia", "Extra", "Source", "QID"]

    /// Every deck this app produces hangs off this root.
    static let deckRoot = "AnkiFlow"

    /// Tag prefix. Tags update on re-import even when deck placement does not,
    /// so these are the reliable record of where a question belongs.
    static let tagPrefix = "AnkiFlow"

    static let sidecarExtension = "ankiflow.json"

    /// "owner/repo" on GitHub. Used only to look up the latest release when
    /// checking for updates -- change it if you fork.
    static let repository = "tasawwan/ankiflow"
}
