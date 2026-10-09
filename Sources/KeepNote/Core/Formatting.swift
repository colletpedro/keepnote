import Foundation

/// Inline formatting and block toggles for the note body, as pure functions
/// from `TextEdit` to `TextEdit` (see `ListEditing` for the list keys).
enum Formatting {
    // MARK: - Wrapping marks

    /// An inline mark: what is written around text, plus other spellings of
    /// the same thing that are recognised (and removed) but never written.
    struct Mark {
        let token: String
        let alternates: [String]

        static let bold = Mark(token: "**", alternates: ["__"])
        static let italic = Mark(token: "*", alternates: ["_"])
        static let strike = Mark(token: "~~", alternates: [])
        static let highlight = Mark(token: "==", alternates: [])
        static let code = Mark(token: "`", alternates: [])

        var spellings: [String] { [token] + alternates }
    }

    /// A run of `count` mark characters on each side means the mark is on when
    /// a one-character mark (`*`) sees an odd run — `**x**` is bold, not
    /// italic, and `***x***` is both — or a two-character mark sees two or more.
    private static func isOn(run count: Int, token: String) -> Bool {
        token.count == 1 ? count % 2 == 1 : count >= token.count
    }

    private enum Operation {
        case wrap
        case unwrapInside(Int)
        case unwrapAround(Int)
    }

    /// ⌘B / ⌘I / ⇧⌘X. A selection is wrapped, or unwrapped if it already is
    /// (whether the selection includes the marks or sits just inside them).
    /// With no selection the pair is inserted and the caret goes between; with
    /// the caret already between a pair, the pair is removed. A selection over
    /// several lines is wrapped line by line, since a mark never spans lines.
    static func toggle(_ edit: TextEdit, _ mark: Mark) -> TextEdit {
        let text = edit.nsText
        let lines = TextLines.ranges(in: text)
        let strings = lines.map { text.substring(with: $0) }
        let fenced = TextLines.fenced(strings)

        if edit.selection.length == 0 {
            let index = TextLines.index(of: edit.selection.location, in: lines)
            guard !fenced[index] else { return edit }
            return toggleAtCaret(edit, mark, line: lines[index])
        }

        // The pieces of text to mark: each line's share of the selection, minus
        // surrounding whitespace and, at a line's start, its list/quote/heading
        // prefix.
        var segments: [NSRange] = []
        for index in TextLines.indexes(of: edit.selection, in: lines) where !fenced[index] {
            let line = lines[index]
            var start = max(edit.selection.location, line.location)
            var end = min(NSMaxRange(edit.selection), NSMaxRange(line))
            if start == line.location {
                start += blockPrefixLength(of: strings[index], limit: end - line.location)
            }
            while start < end, isSpace(text.character(at: start)) { start += 1 }
            while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
            if end > start { segments.append(NSRange(location: start, length: end - start)) }
        }
        guard !segments.isEmpty else { return edit }

        let operations = segments.map { operation(for: $0, in: text, lineOf: lines, mark) }
        let allOn = operations.allSatisfy { if case .wrap = $0 { return false } else { return true } }

        var changes: [Replacement] = []
        var shift = 0
        var innerStart = 0
        var innerEnd = 0
        for (offset, segment) in segments.enumerated() {
            let start = segment.location
            let end = NSMaxRange(segment)
            var newStart = start
            var newLength = segment.length
            var net = 0
            switch operations[offset] {
            case .wrap:
                let open = mark.token
                changes.append(Replacement(range: NSRange(location: start, length: 0), string: open))
                changes.append(Replacement(range: NSRange(location: end, length: 0), string: open))
                newStart += open.utf16.count
                net = 2 * open.utf16.count
            case .unwrapInside(let n):
                guard allOn else { break }
                changes.append(Replacement(range: NSRange(location: start, length: n), string: ""))
                changes.append(Replacement(range: NSRange(location: end - n, length: n), string: ""))
                newLength -= 2 * n
                net = -2 * n
            case .unwrapAround(let n):
                guard allOn else { break }
                changes.append(Replacement(range: NSRange(location: start - n, length: n), string: ""))
                changes.append(Replacement(range: NSRange(location: end, length: n), string: ""))
                newStart -= n
                net = -2 * n
            }
            if offset == 0 { innerStart = newStart + shift }
            innerEnd = newStart + newLength + shift
            shift += net
        }

        var result = edit.applying(changes)
        result.selection = NSRange(location: innerStart, length: innerEnd - innerStart)
        return result
    }

    private static func operation(for segment: NSRange, in text: NSString, lineOf lines: [NSRange], _ mark: Mark) -> Operation {
        let line = lines[TextLines.index(of: segment.location, in: lines)]
        let selected = text.substring(with: segment)
        let before = text.substring(with: NSRange(location: line.location, length: segment.location - line.location))
        let after = text.substring(with: NSRange(location: NSMaxRange(segment), length: NSMaxRange(line) - NSMaxRange(segment)))

        for token in mark.spellings {
            guard let c = token.first else { continue }
            // Marks written inside the selection.
            let lead = selected.prefix { $0 == c }.count
            let trail = selected.reversed().prefix { $0 == c }.count
            if lead < selected.count, isOn(run: min(lead, trail), token: token) {
                return .unwrapInside(token.count)
            }
            // Marks written just outside it.
            let outsideBefore = before.reversed().prefix { $0 == c }.count
            let outsideAfter = after.prefix { $0 == c }.count
            if isOn(run: min(outsideBefore, outsideAfter), token: token) {
                return .unwrapAround(token.count)
            }
        }
        return .wrap
    }

    private static func toggleAtCaret(_ edit: TextEdit, _ mark: Mark, line: NSRange) -> TextEdit {
        let text = edit.nsText
        let caret = edit.selection.location
        let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let after = text.substring(with: NSRange(location: caret, length: NSMaxRange(line) - caret))

        for token in mark.spellings {
            guard let c = token.first else { continue }
            let runBefore = before.reversed().prefix { $0 == c }.count
            let runAfter = after.prefix { $0 == c }.count
            if isOn(run: min(runBefore, runAfter), token: token) {
                let n = token.count
                var result = edit.applying([
                    Replacement(range: NSRange(location: caret - n, length: n), string: ""),
                    Replacement(range: NSRange(location: caret, length: n), string: ""),
                ])
                result.selection = NSRange(location: caret - n, length: 0)
                return result
            }
        }
        let pair = mark.token + mark.token
        var result = edit.applying([Replacement(range: edit.selection, string: pair)])
        result.selection = NSRange(location: caret + mark.token.utf16.count, length: 0)
        return result
    }

    static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    private static let blockPrefixes = [
        ListEditing.itemRegex,
        ListEditing.quoteRegex,
        try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#),
    ]

    /// How much of a line is block syntax (`- `, `1. [ ] `, `> `, `## `), never
    /// more than `limit` — the part of the line the selection actually covers.
    private static func blockPrefixLength(of line: String, limit: Int) -> Int {
        let range = NSRange(location: 0, length: (line as NSString).length)
        for regex in blockPrefixes {
            if let m = regex.firstMatch(in: line, range: range) { return min(m.range.length, limit) }
        }
        return 0
    }

    // MARK: - Links

    private static let urlRegex = try! NSRegularExpression(pattern: #"^(?:https?://|mailto:)\S+$"#, options: [.caseInsensitive])

    /// The clipboard's text if it is a single http(s) or mailto URL.
    static func url(from clipboard: String?) -> String? {
        guard let trimmed = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return urlRegex.firstMatch(in: trimmed, range: range) != nil ? trimmed : nil
    }

    /// A URL as it is written inside `(...)`: parentheses would end the link.
    static func destination(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// ⌘K: turns the selection into `[selection](url)` with the caret in the
    /// url — which is the clipboard's URL when it holds one, empty otherwise.
    /// With no selection it inserts `[](url)` and the caret goes in the text.
    /// `nil` across several lines or in a code fence, where a link means nothing.
    static func link(_ edit: TextEdit, clipboard: String?) -> TextEdit? {
        let url = destination(url(from: clipboard) ?? "")
        guard let target = linkTarget(edit) else { return nil }
        if target.length == 0 {
            var result = edit.applying([Replacement(range: target, string: "[](\(url))")])
            result.selection = NSRange(location: target.location + 1, length: 0)
            return result
        }
        var result = edit.applying([
            Replacement(range: NSRange(location: target.location, length: 0), string: "["),
            Replacement(range: NSRange(location: NSMaxRange(target), length: 0), string: "](\(url))"),
        ])
        result.selection = NSRange(location: NSMaxRange(target) + 3 + (url as NSString).length, length: 0)
        return result
    }

    /// Pasting a URL over selected text makes it `[selection](url)`, caret
    /// after the link. `nil` when the paste should be an ordinary paste: no
    /// selection, several lines, a code fence, text that is not a URL, or a
    /// selection that is itself a URL (that is a replacement, not a link).
    static func pasteURL(_ edit: TextEdit, pasted: String) -> TextEdit? {
        guard edit.selection.length > 0, let url = url(from: pasted).map(destination),
              let target = linkTarget(edit), target.length > 0,
              Formatting.url(from: edit.nsText.substring(with: target)) == nil else { return nil }
        var result = edit.applying([
            Replacement(range: NSRange(location: target.location, length: 0), string: "["),
            Replacement(range: NSRange(location: NSMaxRange(target), length: 0), string: "](\(url))"),
        ])
        result.selection = NSRange(location: NSMaxRange(target) + 4 + (url as NSString).length, length: 0)
        return result
    }

    /// The selection without surrounding blanks, if a link can be made there.
    private static func linkTarget(_ edit: TextEdit) -> NSRange? {
        let text = edit.nsText
        let lines = TextLines.ranges(in: text)
        let strings = lines.map { text.substring(with: $0) }
        let first = TextLines.index(of: edit.selection.location, in: lines)
        let last = TextLines.index(of: NSMaxRange(edit.selection), in: lines)
        guard first == last, !TextLines.fenced(strings)[first] else { return nil }

        var start = edit.selection.location
        var end = NSMaxRange(edit.selection)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        // All blanks counts as no selection: the link goes at the caret.
        return NSRange(location: start, length: end - start)
    }

    // MARK: - List toggles

    enum ListKind: Equatable {
        case bullet, numbered, checklist

        /// What a line of this kind starts with, after any indentation.
        var marker: String {
            switch self {
            case .bullet: return "- "
            case .numbered: return "1. "
            case .checklist: return "- [ ] "
            }
        }

        init(_ item: ListEditing.Item) {
            self = item.isOrdered ? .numbered : (item.box != nil ? .checklist : .bullet)
        }
    }

    /// ⇧⌘7 / ⇧⌘9 / ⇧⌘L: puts every line of the selection in a list of `kind`,
    /// or takes them all out of it when they already are. Lines in another kind
    /// of list switch over and keep their indentation; blank lines are skipped
    /// unless the caret is on one. Numbers are then counted from the list the
    /// lines join, or from 1.
    static func toggleList(_ edit: TextEdit, _ kind: ListKind) -> TextEdit {
        let text = edit.nsText
        let lines = TextLines.ranges(in: text)
        let strings = lines.map { text.substring(with: $0) }
        let fenced = TextLines.fenced(strings)
        let indexes = TextLines.indexes(of: edit.selection, in: lines)
        let single = indexes.count == 1

        let targets = indexes.filter { index in
            guard !fenced[index] else { return false }
            return single || !strings[index].allSatisfy { $0 == " " || $0 == "\t" }
        }
        guard !targets.isEmpty else { return edit }

        let items = targets.map { ListEditing.item(in: strings[$0]) }
        let allInKind = items.allSatisfy { $0.map(ListKind.init) == kind }

        var changes: [Replacement] = []
        for (index, item) in zip(targets, items) {
            let start = lines[index].location
            if allInKind, let item {
                // Out of the list entirely, indentation included.
                changes.append(Replacement(range: NSRange(location: start, length: item.prefixLength), string: ""))
            } else if let item {
                guard ListKind(item) != kind else { continue }
                let leading = (item.leading as NSString).length
                changes.append(Replacement(
                    range: NSRange(location: start + leading, length: item.prefixLength - leading),
                    string: kind.marker
                ))
            } else {
                let line = strings[index] as NSString
                var indent = 0
                while indent < line.length, isSpace(line.character(at: indent)) { indent += 1 }
                changes.append(Replacement(range: NSRange(location: start + indent, length: 0), string: kind.marker))
            }
        }
        let result = edit.applying(changes)
        return ListEditing.renumber(result, touching: result.selection)
    }
}
