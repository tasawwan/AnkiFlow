import Foundation

/// Deciding where a lecture's cards belong when the folders say one thing and
/// the last export says another.
///
/// The problem this exists for: which folder you open as the library decides
/// how much of the hierarchy the app can see. Open `Lecture Materials` and a
/// lecture computes `Block 2::Cardio 04`; open `Block 2` and the same lecture
/// computes `Cardio 04`. Neither is wrong -- the narrower view simply has no
/// way to know what sits above it.
///
/// So a difference between the remembered deck and the computed one is not
/// automatically a conflict. If one path is the tail of the other, the two
/// agree about everything they both know and one of them just knows more
/// ancestors; the longer one is the truth and the shorter one is a partial
/// view of it. Only when neither is a tail of the other has something actually
/// changed -- a folder renamed, or a lecture moved between folders -- and that
/// is the case worth asking about.
enum DeckPath {
    /// What to do about a lecture whose folders and pinned deck disagree.
    enum Reconciliation: Equatable {
        /// They agree.
        case same(String)
        /// The folders know more ancestors than the last export did. Taking the
        /// longer name is safe: nothing the pinned name asserted is being
        /// contradicted, only extended.
        case extended(from: String, to: String)
        /// The folders know fewer ancestors -- you opened a subfolder as the
        /// library. Keep the pinned name and say nothing; the view is narrower
        /// than the truth, which is not a reason to move anything.
        case narrowed(String)
        /// Neither contains the other. A rename, or a lecture that moved. Only
        /// you know which, so this one is offered rather than taken.
        case diverged(from: String, to: String)

        /// Where this export should actually send the cards.
        var deckName: String {
            switch self {
            case .same(let name):        return name
            case .extended(_, let to):   return to
            case .narrowed(let name):    return name
            // Deliberately the old name: the cards are there, and sending new
            // ones somewhere else would split the lecture in two while we wait
            // for an answer.
            case .diverged(let from, _): return from
            }
        }
    }

    static func components(_ deckName: String) -> [String] {
        deckName.components(separatedBy: "::").filter { !$0.isEmpty }
    }

    /// The chain below the deck root, which is the only part the folders have
    /// anything to say about.
    private static func chain(_ deckName: String, root: String) -> [String] {
        var parts = components(deckName)
        if !root.isEmpty, parts.first == root { parts.removeFirst() }
        return parts
    }

    static func reconcile(pinned: String, computed: String, root: String) -> Reconciliation {
        let p = chain(pinned, root: root)
        let c = chain(computed, root: root)
        if p == c { return .same(computed) }
        if c.count > p.count, Array(c.suffix(p.count)) == p {
            return .extended(from: pinned, to: computed)
        }
        if p.count > c.count, Array(p.suffix(c.count)) == c {
            return .narrowed(pinned)
        }
        return .diverged(from: pinned, to: computed)
    }
}
