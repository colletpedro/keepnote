import Foundation

/// Every string the code shows has an English and a Portuguese entry.
///
/// Reads the sources themselves: each `L("…")` is a key that must be in
/// `Resources/en.lproj` and `Resources/pt-BR.lproj` with the same format
/// arguments, and neither table may keep a key the code no longer uses. Then
/// any other string literal that reads like interface text — words with a
/// space between them, a capitalised word, or the text handed to `Text`,
/// `Button`, `.help` and the like — fails, unless it is one of the few left
/// in English on purpose, listed below with the reason.
func runLocalizationTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")

    var keys: [String: String] = [:]      // key → first file using it
    var unwrapped: [String] = []
    var interpolatedKeys: [String] = []

    let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL } ?? [])
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    for file in files {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let name = file.lastPathComponent
        for literal in SwiftLiterals.scan(text) {
            if literal.isKey {
                if literal.raw.contains("\\(") {
                    interpolatedKeys.append("\(name): \(literal.raw)")
                } else if keys[literal.value] == nil {
                    keys[literal.value] = name
                }
            } else if SwiftLiterals.looksVisible(literal), !LeftInEnglish.covers(literal.raw) {
                unwrapped.append("\(name):\(literal.line): \"\(literal.raw)\"")
            }
        }
    }

    expectTrue("l10n: the sources were found", keys.count > 300)
    expect("l10n: no interpolation inside a key", interpolatedKeys.joined(separator: "\n"), "")
    expect("l10n: every visible string goes through L(_:)", unwrapped.joined(separator: "\n"), "")

    for language in ["en", "pt-BR"] {
        let path = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings").path
        guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
            expectTrue("l10n: \(language) table reads", false)
            continue
        }
        let missing = keys.keys.filter { table[$0] == nil }.sorted()
        expect("l10n: \(language) has every key", missing.joined(separator: "\n"), "")
        let stale = table.keys.filter { keys[$0] == nil }.sorted()
        expect("l10n: \(language) has no key the code dropped", stale.joined(separator: "\n"), "")
        let empty = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys.sorted()
        expect("l10n: \(language) has no empty text", empty.joined(separator: "\n"), "")
        let mismatched = table.filter { SwiftLiterals.formatArguments($0.key) != SwiftLiterals.formatArguments($0.value) }
            .keys.sorted()
        expect("l10n: \(language) keeps each key's %@ and %d", mismatched.joined(separator: "\n"), "")
        if language == "en" {
            let rewritten = table.filter { Localization.shown($0.key) != $0.value }.keys.sorted()
            expect("l10n: English is the key itself", rewritten.joined(separator: "\n"), "")
        } else {
            expectTrue("l10n: Daily stays Daily", table["Daily"] == "Daily")
            expectTrue("l10n: the reserved tag stays daily", table["add daily"]?.contains("daily") == true)
            let translated = table.filter { $0.key != $0.value }.count
            expectTrue("l10n: Portuguese is actually translated (\(translated) of \(table.count))",
                       translated * 10 > table.count * 8)
        }
    }
}

/// The strings the app keeps in English, and why. Matched by the start of the
/// literal as written in the source.
private enum LeftInEnglish {
    static let prefixes: [String: String] = [
        "KeepNote": "the app's name",
        "SQLite error": "diagnostics from SQLite, whose own message is English",
        "unable to open database": "SQLite's wording, inside the same diagnostics",
        "unknown error": "SQLite's fallback, inside the same diagnostics",
        "launch event=": "unified log, for development",
        "reading the body key": "unified log, for development",
        "init(coder:)": "a programmer error, never shown",
        "Library/Application Support": "a path",
        "Localizable": "the table's file name",
        "English": "a language's name in itself",
        "above \\(": "an internal signature",
        "pinned \\(": "an internal signature",
        "Backups": "the backups folder's name on disk",
        "VACUUM INTO": "SQL",
        "backup ": "unified log, for development",
    ]

    static func covers(_ raw: String) -> Bool {
        prefixes.keys.contains { raw.hasPrefix($0) }
    }
}

/// Just enough of Swift's string literal grammar to find them in a file:
/// comments skipped, `"…"` and `"""…"""`, escapes and nested interpolation.
enum SwiftLiterals {
    struct Literal {
        var raw: String
        var value: String
        var line: Int
        /// Passed straight to `L(`.
        var isKey: Bool
        /// The text just before the opening quote, for the UI-call check.
        var lead: String
    }

    static func scan(_ text: String) -> [Literal] {
        let chars = Array(text)
        var result: [Literal] = []
        var i = 0
        var line = 1
        func at(_ index: Int, _ string: String) -> Bool {
            let s = Array(string)
            guard index + s.count <= chars.count else { return false }
            return Array(chars[index..<index + s.count]) == s
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if at(i, "//") {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if at(i, "/*") {
                i += 2
                while i < chars.count, !at(i, "*/") { if chars[i] == "\n" { line += 1 }; i += 1 }
                i += 2
                continue
            }
            guard c == "\"" else { i += 1; continue }
            let multiline = at(i, "\"\"\"")
            let start = i + (multiline ? 3 : 1)
            var j = start
            var depth = 0
            let startLine = line
            while j < chars.count {
                if chars[j] == "\n" { line += 1 }
                if chars[j] == "\\", j + 1 < chars.count {
                    if chars[j + 1] == "(" { depth += 1 }
                    j += 2
                    continue
                }
                if depth > 0 {
                    if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                    if chars[j] == "\"" {
                        // A literal inside an interpolation: skip it whole.
                        j += 1
                        while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                    }
                    j += 1
                    continue
                }
                if multiline ? at(j, "\"\"\"") : chars[j] == "\"" { break }
                j += 1
            }
            let raw = String(chars[start..<min(j, chars.count)])
            let leadStart = max(0, i - 40)
            let lead = String(chars[leadStart..<i])
            let isKey = lead.hasSuffix("L(") && !(lead.dropLast(2).last.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } ?? false)
            result.append(Literal(raw: raw, value: decode(raw), line: startLine, isKey: isKey && !multiline, lead: lead))
            i = j + (multiline ? 3 : 1)
        }
        return result
    }

    /// The runtime value of a literal without interpolation.
    static func decode(_ raw: String) -> String {
        var out = ""
        var chars = raw.makeIterator()
        while let c = chars.next() {
            guard c == "\\" else { out.append(c); continue }
            switch chars.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            case "u":
                _ = chars.next() // {
                var hex = ""
                while let h = chars.next(), h != "}" { hex.append(h) }
                if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) { out.unicodeScalars.append(scalar) }
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    private static let prose = try! NSRegularExpression(pattern: "[A-Za-z]{2,}[ \\u00A0][A-Za-z]|^[A-Z][a-z]+(\\u2026|\\.)?$")
    private static let sql = try! NSRegularExpression(
        pattern: "^\\s*(SELECT|INSERT|UPDATE|DELETE|CREATE|PRAGMA|ALTER|DROP|BEGIN|COMMIT|ROLLBACK|WITH|REPLACE)\\b")
    /// Calls whose first string is shown to someone.
    private static let heads = ["Text(", "Button(", "Toggle(", "Picker(", "LabeledContent(", "Section(", ".help(",
                                "HelpNote(text: ", "Option(help: ", "Label(", "Link(", "TextField(", "accessibilityLabel(",
                                "withTitle: ", "toolTip = ", "placeholderString = ", "accessibilityDescription: ",
                                "messageText = ", "informativeText = ", "prompt = ", "message = ", ".notice(", "title: "]

    static func looksVisible(_ literal: Literal) -> Bool {
        // The words of the literal, without its interpolations and escapes.
        let words = literal.raw
            .replacingOccurrences(of: "\\\\\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\\u\\{[0-9A-Fa-f]+\\}", with: "", options: .regularExpression)
        let range = NSRange(words.startIndex..., in: words)
        if sql.firstMatch(in: words, range: range) != nil { return false }
        if prose.firstMatch(in: words, range: range) != nil { return true }
        let shown = heads.contains { literal.lead.hasSuffix($0) }
        return shown && words.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil
    }

    /// `%@`, `%d` and positional `%1$@`, in order, so a translation can be
    /// checked against its key.
    static func formatArguments(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?[@d]")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range) }
            .sorted()
    }
}
