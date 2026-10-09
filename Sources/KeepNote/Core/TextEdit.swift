import Foundation

/// The text of a note body plus where the caret or selection sits. This is the
/// whole input and output of the editing logic in `ListEditing` and
/// `Formatting`: no AppKit, so it can be compiled and tested on its own
/// (`Scripts/test.sh`). Ranges are UTF-16, like `NSRange` everywhere else.
struct TextEdit: Equatable {
    var text: String
    var selection: NSRange

    init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }

    init(text: String, caret: Int) {
        self.init(text: text, selection: NSRange(location: caret, length: 0))
    }

    var nsText: NSString { text as NSString }
}

/// One change, in the coordinates of the text *before* any change is made.
struct Replacement: Equatable {
    var range: NSRange
    var string: String
}

extension TextEdit {
    /// Applies non-overlapping replacements and carries the selection along:
    /// a position before a change stays, one at or after its end moves by the
    /// change's size, one inside it lands at the end of the new text (clamped).
    func applying(_ replacements: [Replacement]) -> TextEdit {
        let ordered = replacements.sorted { $0.range.location < $1.range.location }
        var result = ""
        var cursor = 0
        let source = nsText
        for change in ordered {
            result += source.substring(with: NSRange(location: cursor, length: change.range.location - cursor))
            result += change.string
            cursor = NSMaxRange(change.range)
        }
        result += source.substring(from: cursor)

        func map(_ position: Int) -> Int {
            var shift = 0
            for change in ordered {
                let start = change.range.location
                let end = NSMaxRange(change.range)
                let newLength = (change.string as NSString).length
                if position >= end {
                    shift += newLength - change.range.length
                } else if position > start {
                    return start + shift + min(position - start, newLength)
                } else {
                    break
                }
            }
            return position + shift
        }

        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return TextEdit(text: result, selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// The smallest single replacement that turns `text` into `other`'s text,
    /// so the editor can apply a result as one undoable edit that leaves the
    /// rest of the note (and its styling) alone.
    func minimalChange(to other: TextEdit) -> Replacement {
        let old = nsText
        let new = other.nsText
        let limit = min(old.length, new.length)

        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        // Never cut between the two halves of a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }

        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }

        return Replacement(
            range: NSRange(location: prefix, length: old.length - prefix - suffix),
            string: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        )
    }
}

/// Line-level view of a body.
enum TextLines {
    /// The content range of every line, newline excluded. Text that ends in a
    /// newline has a final empty line, which is where the caret sits after it.
    static func ranges(in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        var index = 0
        while index < text.length {
            if text.character(at: index) == 10 {
                result.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        result.append(NSRange(location: start, length: text.length - start))
        return result
    }

    /// The line a caret at `location` is on (a caret right after a newline is
    /// on the next line).
    static func index(of location: Int, in lines: [NSRange]) -> Int {
        for (i, range) in lines.enumerated() where location <= NSMaxRange(range) { return i }
        return max(0, lines.count - 1)
    }

    /// The lines a selection touches. A selection that ends right after a
    /// newline does not count the empty line it stops at, unless it is empty.
    static func indexes(of selection: NSRange, in lines: [NSRange]) -> ClosedRange<Int> {
        let first = index(of: selection.location, in: lines)
        var last = index(of: NSMaxRange(selection), in: lines)
        if selection.length > 0, last > first, lines[last].location == NSMaxRange(selection) { last -= 1 }
        return first...last
    }

    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// The fenced code blocks, as line indexes of their opening and closing
    /// fence. An unclosed fence runs to the end of the note, as it renders, and
    /// has no `close`.
    static func fenceBlocks(_ lines: [String]) -> [(open: Int, close: Int?, last: Int)] {
        var result: [(open: Int, close: Int?, last: Int)] = []
        var index = 0
        while index < lines.count {
            if isFence(lines[index]) {
                var close = index + 1
                while close < lines.count, !isFence(lines[close]) { close += 1 }
                let last = min(close, lines.count - 1)
                result.append((index, close < lines.count ? close : nil, last))
                index = last + 1
            } else {
                index += 1
            }
        }
        return result
    }

    /// Which lines are inside a fenced code block, fences included.
    static func fenced(_ lines: [String]) -> [Bool] {
        var result = [Bool](repeating: false, count: lines.count)
        for block in fenceBlocks(lines) { for k in block.open...block.last { result[k] = true } }
        return result
    }
}
