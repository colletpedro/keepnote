import Foundation

/// Markdown reduced to what it reads as: no `#`, `**`, `>` or `- [ ]`.
///
/// The stack labels, list rows and hover previews are plain `Text`, so they
/// would otherwise show the raw syntax the editor now hides. The stored body is
/// never changed — this is display only.
enum MarkdownText {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let rule = regex(#"^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let heading = regex(#"^#{1,6}[ \t]+"#)
    private static let quote = regex(#"^[ \t]{0,3}(?:>[ \t]?)+"#)
    private static let openTask = regex(#"^([ \t]*)[-*+][ \t]+\[ \][ \t]+"#)
    private static let doneTask = regex(#"^([ \t]*)[-*+][ \t]+\[[xX]\][ \t]+"#)
    private static let bullet = regex(#"^([ \t]*)[-*+][ \t]+"#)

    private static let tableSeparator = regex(#"^[ \t]*\|?[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#)

    private static let inline: [(NSRegularExpression, String)] = [
        (regex(#"%%.+?%%"#), ""),
        (regex(#"\[\[[^\]\n|]+\|([^\]\n]+)\]\]"#), "$1"),
        (regex(#"\[\[([^\]\n]+)\]\]"#), "$1"),
        (regex(#"\[([^\]\n]+)\]\([^)\s]+\)"#), "$1"),
        (regex(#"`([^`\n]+)`"#), "$1"),
        (regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), "$2"),
        (regex(#"(?<![*\w])\*(?![\s*])(.+?)(?<![\s*])\*(?!\*)"#), "$1"),
        (regex(#"(?<![_\w])_(?![\s_])(.+?)(?<![\s_])_(?![_\w])"#), "$1"),
        (regex(#"~~(?=\S)(.+?)(?<=\S)~~"#), "$1"),
        (regex(#"==(?=\S)(.+?)(?<=\S)=="#), "$1"),
    ]

    static func plain(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return markdown }
        return plainLines(markdown) { _ in false }.joined(separator: "\n")
    }

    /// The first line of `plain(markdown)` that is not empty, reading no
    /// further into the body than it has to.
    static func firstPlainLine(_ markdown: String) -> String? {
        plainLines(markdown) { !$0.isEmpty }.last.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The plain lines in order, stopping after the first one `stop` accepts.
    private static func plainLines(_ markdown: String, stop: (String) -> Bool) -> [String] {
        var inFence = false
        var lines: [String] = []

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(line)
                if stop(line) { break }
                continue
            }
            if matches(rule, line) { continue }
            // Tables: drop the `|---|` row, flatten the others to "a · b".
            if line.contains("-"), matches(tableSeparator, line), line.contains("|") { continue }
            if trimmed.hasPrefix("|") {
                line = MarkdownStyler.cells(of: line).filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            }

            line = replace(heading, in: line, with: "")
            line = replace(quote, in: line, with: "")
            line = replace(openTask, in: line, with: "$1\u{2610} ")
            line = replace(doneTask, in: line, with: "$1\u{2611} ")
            line = replace(bullet, in: line, with: "$1\u{2022} ")
            for (pattern, template) in inline {
                line = replace(pattern, in: line, with: template)
            }
            lines.append(line)
            if stop(line) { break }
        }
        return lines
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: template
        )
    }
}
