import Foundation

/// The tags field of an open note: free text such as `#work, ideas` on one
/// side, the normalised tag list the store keeps on the other.
enum TagText {
    /// Lower-cased, `#` stripped, no blanks, no duplicates, first spelling's
    /// position kept. Tags round-trip through a single TEXT column and through
    /// `.hmnote` headers, so every path normalises them the same way.
    static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let clean = tag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .lowercased()
            guard !clean.isEmpty, !clean.contains(",") else { continue }
            if seen.insert(clean).inserted { result.append(clean) }
        }
        return result
    }

    /// The tags a field's text stands for. Tags are separated by blanks or commas.
    static func parse(_ text: String) -> [String] {
        normalize(text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
    }

    /// How tags are written in the field: `#work #ideas`.
    static func format(_ tags: [String]) -> String {
        tags.map { "#\($0)" }.joined(separator: " ")
    }

    /// Whether the field has to be rewritten to show `stored` — only when it
    /// stands for different tags. A field that merely *spells* them differently
    /// (`work, Ideas` for `#work #ideas`) is what the user typed, so it stays.
    static func fieldDiffers(from stored: [String], field: String) -> Bool {
        parse(field) != stored
    }

    // MARK: - Suggestions

    /// A tag and how many notes carry it.
    struct Usage: Equatable {
        var tag: String
        var count: Int
    }

    /// Case- and accent-insensitive form used for every comparison here.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// How many notes use each tag; a note counts once however it is written.
    static func usage(of notes: [[String]]) -> [Usage] {
        var counts: [String: Int] = [:]
        for tags in notes {
            for tag in Set(normalize(tags)) { counts[tag, default: 0] += 1 }
        }
        return counts.map { Usage(tag: $0.key, count: $0.value) }
    }

    /// The text of a token as a tag name: no `#`, no blanks.
    static func name(ofToken token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    /// Up to `limit` existing tags for the token being typed, never one the
    /// note already has. Tags that start with the token come before tags that
    /// merely contain it; within each, the most used first, then alphabetical.
    /// An empty token gets the most used tags.
    static func suggestions(for token: String, usage: [Usage], existing: [String], limit: Int = 6) -> [String] {
        let needle = fold(name(ofToken: token))
        let taken = Set(existing.map(fold))

        var ranked: [(usage: Usage, bucket: Int)] = []
        for entry in usage where !taken.contains(fold(entry.tag)) {
            let folded = fold(entry.tag)
            if needle.isEmpty {
                ranked.append((entry, 0))
            } else if folded.hasPrefix(needle) {
                ranked.append((entry, 0))
            } else if folded.contains(needle) {
                ranked.append((entry, 1))
            }
        }
        ranked.sort { a, b in
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            if a.usage.count != b.usage.count { return a.usage.count > b.usage.count }
            let (fa, fb) = (fold(a.usage.tag), fold(b.usage.tag))
            return fa != fb ? fa < fb : a.usage.tag < b.usage.tag
        }
        return ranked.prefix(max(0, limit)).map(\.usage.tag)
    }

    // MARK: - The token being edited

    /// The word under the caret in the tags field: where it is, and its name
    /// without the `#`. Tags are separated by blanks and commas; a caret
    /// between separators is on an empty token.
    struct Token: Equatable {
        var range: NSRange
        var name: String
    }

    private static func isSeparator(_ unit: unichar) -> Bool {
        unit == 44 || unit == 32 || unit == 9 || unit == 10 || unit == 13
    }

    static func token(in text: String, caret: Int) -> Token {
        let ns = text as NSString
        let caret = min(max(caret, 0), ns.length)
        var start = caret
        var end = caret
        while start > 0, !isSeparator(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, !isSeparator(ns.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        return Token(range: range, name: name(ofToken: ns.substring(with: range)))
    }

    /// The field's text with the token under the caret removed: what the note
    /// already has, apart from the word being typed.
    static func text(_ text: String, without token: Token) -> String {
        (text as NSString).replacingCharacters(in: token.range, with: " ")
    }

    /// Accepting `tag` for the token under the caret: the token becomes
    /// `#tag`, followed by one space, and the caret lands after that space,
    /// ready for the next tag. A space that is already there is reused.
    static func accept(_ tag: String, in text: String, caret: Int) -> (text: String, caret: Int) {
        let ns = text as NSString
        let token = token(in: text, caret: caret)
        let end = NSMaxRange(token.range)
        let replacement = "#" + tag
        let followedBySpace = end < ns.length && {
            let unit = ns.character(at: end)
            return unit == 32 || unit == 9
        }()

        let head = ns.substring(to: token.range.location) + replacement
        if followedBySpace {
            return (head + ns.substring(from: end), (head as NSString).length + 1)
        }
        return (head + " " + ns.substring(from: end), (head as NSString).length + 1)
    }

    /// Whether a note with `tags` is in the list filtered by `filter`. No
    /// filter shows everything; otherwise the note must carry that tag,
    /// ignoring case, accents and a leading `#`.
    static func matches(tags: [String], filter: String?) -> Bool {
        guard let filter else { return true }
        let wanted = fold(name(ofToken: filter))
        guard !wanted.isEmpty else { return true }
        return tags.contains { fold($0) == wanted }
    }

    /// The tag the "Create" row would make from what is typed, or `nil` when
    /// there is nothing to create: no text, or the text already is a tag —
    /// anywhere in the store, or in this note — ignoring case and accents.
    static func createCandidate(for token: String, usage: [Usage], existing: [String]) -> String? {
        guard let tag = normalize([name(ofToken: token)]).first else { return nil }
        let known = Set(usage.map { fold($0.tag) } + existing.map(fold))
        return known.contains(fold(tag)) ? nil : tag
    }

    /// Where the highlight goes after an arrow key: the first row on the way
    /// down from nothing, the last on the way up, and around the ends.
    static func moveSelection(_ current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return delta > 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    /// Which row Return takes when the list opens on `token`: the first, unless
    /// nothing has been typed for this tag yet, where Return should keep
    /// meaning "done" rather than pick the most used tag.
    /// `suggestionCount` counts real suggestions only: a list that offers just
    /// "Create" selects nothing, since Return then should tidy the field, which
    /// leaves the typed word exactly as the Create row would.
    static func initialSelection(token: Token, suggestionCount: Int) -> Int? {
        token.name.isEmpty || suggestionCount == 0 ? nil : 0
    }
}
