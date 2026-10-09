import AppKit

/// A pipe table, laid out once by `MarkdownStyler` and painted by
/// `MarkdownTextView`. The raw `| a | b |` lines stay in the text, hidden, each
/// one given exactly the height of the row drawn in its place.
final class TableLayout: NSObject {
    static let cellPaddingX: CGFloat = 8
    static let cellPaddingY: CGFloat = 5

    /// Header first, then body rows; each cell is already styled.
    let cells: [[NSAttributedString]]
    /// Where each of those rows lives in the text (same order as `cells`).
    let rowRanges: [NSRange]
    let columnWidths: [CGFloat]

    init(cells: [[NSAttributedString]], rowRanges: [NSRange], columnWidths: [CGFloat]) {
        self.cells = cells
        self.rowRanges = rowRanges
        self.columnWidths = columnWidths
    }

    var totalWidth: CGFloat { columnWidths.reduce(0, +) }
}

/// Live-preview styling for a note body written in markdown, the way
/// Obsidian's Live Preview does it.
///
/// The stored text is never touched — the `.md` stays exactly as typed. This
/// only decorates the `NSTextStorage`. Syntax is hidden everywhere except where
/// the caret (or selection) is:
///
/// - inline marks (`**`, `*`, `` ` ``, `~~`, `[[ ]]`, links…) come back only for
///   the one span the caret is in or touching, not the whole line;
/// - line-level marks (`#`, `>`, `---`) come back on the caret's line;
/// - a code block or a table shows its source while the caret is inside it;
/// - bullets, checkboxes and ordered-list numbers are always rendered.
///
/// "Hidden" means a near-zero-size clear font, not a deletion, so copy/paste,
/// find and undo keep working on the real characters. Things a font cannot
/// draw (bullets, checkboxes, quote bars, rules, code fills, tables) are tagged
/// with `decorationKey` / `tableKey` and painted by `MarkdownTextView`.
struct MarkdownStyler: Equatable {
    static let decorationKey = NSAttributedString.Key("KeepNote.decoration")
    static let linkKey = NSAttributedString.Key("KeepNote.link")
    static let tableKey = NSAttributedString.Key("KeepNote.table")

    enum Decoration: String {
        case bullet, checkbox, checkboxDone, quote, rule, codeLine
    }

    static let baseSize: CGFloat = 14
    /// Line height as a multiple of the font *size*: 14 pt text on a 22.4 pt line.
    static let lineSpacing: CGFloat = 1.6
    static let bulletWidth: CGFloat = 16
    static let checkboxWidth: CGFloat = 22
    static let quoteIndent: CGFloat = 14

    private static let tabWidth: CGFloat = 28
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.1)
    private static let headingSizes: [CGFloat] = [22, 18, 15.5, 14, 13, 13]
    private static let tableFontSize: CGFloat = 12.5

    var ink: NSColor
    /// For text and marks on the paper: the note colour's `accent`.
    var accent: NSColor
    /// The spine colour, for the `==highlight==` wash only.
    var highlight: NSColor

    var baseFont: NSFont { NSFont.systemFont(ofSize: Self.baseSize) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: ink, .paragraphStyle: baseParagraph()]
    }

    /// The paragraph style every line starts from.
    private func baseParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        // `lineHeightMultiple` scales the font's own line height (about 1.2 of
        // its size), so the factor is converted to land on 1.6 x the size.
        p.lineHeightMultiple = Self.lineSpacing * Self.baseSize / lineHeight
        return p
    }

    // MARK: - Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a bad one is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    static let list = ListEditing.itemRegex
    static let quote = ListEditing.quoteRegex

    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let rule = regex(#"^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let callout = regex(#"^\[![A-Za-z-]+\][+-]?[ \t]*"#)
    private static let tableSeparator = regex(#"^[ \t]*\|?[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#)

    private static let escape = regex(#"\\([\\`*_{}\[\]()#+\-.!|~>=%])"#)
    private static let comment = regex(#"(%%)(.+?)\1"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let wikilink = regex(#"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)
    private static let link = regex(#"!?\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let bareURL = regex(#"https?://[^\s<>)\]]+"#)
    private static let boldItalic = regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStar = regex(#"(?<![*\w])(\*)(?![\s*])(.+?)(?<![\s*])\1(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![_\w])(_)(?![\s_])(.+?)(?<![\s_])\1(?![_\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)\1"#)
    private static let highlight = regex(#"(==)(?=\S)(.+?)(?<=\S)\1"#)

    // MARK: - Entry point

    /// Restyles the whole body. `selection` is where the caret or selection
    /// is; syntax is revealed only around it. `tableWidth` is the room a table
    /// may take, so wide ones wrap their cells instead of overflowing.
    func apply(to storage: NSTextStorage, selection: NSRange, tableWidth: CGFloat) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        var lines: [(range: NSRange, enclosing: NSRange)] = []
        text.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            lines.append((range, enclosing))
        }
        func string(_ index: Int) -> String {
            let range = lines[index].range
            return range.length > 0 ? text.substring(with: range) : ""
        }

        // Pass 1: which lines belong to a fenced code block or a table.
        enum Role { case text, fence, code, table(Int) }
        var roles = [Role](repeating: .text, count: lines.count)
        var blocks: [NSRange] = []
        var blockOf = [Int?](repeating: nil, count: lines.count)
        var tables: [(rows: [Int], separator: Int)] = []

        func isFence(_ index: Int) -> Bool {
            TextLines.isFence(string(index))
        }
        func blockRange(_ from: Int, _ to: Int) -> NSRange {
            let start = lines[from].range.location
            return NSRange(location: start, length: NSMaxRange(lines[to].range) - start)
        }

        var index = 0
        while index < lines.count {
            if isFence(index) {
                var close = index + 1
                while close < lines.count, !isFence(close) { close += 1 }
                let last = min(close, lines.count - 1)
                for k in index...last {
                    roles[k] = (k == index || (k == close && close < lines.count)) ? .fence : .code
                    blockOf[k] = blocks.count
                }
                blocks.append(blockRange(index, last))
                index = last + 1
                continue
            }

            let line = string(index)
            if line.contains("|"), index + 1 < lines.count, !isFence(index + 1),
               Self.matches(Self.tableSeparator, string(index + 1)), string(index + 1).contains("-") {
                var end = index + 2
                while end < lines.count, !isFence(end), string(end).contains("|") { end += 1 }
                for k in index..<end {
                    roles[k] = .table(tables.count)
                    blockOf[k] = blocks.count
                }
                var rows = Array(index..<end)
                rows.remove(at: 1)
                tables.append((rows, index + 1))
                blocks.append(blockRange(index, end - 1))
                index = end
                continue
            }
            index += 1
        }
        let blockActive = blocks.map { Self.touches(selection, $0) }

        // Pass 2: style every line.
        for (i, line) in lines.enumerated() {
            let active = blockOf[i].map { blockActive[$0] } ?? false
            switch roles[i] {
            case .fence:
                storage.addAttributes(codeAttributes(dim: true), range: line.enclosing)
                if !active { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: line.enclosing) }
            case .code:
                storage.addAttributes(codeAttributes(dim: false), range: line.enclosing)
            case .table(let t):
                // A table is styled once, from its first line.
                guard i == tables[t].rows[0] else { continue }
                styleTable(
                    rows: tables[t].rows, separator: tables[t].separator,
                    lines: lines.map { ($0.range, $0.enclosing) },
                    text: text, active: active, width: tableWidth, in: storage
                )
            case .text:
                guard line.range.length > 0 else { continue }
                styleText(line: line.range, in: storage, text: text, selection: selection)
            }
        }
        storage.endEditing()
    }

    // MARK: - Text lines

    private func styleText(line range: NSRange, in storage: NSTextStorage, text: NSString, selection: NSRange) {
        let line = text.substring(with: range) as NSString
        let lineString = line as String
        let whole = NSRange(location: 0, length: line.length)
        let lineActive = Self.touches(selection, range)

        func abs(_ r: NSRange) -> NSRange {
            NSRange(location: range.location + r.location, length: r.length)
        }

        var contentStart = 0
        var paragraph: NSMutableParagraphStyle?

        if Self.rule.firstMatch(in: lineString, range: whole) != nil {
            if lineActive {
                dim(range, in: storage)
            } else {
                storage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    Self.decorationKey: Decoration.rule.rawValue
                ], range: range)
            }
            return
        }

        if let m = Self.heading.firstMatch(in: lineString, range: whole) {
            let level = m.range(at: 1).length
            storage.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: Self.headingSizes[level - 1], weight: .bold),
                range: range
            )
            mark(abs(m.range), show: lineActive, in: storage)
            if level <= 2 {
                let p = NSMutableParagraphStyle()
                p.paragraphSpacingBefore = 6
                p.lineHeightMultiple = 1.25
                paragraph = p
            }
            contentStart = m.range.length

        } else if let m = Self.quote.firstMatch(in: lineString, range: whole) {
            let depth = CGFloat(line.substring(with: m.range).filter { $0 == ">" }.count)
            let indent = Self.quoteIndent * depth
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.72), range: range)
            if lineActive {
                dim(abs(m.range), in: storage)
            } else {
                hide(abs(m.range), reserve: indent, in: storage)
                storage.addAttribute(Self.decorationKey, value: Decoration.quote.rawValue, range: abs(m.range))
            }
            let p = baseParagraph()
            p.headIndent = indent
            p.minimumLineHeight = lineHeight
            paragraph = p
            contentStart = m.range.length

            // `> [!note] Title` — the callout header.
            let rest = NSRange(location: contentStart, length: line.length - contentStart)
            if let c = Self.callout.firstMatch(in: lineString, range: rest) {
                let title = NSRange(location: NSMaxRange(c.range), length: line.length - NSMaxRange(c.range))
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: Self.baseSize, weight: .semibold),
                    .foregroundColor: accent
                ], range: abs(NSRange(location: contentStart, length: line.length - contentStart)))
                if title.length > 0 { mark(abs(c.range), show: lineActive, in: storage) }
                contentStart = NSMaxRange(c.range)
            }

        } else if let m = Self.list.firstMatch(in: lineString, range: whole) {
            // List markers are always rendered, never shown as source.
            let leading = m.range(at: 1)
            let markerText = line.substring(with: m.range(at: 2))
            let isOrdered = markerText.first?.isNumber == true
            let hasBox = m.range(at: 4).location != NSNotFound
            let marker = NSRange(location: leading.length, length: m.range.length - leading.length)
            let leadingWidth = width(of: line.substring(with: leading))

            var reserved: CGFloat
            if hasBox {
                let done = line.substring(with: m.range(at: 5)) != " "
                reserved = Self.checkboxWidth
                hide(abs(marker), reserve: reserved, in: storage)
                let kind: Decoration = done ? .checkboxDone : .checkbox
                storage.addAttribute(Self.decorationKey, value: kind.rawValue, range: abs(marker))
                if done, m.range.length < line.length {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: ink.withAlphaComponent(0.5)
                    ], range: abs(NSRange(location: m.range.length, length: line.length - m.range.length)))
                }
            } else if isOrdered {
                reserved = width(of: line.substring(with: marker))
                storage.addAttribute(.foregroundColor, value: accent, range: abs(marker))
            } else {
                reserved = Self.bulletWidth
                hide(abs(marker), reserve: reserved, in: storage)
                storage.addAttribute(Self.decorationKey, value: Decoration.bullet.rawValue, range: abs(marker))
            }

            let p = baseParagraph()
            p.headIndent = leadingWidth + reserved
            p.minimumLineHeight = lineHeight
            paragraph = p
            contentStart = m.range.length
        }

        if let paragraph {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        styleInline(line, from: contentStart, offset: range.location, selection: selection, in: storage)
    }

    private func codeAttributes(dim: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: dim ? ink.withAlphaComponent(0.45) : ink,
            Self.decorationKey: Decoration.codeLine.rawValue
        ]
    }

    // MARK: - Inline

    /// `selection == nil` means nothing is revealed — used for table cells.
    private func styleInline(
        _ line: NSString,
        from start: Int,
        offset: Int,
        selection: NSRange?,
        in storage: NSTextStorage
    ) {
        let scope = NSRange(location: start, length: line.length - start)
        guard scope.length > 0 else { return }
        let string = line as String
        var protected: [NSRange] = []

        func abs(_ r: NSRange) -> NSRange {
            NSRange(location: offset + r.location, length: r.length)
        }
        func overlaps(_ r: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, r).length > 0 }
        }
        /// The caret is inside the span or touching either end of it.
        func revealed(_ span: NSRange) -> Bool {
            guard let selection else { return false }
            return Self.touches(selection, abs(span))
        }
        func marker(_ r: NSRange, show: Bool) {
            guard r.length > 0 else { return }
            mark(abs(r), show: show, in: storage)
        }

        // Escaped characters are literal: `\*` must not open emphasis.
        for m in Self.escape.matches(in: string, range: scope) {
            protected.append(m.range)
            marker(NSRange(location: m.range.location, length: 1), show: revealed(m.range))
        }

        for m in Self.comment.matches(in: string, range: scope) where !overlaps(m.range) {
            protected.append(m.range)
            let show = revealed(m.range)
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.42), range: abs(m.range(at: 2)))
            marker(m.range(at: 1), show: show)
            marker(NSRange(location: NSMaxRange(m.range) - 2, length: 2), show: show)
        }

        for m in Self.code.matches(in: string, range: scope) where !overlaps(m.range) {
            protected.append(m.range)
            let show = revealed(m.range)
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .backgroundColor: ink.withAlphaComponent(0.09)
            ], range: abs(m.range(at: 1)))
            marker(NSRange(location: m.range.location, length: 1), show: show)
            marker(NSRange(location: NSMaxRange(m.range) - 1, length: 1), show: show)
        }

        for m in Self.wikilink.matches(in: string, range: scope) where !overlaps(m.range) {
            protected.append(m.range)
            let show = revealed(m.range)
            let target = m.range(at: 1)
            let alias = m.range(at: 2)
            let shown = alias.location != NSNotFound ? alias : target
            storage.addAttribute(.foregroundColor, value: accent, range: abs(shown))
            marker(NSRange(location: m.range.location, length: shown.location - m.range.location), show: show)
            marker(NSRange(location: NSMaxRange(shown), length: NSMaxRange(m.range) - NSMaxRange(shown)), show: show)
        }

        for m in Self.link.matches(in: string, range: scope) where !overlaps(m.range) {
            protected.append(m.range)
            let show = revealed(m.range)
            let label = m.range(at: 1)
            storage.addAttributes([
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                Self.linkKey: line.substring(with: m.range(at: 2))
            ], range: abs(label))
            marker(NSRange(location: m.range.location, length: label.location - m.range.location), show: show)
            marker(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)), show: show)
        }

        for m in Self.bareURL.matches(in: string, range: scope) where !overlaps(m.range) {
            protected.append(m.range)
            storage.addAttributes([
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                Self.linkKey: line.substring(with: m.range)
            ], range: abs(m.range))
        }

        func pairs(_ regex: NSRegularExpression, protect: Bool = false, _ style: (NSRange) -> Void) {
            for m in regex.matches(in: string, range: scope) where !overlaps(m.range) {
                let content = m.range(at: 2)
                let length = m.range(at: 1).length
                let show = revealed(m.range)
                style(abs(content))
                marker(NSRange(location: m.range.location, length: length), show: show)
                marker(NSRange(location: NSMaxRange(content), length: length), show: show)
                if protect { protected.append(m.range) }
            }
        }

        pairs(Self.boldItalic, protect: true) {
            addTrait([.bold, .italic], in: $0, storage)
        }
        pairs(Self.bold) { addTrait(.bold, in: $0, storage) }
        pairs(Self.italicStar) { addTrait(.italic, in: $0, storage) }
        pairs(Self.italicUnderscore) { addTrait(.italic, in: $0, storage) }
        pairs(Self.strike) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0)
        }
        pairs(Self.highlight) {
            storage.addAttribute(.backgroundColor, value: highlight.withAlphaComponent(0.3), range: $0)
        }

        // `#tag` in the body is plain text: tags live in the footer field only.
    }

    // MARK: - Tables

    private func styleTable(
        rows: [Int],
        separator: Int,
        lines: [(NSRange, NSRange)],
        text: NSString,
        active: Bool,
        width: CGFloat,
        in storage: NSTextStorage
    ) {
        let allLines = (rows + [separator]).sorted()

        // Caret inside: show the source, monospaced so the columns still line up.
        if active {
            for i in allLines {
                let range = lines[i].1
                storage.addAttributes(
                    [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)],
                    range: range
                )
                var search = NSRange(location: lines[i].0.location, length: lines[i].0.length)
                while search.length > 0 {
                    let pipe = text.range(of: "|", range: search)
                    guard pipe.location != NSNotFound else { break }
                    dim(pipe, in: storage)
                    let next = NSMaxRange(pipe)
                    search = NSRange(location: next, length: NSMaxRange(lines[i].0) - next)
                }
            }
            return
        }

        func lineText(_ i: Int) -> String {
            lines[i].0.length > 0 ? text.substring(with: lines[i].0) : ""
        }
        let header = Self.cells(of: lineText(rows[0]))
        let columns = max(header.count, 1)
        let alignments = Self.cells(of: lineText(separator)).map { cell -> NSTextAlignment in
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            return left && right ? .center : (right ? .right : .left)
        }

        let cells: [[NSAttributedString]] = rows.enumerated().map { rowIndex, line in
            var raw = Self.cells(of: lineText(line))
            if raw.count < columns { raw += Array(repeating: "", count: columns - raw.count) }
            return raw.prefix(columns).enumerated().map { column, cell in
                cellText(
                    cell, bold: rowIndex == 0,
                    alignment: column < alignments.count ? alignments[column] : .left
                )
            }
        }

        let padX = TableLayout.cellPaddingX * 2
        let natural: [CGFloat] = (0..<columns).map { column in
            let widest = cells.map { row in
                ceil(row[column].boundingRect(
                    with: NSSize(width: 10_000, height: 10_000),
                    options: [.usesLineFragmentOrigin]
                ).width)
            }.max() ?? 0
            return widest + padX + 2
        }
        // A column never squeezes below its longest word, so words are not cut.
        let longestWord: [CGFloat] = (0..<columns).map { column in
            let font = NSFont.systemFont(ofSize: Self.tableFontSize, weight: .semibold)
            let widest = cells.map { row in
                row[column].string.split(whereSeparator: \.isWhitespace)
                    .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
                    .max() ?? 0
            }.max() ?? 0
            return widest + padX + 2
        }
        let columnWidths = Self.fit(natural, floors: longestWord, into: width)

        for (rowIndex, line) in rows.enumerated() {
            let height = ceil((0..<columns).map { column in
                cells[rowIndex][column].boundingRect(
                    with: NSSize(width: max(columnWidths[column] - padX, 10), height: 10_000),
                    options: [.usesLineFragmentOrigin]
                ).height
            }.max() ?? 0) + TableLayout.cellPaddingY * 2
            hideRow(lines[line].1, height: max(height, 24), in: storage)
        }
        hideRow(lines[separator].1, height: 1, in: storage)

        let layout = TableLayout(cells: cells, rowRanges: rows.map { lines[$0].1 }, columnWidths: columnWidths)
        for i in allLines {
            storage.addAttribute(Self.tableKey, value: layout, range: lines[i].1)
        }
    }

    /// Raw row text made invisible, and the row forced to the height its drawn
    /// version needs.
    private func hideRow(_ range: NSRange, height: CGFloat, in storage: NSTextStorage) {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        p.lineBreakMode = .byClipping
        storage.addAttributes([
            .font: Self.hiddenFont,
            .foregroundColor: NSColor.clear,
            .paragraphStyle: p
        ], range: range)
    }

    private func cellText(_ text: String, bold: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: Self.tableFontSize)
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        let storage = NSTextStorage(string: text, attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: p
        ])
        styleInline(text as NSString, from: 0, offset: 0, selection: nil, in: storage)
        if bold {
            addTrait(.bold, in: NSRange(location: 0, length: storage.length), storage)
        }
        return NSAttributedString(attributedString: storage)
    }

    /// Natural widths if they fit; otherwise squeezed, the widest columns
    /// giving up the most, so cells wrap instead of the table overflowing.
    private static func fit(_ natural: [CGFloat], floors minimum: [CGFloat], into available: CGFloat) -> [CGFloat] {
        let room = available > 0 ? available : 300
        let total = natural.reduce(0, +)
        guard total > room else { return natural }

        // Prefer not cutting words (capped, so one long token cannot hog the
        // row); if even that does not fit, fall back to a flat minimum.
        var floors = zip(natural, minimum).map { min($0, min($1, 74)) }
        if floors.reduce(0, +) > room * 0.85 { floors = natural.map { min($0, 56) } }
        let floorTotal = floors.reduce(0, +)
        if floorTotal >= room { return floors.map { $0 * room / floorTotal } }

        let slack = zip(natural, floors).map { $0 - $1 }
        let slackTotal = slack.reduce(0, +)
        let spare = room - floorTotal
        return zip(floors, slack).map { $0 + $1 / slackTotal * spare }
    }

    /// `| a | b |` → `["a", "b"]`. `\|` stays inside a cell.
    static func cells(of line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        return text
            .replacingOccurrences(of: "\\|", with: "\u{1}")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Helpers

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    /// Whether the selection is inside `range` or touching either end of it.
    static func touches(_ selection: NSRange, _ range: NSRange) -> Bool {
        guard selection.location != NSNotFound else { return false }
        return selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
    }

    /// Syntax characters: shown dimmed when revealed, otherwise hidden.
    private func mark(_ range: NSRange, show: Bool, in storage: NSTextStorage) {
        if show { dim(range, in: storage) } else { hide(range, reserve: 0, in: storage) }
    }

    private func dim(_ range: NSRange, in storage: NSTextStorage) {
        storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.4), range: range)
    }

    /// Near-zero width, invisible. `reserve` keeps room after the last hidden
    /// character for whatever `MarkdownTextView` paints in its place.
    private func hide(_ range: NSRange, reserve: CGFloat, in storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: range)
        if reserve > 0 {
            storage.addAttribute(.kern, value: reserve, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
    }

    /// Adds bold or italic to whatever font is already there, so `**` inside a
    /// heading, or `*` inside `**`, composes instead of overwriting.
    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange, _ storage: NSTextStorage) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { runs.append((run, font)) }
        }
        for (run, font) in runs {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: styled, range: run)
            }
        }
    }

    private var lineHeight: CGFloat {
        let font = baseFont
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Width of leading whitespace or a marker in the body font. Tabs count as
    /// a tab stop, which is what the text system will lay them out as.
    private func width(of string: String) -> CGFloat {
        let tabs = string.filter { $0 == "\t" }.count
        let rest = string.replacingOccurrences(of: "\t", with: "")
        return CGFloat(tabs) * Self.tabWidth
            + (rest as NSString).size(withAttributes: [.font: baseFont]).width
    }
}
