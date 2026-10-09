import Foundation

/// Block-level commands of the editor — headings, quotes, code blocks and the
/// things inserted whole (table, divider, date) — as pure functions from
/// `TextEdit` to `TextEdit`. Inline marks and list toggles live in `Formatting`.
enum BlockEditing {
    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let quoteLevelRegex = try! NSRegularExpression(pattern: #"^[ \t]{0,3}>[ \t]?"#)

    private struct Context {
        let edit: TextEdit
        let lines: [NSRange]
        let strings: [String]
        let fenced: [Bool]
        let indexes: ClosedRange<Int>

        init(_ edit: TextEdit) {
            self.edit = edit
            lines = TextLines.ranges(in: edit.nsText)
            strings = lines.map { edit.nsText.substring(with: $0) }
            fenced = TextLines.fenced(strings)
            indexes = TextLines.indexes(of: edit.selection, in: lines)
        }

        /// The selected lines a line-prefix command applies to: not in a code
        /// fence, and not blank unless that is the only line (the caret).
        func targets(where include: (Int) -> Bool = { _ in true }) -> [Int] {
            let single = indexes.count == 1
            return indexes.filter { index in
                guard !fenced[index], include(index) else { return false }
                return single || !strings[index].allSatisfy { $0 == " " || $0 == "\t" }
            }
        }

        func firstMatch(_ regex: NSRegularExpression, _ index: Int) -> NSTextCheckingResult? {
            regex.firstMatch(in: strings[index], range: NSRange(location: 0, length: (strings[index] as NSString).length))
        }
    }

    // MARK: - Heading

    /// H1-H3 (any 1...6): sets the heading level of the selected lines, or
    /// removes the heading when they all already have exactly that level. List
    /// items are left alone — `# - a` is not what anyone means.
    static func heading(_ edit: TextEdit, level: Int) -> TextEdit {
        let level = min(max(level, 1), 6)
        let c = Context(edit)
        let targets = c.targets { ListEditing.item(in: c.strings[$0]) == nil }
        guard !targets.isEmpty else { return edit }

        let existing = targets.map { c.firstMatch(headingRegex, $0) }
        let allAtLevel = existing.allSatisfy { $0?.range(at: 1).length == level }

        var changes: [Replacement] = []
        for (index, match) in zip(targets, existing) {
            let start = c.lines[index].location
            if allAtLevel, let match {
                changes.append(Replacement(range: NSRange(location: start, length: match.range.length), string: ""))
            } else {
                let prefix = String(repeating: "#", count: level) + " "
                changes.append(Replacement(range: NSRange(location: start, length: match?.range.length ?? 0), string: prefix))
            }
        }
        return edit.applying(changes)
    }

    // MARK: - Quote

    /// Puts `> ` on the selected lines, or takes one level off when they are
    /// all quoted already.
    static func quote(_ edit: TextEdit) -> TextEdit {
        let c = Context(edit)
        let targets = c.targets()
        guard !targets.isEmpty else { return edit }

        let existing = targets.map { c.firstMatch(quoteLevelRegex, $0) }
        let allQuoted = existing.allSatisfy { $0 != nil }

        var changes: [Replacement] = []
        for (index, match) in zip(targets, existing) {
            let start = c.lines[index].location
            if allQuoted, let match {
                changes.append(Replacement(range: NSRange(location: start, length: match.range.length), string: ""))
            } else if match == nil {
                changes.append(Replacement(range: NSRange(location: start, length: 0), string: "> "))
            }
        }
        return edit.applying(changes)
    }

    // MARK: - Code block

    /// Wraps the selected lines (the caret's line when nothing is selected) in
    /// a fence; on a blank line it opens an empty block with the caret inside.
    /// Over lines that are inside a fenced block it removes that block's two
    /// fence lines instead, keeping the code.
    static func codeBlock(_ edit: TextEdit) -> TextEdit {
        let c = Context(edit)
        let blocks = TextLines.fenceBlocks(c.strings)

        if c.indexes.contains(where: { c.fenced[$0] }) {
            guard let block = blocks.first(where: { $0.open <= c.indexes.lowerBound && c.indexes.upperBound <= $0.last })
            else { return edit }
            var changes = [fenceRemoval(block.open, c)]
            if let close = block.close { changes.append(fenceRemoval(close, c)) }
            return edit.applying(changes)
        }

        let first = c.lines[c.indexes.lowerBound]
        let last = c.lines[c.indexes.upperBound]
        if edit.selection.length == 0, first.length == 0 {
            var result = edit.applying([Replacement(range: first, string: "```\n\n```")])
            result.selection = NSRange(location: first.location + 4, length: 0)
            return result
        }
        var result = edit.applying([
            Replacement(range: NSRange(location: first.location, length: 0), string: "```\n"),
            Replacement(range: NSRange(location: NSMaxRange(last), length: 0), string: "\n```"),
        ])
        let shifted = NSRange(location: edit.selection.location + 4, length: edit.selection.length)
        result.selection = shifted
        return result
    }

    /// Deletes a fence line together with one line break.
    private static func fenceRemoval(_ index: Int, _ c: Context) -> Replacement {
        let line = c.lines[index]
        if index + 1 < c.lines.count { return Replacement(range: NSRange(location: line.location, length: line.length + 1), string: "") }
        if line.location > 0 { return Replacement(range: NSRange(location: line.location - 1, length: line.length + 1), string: "") }
        return Replacement(range: line, string: "")
    }

    // MARK: - Inserting whole blocks

    static let tableTemplate = ["| Column 1 | Column 2 |", "| --- | --- |", "|  |  |"]

    /// A 2 x 2 pipe table (header and one row), with the first header cell
    /// selected so typing names it.
    static func insertTable(_ edit: TextEdit) -> TextEdit {
        insertBlock(edit, lines: tableTemplate, select: NSRange(location: 2, length: 8))
    }

    /// A horizontal rule, with the caret on the line after it.
    static func insertDivider(_ edit: TextEdit) -> TextEdit {
        insertBlock(edit, lines: ["---"], select: nil)
    }

    /// Today's date in the system's short format for the current locale
    /// (`06/10/2026`, `10/6/26`). It replaces the selection, like typing it would.
    static func insertDate(
        _ edit: TextEdit, date: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> TextEdit {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        let text = formatter.string(from: date)
        var result = edit.applying([Replacement(range: edit.selection, string: text)])
        result.selection = NSRange(location: edit.selection.location + (text as NSString).length, length: 0)
        return result
    }

    /// Puts `lines` in the text as a block of their own at the end of the
    /// selection: a blank line on either side when it lands next to text, so
    /// `---` after a paragraph is a rule and not a heading underline, and a
    /// table does not swallow the line below it. `select` is a range inside
    /// the block's first line; with `nil` the caret goes after the block.
    private static func insertBlock(_ edit: TextEdit, lines block: [String], select: NSRange?) -> TextEdit {
        let text = edit.nsText
        let all = TextLines.ranges(in: text)
        let position = NSMaxRange(edit.selection)
        let index = TextLines.index(of: position, in: all)
        let line = all[index]

        let before = text.substring(with: NSRange(location: line.location, length: position - line.location))
        let after = text.substring(with: NSRange(location: position, length: NSMaxRange(line) - position))
        func isBlank(_ i: Int) -> Bool { text.substring(with: all[i]).allSatisfy { $0 == " " || $0 == "\t" } }

        let lead: String
        if !before.isEmpty { lead = "\n\n" } else if index > 0, !isBlank(index - 1) { lead = "\n" } else { lead = "" }

        let trail: String
        if !after.isEmpty { trail = "\n\n" }
        else if index + 1 >= all.count { trail = "\n" }
        else if isBlank(index + 1) { trail = "" }
        else { trail = "\n" }

        let body = block.joined(separator: "\n")
        var result = edit.applying([Replacement(range: NSRange(location: position, length: 0), string: lead + body + trail)])
        let bodyStart = position + (lead as NSString).length
        if let select {
            result.selection = NSRange(location: bodyStart + select.location, length: select.length)
        } else {
            result.selection = NSRange(location: bodyStart + (body as NSString).length + max((trail as NSString).length, 1), length: 0)
        }
        return result
    }
}
