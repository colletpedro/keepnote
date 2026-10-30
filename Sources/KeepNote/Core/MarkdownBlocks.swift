import Foundation

/// A piece of a line of Markdown: what the HTML and the rich-text clipboard
/// formats are drawn from.
enum MarkdownSpan: Equatable {
    case text(String)
    case code(String)
    case bold([MarkdownSpan])
    case italic([MarkdownSpan])
    case strike([MarkdownSpan])
    case highlight([MarkdownSpan])
    case link([MarkdownSpan], String)
}

struct MarkdownListItem: Equatable {
    /// `nil` for a plain item; otherwise whether the task is done.
    var task: Bool?
    var spans: [MarkdownSpan]
    var sublists: [MarkdownList]
}

struct MarkdownList: Equatable {
    var ordered: Bool
    var start: Int
    var items: [MarkdownListItem]
}

enum MarkdownBlock: Equatable {
    case heading(Int, [MarkdownSpan])
    /// One entry per line: a line break inside a paragraph is kept.
    case paragraph([[MarkdownSpan]])
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case code(String)
    case rule
    case table(header: [[MarkdownSpan]], rows: [[[MarkdownSpan]]])
    case attachment(AttachmentText.Reference)
}

/// A note's Markdown read into blocks, for the formats that are not Markdown.
///
/// Reads what the editor writes — headings, lists, tasks, quotes, code, rules,
/// tables, links, `**bold**`, `*italic*`, `~~strike~~`, `==highlight==` and the
/// attachment lines — and leaves anything else as the text it is. Obsidian's
/// `%%comments%%` are dropped and `[[links]]` read as their words, as the
/// lists and previews do.
enum MarkdownBlocks {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let ruleLine = regex(#"^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let headingLine = regex(#"^[ \t]{0,3}(#{1,6})[ \t]+(.*?)[ \t]*$"#)
    private static let listLine = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$"#)
    private static let taskText = regex(#"^\[([ xX])\](?:[ \t]+(.*))?$"#)
    private static let tableSeparator = regex(#"^[ \t]*\|?[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#)

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func groups(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    // MARK: - Blocks

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(lines: lines)
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let next = lines[index + 1]
        return line.hasPrefix("|") && next.contains("-") && next.contains("|") && matches(tableSeparator, next)
    }

    /// Whether `line` starts a block of its own, ending a paragraph.
    private static func startsBlock(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        return isFence(line) || matches(headingLine, line) || matches(ruleLine, line)
            || matches(listLine, line) || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            || AttachmentText.isReferenceLine(line) || isTableStart(lines, index)
    }

    private static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if isFence(line) {
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1   // the closing fence, if there is one
                blocks.append(.code(code.joined(separator: "\n")))
            } else if AttachmentText.isReferenceLine(line), let reference = AttachmentText.references(in: line).first {
                blocks.append(.attachment(reference))
                index += 1
            } else if matches(ruleLine, line) {
                blocks.append(.rule)
                index += 1
            } else if let heading = groups(headingLine, line) {
                blocks.append(.heading(heading[1].count, MarkdownInline.parse(heading[2])))
                index += 1
            } else if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[index].trimmingCharacters(in: .whitespaces)
                    content.removeFirst()
                    if content.hasPrefix(" ") { content.removeFirst() }
                    inner.append(content)
                    index += 1
                }
                blocks.append(.quote(parse(lines: inner)))
            } else if isTableStart(lines, index) {
                let header = cells(of: lines[index]).map(MarkdownInline.parse)
                index += 2
                var rows: [[[MarkdownSpan]]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(of: lines[index]).map(MarkdownInline.parse))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if matches(listLine, line) {
                var flat: [FlatItem] = []
                while index < lines.count, let item = FlatItem(lines[index]) {
                    flat.append(item)
                    index += 1
                }
                var position = 0
                for list in lists(flat, &position) { blocks.append(.list(list)) }
            } else {
                var paragraph: [[MarkdownSpan]] = []
                repeat {
                    paragraph.append(MarkdownInline.parse(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                } while index < lines.count
                    && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && !startsBlock(lines, index)
                blocks.append(.paragraph(paragraph))
            }
        }
        return blocks
    }

    /// The cells of one table row.
    static func cells(of row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Lists

    private struct FlatItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        var task: Bool?
        var text: String

        init?(_ line: String) {
            guard let parts = MarkdownBlocks.groups(MarkdownBlocks.listLine, line) else { return nil }
            indent = parts[1].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let marker = parts[2]
            ordered = marker.last == "." || marker.last == ")"
            number = ordered ? Int(marker.dropLast()) ?? 1 : 1
            if let task = MarkdownBlocks.groups(MarkdownBlocks.taskText, parts[3]) {
                self.task = task[1] != " "
                text = task[2]
            } else {
                text = parts[3]
            }
        }
    }

    /// The lists that start at `flat[position]`, at its indent, with whatever
    /// is indented further inside the item above it.
    private static func lists(_ flat: [FlatItem], _ position: inout Int) -> [MarkdownList] {
        guard position < flat.count else { return [] }
        let level = flat[position].indent
        var found: [MarkdownList] = []
        while position < flat.count {
            let entry = flat[position]
            if entry.indent < level { break }
            if entry.indent > level {
                let inner = lists(flat, &position)
                if let last = found.indices.last, let item = found[last].items.indices.last {
                    found[last].items[item].sublists += inner
                } else {
                    found += inner
                }
                continue
            }
            if found.last?.ordered != entry.ordered {
                found.append(MarkdownList(ordered: entry.ordered, start: entry.number, items: []))
            }
            found[found.count - 1].items.append(
                MarkdownListItem(task: entry.task, spans: MarkdownInline.parse(entry.text), sublists: []))
            position += 1
        }
        return found
    }
}

/// A line of text read into spans.
enum MarkdownInline {
    static func parse(_ text: String) -> [MarkdownSpan] { parse(Array(text)) }

    private static let escapable = Set("\\`*_{}[]()#+-.!~=|>%<")

    private static func parse(_ chars: [Character]) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        var buffer = ""
        var index = 0
        func flush() {
            if !buffer.isEmpty { spans.append(.text(buffer)); buffer = "" }
        }
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count, escapable.contains(chars[index + 1]) {
                buffer.append(chars[index + 1])
                index += 2
            } else if ch == "`", let end = find(chars, "`", from: index + 1), end > index + 1 {
                flush()
                spans.append(.code(String(chars[(index + 1)..<end])))
                index = end + 1
            } else if ch == "%", starts(chars, "%%", at: index), let end = find(chars, "%%", from: index + 2) {
                index = end + 2
            } else if ch == "[", starts(chars, "[[", at: index), let end = find(chars, "]]", from: index + 2), end > index + 2 {
                // [[note]] and [[note|words]]: the words.
                let inner = String(chars[(index + 2)..<end])
                buffer += inner.components(separatedBy: "|").last ?? inner
                index = end + 2
            } else if ch == "[" || (ch == "!" && index + 1 < chars.count && chars[index + 1] == "["),
                      let link = link(chars, at: ch == "!" ? index + 1 : index) {
                flush()
                let label = link.label.isEmpty ? [.text(link.url)] : parse(link.label)
                spans.append(.link(label, link.url))
                index = link.next
            } else if let styled = styled(chars, at: index) {
                flush()
                spans.append(styled.span)
                index = styled.next
            } else {
                buffer.append(ch)
                index += 1
            }
        }
        flush()
        return spans
    }

    private static func starts(_ chars: [Character], _ marker: String, at index: Int) -> Bool {
        let marker = Array(marker)
        guard index + marker.count <= chars.count else { return false }
        return Array(chars[index..<(index + marker.count)]) == marker
    }

    private static func find(_ chars: [Character], _ marker: String, from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            if starts(chars, marker, at: index) { return index }
            index += 1
        }
        return nil
    }

    /// `[label](url "title")` at `index`.
    private static func link(_ chars: [Character], at index: Int) -> (label: [Character], url: String, next: Int)? {
        guard index < chars.count, chars[index] == "[" else { return nil }
        var close = index + 1
        while close < chars.count, chars[close] != "]" {
            if chars[close] == "\n" { return nil }
            close += 1
        }
        guard close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
        var depth = 1
        var end = close + 2
        while end < chars.count {
            if chars[end] == "(" { depth += 1 }
            if chars[end] == ")" { depth -= 1; if depth == 0 { break } }
            end += 1
        }
        guard end < chars.count else { return nil }
        var target = String(chars[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), let closing = target.firstIndex(of: ">") {
            target = String(target[target.index(after: target.startIndex)..<closing])
        } else if let space = target.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            target = String(target[..<space])
        }
        return (Array(chars[(index + 1)..<close]), target, end + 1)
    }

    /// Bold, italic, strike and highlight starting at `index`.
    private static func styled(_ chars: [Character], at index: Int) -> (span: MarkdownSpan, next: Int)? {
        let ch = chars[index]
        guard "*_~=".contains(ch) else { return nil }
        let doubled = starts(chars, String([ch, ch]), at: index)
        if doubled, let found = delimited(chars, at: index, delimiter: String([ch, ch])) {
            let inner = parse(found.inner)
            switch ch {
            case "*", "_": return (.bold(inner), found.next)
            case "~": return (.strike(inner), found.next)
            default: return (.highlight(inner), found.next)
            }
        }
        if ch == "*" || ch == "_", let found = delimited(chars, at: index, delimiter: String(ch)) {
            return (.italic(parse(found.inner)), found.next)
        }
        return nil
    }

    private static func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber }

    private static func delimited(_ chars: [Character], at index: Int, delimiter: String) -> (inner: [Character], next: Int)? {
        let mark = delimiter.first!
        let length = delimiter.count
        let open = index + length
        guard open < chars.count, !chars[open].isWhitespace else { return nil }
        if length == 1, chars[open] == mark { return nil }
        // Underscores inside a word are just underscores.
        if mark == "_", index > 0, isWord(chars[index - 1]) { return nil }
        var close = open + 1
        while close + length <= chars.count {
            if starts(chars, delimiter, at: close) {
                if length == 1, close + 1 < chars.count, chars[close + 1] == mark {
                    close += 2   // the end of a bold run inside an italic one
                    continue
                }
                // In a longer run the last marks close: `**a *b***`.
                if length == 2, close + 2 < chars.count, chars[close + 2] == mark {
                    close += 1
                    continue
                }
                let afterWord = mark == "_" && close + length < chars.count && isWord(chars[close + length])
                if !chars[close - 1].isWhitespace, !afterWord, close > open {
                    return (Array(chars[open..<close]), close + length)
                }
            }
            close += 1
        }
        return nil
    }
}
