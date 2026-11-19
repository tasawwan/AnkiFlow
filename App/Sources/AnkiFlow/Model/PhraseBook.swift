import Foundation

/// Wording you have used before, offered back while you type the next question.
///
/// The questions in a deck are not all different. "What does ALT do? What is it
/// a biomarker of?" and the same sentence about AST are one question asked
/// twice, and typing the second one out is work the first one already did. The
/// slide vocabulary cannot help: the words that differ are the only ones it
/// knows, and the words that repeat are ordinary English.
///
/// So the corpus here is your own question list, and the match is deliberately
/// loose. A past question still counts as the one you are writing with up to
/// two words swapped out -- that is what makes it a *shape* rather than a
/// string -- and what is offered is the rest of that shape, from wherever you
/// have got to. Swap "histamine" for "serotonin" and the offer is still
/// "? What cofactor is important?".
enum PhraseBook {
    /// How many words may differ before this stops being the same question.
    /// Two: "What does ALT do?" against AST is one, and a question whose
    /// opening you have changed twice is one you are writing, not repeating.
    static let maximumWildcards = 2
    /// How many words have to line up before anything is offered. Three keeps
    /// "What is the" from dragging a whole question in behind it.
    static let minimumMatched = 3
    /// A word you are part-way through has to be this long before it is allowed
    /// to be the one that differs -- "s" is not yet evidence of anything.
    static let minimumPartial = 3
    /// Nothing shorter is worth drawing. Where several past questions disagree
    /// the offer shrinks to what they agree on, and that is often a space.
    static let minimumTail = 3
    /// Below this there is not enough typed to be repeating anything.
    static let minimumTyped = 6

    private static let punctuation = Set("?.,;:!—–-()[]{}\"'`")

    /// A word, and the whole run of non-space characters it sits in.
    ///
    /// The two differ by the punctuation, and the difference is the point:
    /// "histamine?" is the word "histamine" for matching and the characters
    /// "histamine?" for offering, so the question mark that ends it comes back
    /// as part of what is suggested.
    struct Token {
        let chunk: Range<Int>
        let core: Range<Int>
    }

    static func tokens(in characters: [Character]) -> [Token] {
        var out: [Token] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let start = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            var coreStart = start
            var coreEnd = index
            while coreStart < coreEnd, punctuation.contains(characters[coreStart]) { coreStart += 1 }
            while coreEnd > coreStart, punctuation.contains(characters[coreEnd - 1]) { coreEnd -= 1 }
            out.append(Token(chunk: start..<index, core: coreStart..<coreEnd))
        }
        return out
    }

    private static func word(_ characters: [Character], _ range: Range<Int>) -> String {
        String(characters[range]).lowercased()
    }

    /// How one past question would finish what you have typed, or nil if it is
    /// not the question you are writing.
    static func match(typed: [Character],
                      phrase: [Character]) -> (wildcards: Int, matched: Int, tail: String)? {
        let typedTokens = tokens(in: typed)
        let phraseTokens = tokens(in: phrase)
        guard !typedTokens.isEmpty, phraseTokens.count >= typedTokens.count else { return nil }
        // A trailing space means the word is finished and the next one has not
        // been started; without one, the last word is still being typed.
        let partial = !(typed.last?.isWhitespace ?? true)

        var wildcards = 0
        var matched = 0
        var start: Int?
        for (index, token) in typedTokens.enumerated() {
            let other = phraseTokens[index]
            let last = index == typedTokens.count - 1
            let mine = word(typed, token.core)
            let theirs = word(phrase, other.core)
            if last && partial {
                if theirs.hasPrefix(mine), theirs.count > mine.count,
                   other.core.lowerBound + mine.count <= other.core.upperBound {
                    // Part-way through the same word: finish the word.
                    start = other.core.lowerBound + mine.count
                    matched += 1
                } else if theirs == mine {
                    start = other.core.upperBound
                    matched += 1
                } else {
                    // A different word in the same place. The offer picks up
                    // after it, which is how the shape survives the swap.
                    guard mine.count >= minimumPartial else { return nil }
                    wildcards += 1
                    start = other.core.upperBound
                }
            } else {
                if mine == theirs { matched += 1 } else { wildcards += 1 }
                if last { start = other.core.upperBound }
            }
            if wildcards > maximumWildcards { return nil }
        }
        guard matched >= minimumMatched, var from = start else { return nil }

        // Punctuation you have already typed is not offered back to you. Type
        // the "?" after "What does AST do" yourself and the offer starts at the
        // space, not at a second question mark.
        let lastTyped = typedTokens[typedTokens.count - 1]
        let lastPhrase = phraseTokens[typedTokens.count - 1]
        if from == lastPhrase.core.upperBound {
            var mineIndex = lastTyped.core.upperBound
            while mineIndex < lastTyped.chunk.upperBound, from < phrase.count,
                  typed[mineIndex] == phrase[from] {
                mineIndex += 1
                from += 1
            }
        }
        guard from <= phrase.count else { return nil }
        let tail = String(phrase[from...])
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (wildcards, matched, tail)
    }

    /// The best offer across every past question, or nil.
    ///
    /// Fewest words swapped wins, then the most words lined up. Where the
    /// front-runners disagree the offer is cut back to where they agree, the
    /// same rule the stock phrases follow: a suggestion you have not chosen
    /// between yet is one you would have to read and reject.
    static func completion(for typed: String, in phrases: [String]) -> String? {
        let characters = Array(typed)
        guard characters.count >= minimumTyped, !phrases.isEmpty else { return nil }

        var best: [(wildcards: Int, matched: Int, tail: String)] = []
        for phrase in phrases {
            guard let found = match(typed: characters, phrase: Array(phrase)) else { continue }
            guard let top = best.first else { best = [found]; continue }
            if (found.wildcards, -found.matched) < (top.wildcards, -top.matched) {
                best = [found]
            } else if (found.wildcards, -found.matched) == (top.wildcards, -top.matched) {
                best.append(found)
            }
        }
        guard let first = best.first else { return nil }
        var shared = first.tail
        for candidate in best.dropFirst() where candidate.tail != shared {
            shared = String(zip(shared, candidate.tail).prefix { $0.0 == $0.1 }.map(\.0))
            if shared.count < minimumTail { return nil }
        }
        return shared.count >= minimumTail ? shared : nil
    }
}
