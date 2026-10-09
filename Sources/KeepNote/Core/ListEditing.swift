import Foundation

/// The list and quote behaviour of the editor, as pure functions from
/// `TextEdit` to `TextEdit`. A function returns `nil` when the key should keep
/// its ordinary meaning, so the view can fall through to AppKit.
enum ListEditing {
    /// `- `, `* `, `+ `, `1. `, `1) `, `1: `, with an optional `[ ]`/`[x]`.
    /// Groups: 1 leading whitespace, 2 marker, 3 spacing, 4 checkbox (with its
    /// trailing space), 5 the checkbox's state character.
    static let itemRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.):])([ \t]+)(\[([ xX])\][ \t]+)?"#)
    static let quoteRegex = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(?:>[ \t]?)+"#)

    struct Item {
        var leading: String
        var marker: String
        var spacing: String
        var box: String?
        /// Length of everything before the item's text.
        var prefixLength: Int

        var isOrdered: Bool { marker.first?.isNumber == true }
        var number: Int? { isOrdered ? Int(marker.dropLast()) : nil }
        var delimiter: Character? { isOrdered ? marker.last : nil }
    }

    static func item(in line: String) -> Item? {
        let ns = line as NSString
        guard let m = itemRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Item(
            leading: ns.substring(with: m.range(at: 1)),
            marker: ns.substring(with: m.range(at: 2)),
            spacing: ns.substring(with: m.range(at: 3)),
            box: m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : nil,
            prefixLength: m.range.length
        )
    }

    /// Return: continues a list or quote; Return on an empty item ends it.
    static func newline(_ edit: TextEdit) -> TextEdit? {
        guard edit.selection.length == 0 else { return nil }
        let ranges = TextLines.ranges(in: edit.nsText)
        let strings = ranges.map { edit.nsText.substring(with: $0) }
        let index = TextLines.index(of: edit.selection.location, in: ranges)
        guard !TextLines.fenced(strings)[index] else { return nil }

        let range = ranges[index]
        let line = strings[index]
        let offset = edit.selection.location - range.location
        let length = (line as NSString).length

        if let item = item(in: line), offset >= item.prefixLength {
            if item.prefixLength == length {
                // An empty item steps back out of a nested list first, and
                // only at the top level ends the list.
                if level(ofLeading: item.leading) > 0 { return indent(edit, outdent: true) }
                return renumber(edit.applying([Replacement(range: range, string: "")]))
            }
            var next = item.marker
            if let number = item.number, let delimiter = item.delimiter { next = "\(number + 1)\(delimiter)" }
            let box = item.box != nil ? "[ ] " : ""
            return renumber(edit.applying([Replacement(range: edit.selection, string: "\n" + item.leading + next + item.spacing + box)]))
        }

        if let m = quoteRegex.firstMatch(in: line, range: NSRange(location: 0, length: length)), offset >= m.range.length {
            if m.range.length == length {
                return edit.applying([Replacement(range: range, string: "")])
            }
            let prefix = (line as NSString).substring(with: m.range)
            return edit.applying([Replacement(range: edit.selection, string: "\n" + prefix)])
        }
        return nil
    }

    // MARK: - Indentation

    /// One nesting level. Four spaces is what every markdown renderer reads as
    /// "nested", including under `1. `, whose text starts three columns in.
    static let indentUnit = "    "

    /// How deep a list item's leading whitespace is. A tab is a level; spaces
    /// count four to a level, and a partial level counts as a whole one.
    static func level(ofLeading leading: String) -> Int {
        var columns = 0
        for ch in leading { columns += ch == "\t" ? 4 : 1 }
        return (columns + 3) / 4
    }

    /// Tab / Shift-Tab: moves every list item the selection touches one level
    /// in or out, wherever the caret is inside the item. `nil` when no touched
    /// line is a list item, so Tab keeps its ordinary meaning outside lists.
    static func indent(_ edit: TextEdit, outdent: Bool) -> TextEdit? {
        let ranges = TextLines.ranges(in: edit.nsText)
        let strings = ranges.map { edit.nsText.substring(with: $0) }
        let fenced = TextLines.fenced(strings)

        var changes: [Replacement] = []
        var foundItem = false
        for index in TextLines.indexes(of: edit.selection, in: ranges) where !fenced[index] {
            guard let item = item(in: strings[index]) else { continue }
            foundItem = true
            let start = ranges[index].location
            let leading = item.leading as NSString
            if outdent {
                guard leading.length > 0 else { continue }
                var remove = 0
                if leading.character(at: leading.length - 1) == 9 {
                    remove = 1
                } else {
                    while remove < 4, remove < leading.length, leading.character(at: leading.length - 1 - remove) == 32 { remove += 1 }
                }
                changes.append(Replacement(range: NSRange(location: start + leading.length - remove, length: remove), string: ""))
            } else {
                changes.append(Replacement(range: NSRange(location: start, length: 0),
                                           string: item.leading.contains("\t") ? "\t" : indentUnit))
            }
        }
        guard foundItem else { return nil }
        return renumber(edit.applying(changes))
    }

    // MARK: - Bullets

    /// The shape drawn for a bullet at a nesting level: • then ◦ then ▪, and
    /// around again below that.
    enum BulletKind: Equatable {
        case disc, ring, square

        var glyph: Character {
            switch self {
            case .disc: return "\u{2022}"
            case .ring: return "\u{25E6}"
            case .square: return "\u{25AA}"
            }
        }
    }

    static func bulletKind(level: Int) -> BulletKind {
        [BulletKind.disc, .ring, .square][max(0, level) % 3]
    }

    // MARK: - Numbering

    /// Renumbers the numbered items of every list block that touches `touching`
    /// (or of the whole text when it is `nil`). A block is a run of consecutive
    /// list lines outside code fences.
    ///
    /// Within a block, items at one level form a run that counts up from the
    /// number its first item already has. A deeper level restarts at 1 under
    /// each parent; a bullet at the same level, or a shallower item, ends the
    /// run. Each item keeps its own delimiter (`.`, `)` or `:`).
    static func renumber(_ edit: TextEdit, touching: NSRange? = nil) -> TextEdit {
        let ranges = TextLines.ranges(in: edit.nsText)
        let strings = ranges.map { edit.nsText.substring(with: $0) }
        let fenced = TextLines.fenced(strings)
        let items: [Item?] = strings.enumerated().map { fenced[$0.offset] ? nil : item(in: $0.element) }

        var window = 0...(ranges.count - 1)
        if let touching {
            let first = TextLines.index(of: touching.location, in: ranges)
            let last = TextLines.index(of: NSMaxRange(touching), in: ranges)
            window = max(0, first - 1)...min(ranges.count - 1, last + 1)
        }

        var changes: [Replacement] = []
        var index = 0
        while index < items.count {
            guard items[index] != nil else { index += 1; continue }
            var end = index
            while end + 1 < items.count, items[end + 1] != nil { end += 1 }
            if end >= window.lowerBound, index <= window.upperBound {
                changes += renumber(block: index...end, items: items, ranges: ranges)
            }
            index = end + 1
        }
        return changes.isEmpty ? edit : edit.applying(changes)
    }

    private static func renumber(block: ClosedRange<Int>, items: [Item?], ranges: [NSRange]) -> [Replacement] {
        var changes: [Replacement] = []
        var next: [Int: Int] = [:]          // level -> number the run counts up to next
        var shallowest = Int.max            // shallowest level seen so far in the block

        for line in block {
            guard let item = items[line] else { continue }
            let level = level(ofLeading: item.leading)
            for deeper in next.keys where deeper > level { next[deeper] = nil }

            if let number = item.number, let delimiter = item.delimiter {
                let wanted: Int
                if let continuing = next[level] {
                    wanted = continuing
                } else if shallowest < level {
                    wanted = 1
                } else {
                    wanted = number
                }
                next[level] = wanted + 1
                if wanted != number {
                    let start = ranges[line].location + (item.leading as NSString).length
                    changes.append(Replacement(
                        range: NSRange(location: start, length: (item.marker as NSString).length),
                        string: "\(wanted)\(delimiter)"
                    ))
                }
            } else {
                next[level] = nil
            }
            shallowest = min(shallowest, level)
        }
        return changes
    }
}
