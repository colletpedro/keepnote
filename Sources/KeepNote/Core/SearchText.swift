import Foundation

/// Title and tag search, in memory, by the rules the on-disk FTS5 index used
/// (`unicode61 remove_diacritics 2`, every term quoted with a prefix wildcard):
///
/// - text splits into tokens at anything that is not a letter or a digit, and
///   tokens compare without case or accents;
/// - each whitespace-separated term of the query is a phrase of its own
///   tokens, the last one a prefix ("release-no" matches "Release notes", "rel-no" does not);
/// - every term has to match, each within the title or within the tags.
enum SearchText {
    /// The query's terms, already tokenised. A term with no letters or digits
    /// in it can match nothing.
    static func terms(_ query: String) -> [[String]] {
        query.split(whereSeparator: { $0.isWhitespace }).map { tokens(String($0)) }
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    static func matches(query: String, title: String, tags: [String]) -> Bool {
        matches(terms: terms(query), title: title, tags: tags)
    }

    static func matches(terms: [[String]], title: String, tags: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let titleTokens = tokens(title)
        let tagTokens = tokens(tags.joined(separator: " "))
        return terms.allSatisfy { term in
            contains(phrase: term, in: titleTokens) || contains(phrase: term, in: tagTokens)
        }
    }

    private static func contains(phrase: [String], in tokens: [String]) -> Bool {
        guard let last = phrase.last, tokens.count >= phrase.count else { return false }
        let head = phrase.dropLast()
        for start in 0...(tokens.count - phrase.count) {
            let window = tokens[start..<(start + phrase.count)]
            if zip(head, window).allSatisfy(==), window.last?.hasPrefix(last) == true {
                return true
            }
        }
        return false
    }
}
