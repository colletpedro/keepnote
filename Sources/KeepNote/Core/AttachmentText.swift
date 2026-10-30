import Foundation

/// How a note's text refers to its attachments.
///
/// An attachment is a line of its own: `![description](attachment:ID)` for an
/// image, `[name](attachment:ID)` for any other file, where `ID` is the
/// SHA-256 of the file's bytes in lower-case hex. The bytes live in the
/// database (sealed like the body); the text only names them, so two notes,
/// or one note twice, holding the same file hold it once.
///
/// The editor draws the image or a card in place of the line; everything that
/// reads the text for display or search (titles, the deck's labels, previews,
/// search) leaves these lines out.
enum AttachmentText {
    struct Reference: Equatable {
        /// The SHA-256 of the file.
        var id: String
        var isImage: Bool
        /// The image's description, or the file's name.
        var label: String
        /// The whole line, without its line break.
        var range: NSRange
        /// Where the label sits, inside `range`.
        var labelRange: NSRange
    }

    static let scheme = "attachment"

    private static let line: NSRegularExpression = {
        let pattern = "^[ \\t]*(!?)\\[([^\\]\\n]*)\\]\\(attachment:([0-9a-f]{64})\\)[ \\t]*$"
        // A literal in this file; a bad one is a programming error.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    /// Every attachment line in `text`, in order.
    static func references(in text: String) -> [Reference] {
        guard text.contains("(attachment:") else { return [] }
        let ns = text as NSString
        return line.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            Reference(
                id: ns.substring(with: match.range(at: 3)),
                isImage: match.range(at: 1).length == 1,
                label: unescape(ns.substring(with: match.range(at: 2))),
                range: match.range,
                labelRange: match.range(at: 2)
            )
        }
    }

    /// The attachments `text` refers to, each once.
    static func ids(in text: String) -> Set<String> {
        Set(references(in: text).map(\.id))
    }

    /// The reference at `location`, if that line is one.
    static func reference(at location: Int, in text: String) -> Reference? {
        references(in: text).first { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location }
    }

    /// Whether this one line (no line break) is an attachment.
    static func isReferenceLine(_ text: String) -> Bool {
        text.contains("(attachment:") && !references(in: text).isEmpty
    }

    /// The line for an attachment.
    static func token(id: String, isImage: Bool, label: String) -> String {
        "\(isImage ? "!" : "")[\(escape(label))](\(scheme):\(id))"
    }

    /// `text` with every attachment line taken out, for titles, labels,
    /// previews and search.
    static func removingReferences(from text: String) -> String {
        guard text.contains("(attachment:") else { return text }
        let ns = text as NSString
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, _, _, _ in
            guard let line else { return }
            if !isReferenceLine(line) { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// The text to put at `selection` so the attachment lands on a line of
    /// its own: a line break before it unless it starts a line, one after it
    /// unless a line break already follows. Returns the replacement and where
    /// the caret goes after it (an offset into the replacement).
    static func insertion(of tokens: [String], in text: String, at selection: NSRange) -> (text: String, caret: Int) {
        let ns = text as NSString
        let start = selection.location
        let end = NSMaxRange(selection)
        let atLineStart = start == 0 || ns.character(at: start - 1) == 0x0A
        let breakFollows = end < ns.length && ns.character(at: end) == 0x0A
        var result = atLineStart ? "" : "\n"
        result += tokens.joined(separator: "\n")
        // The caret goes after the last attachment's line, ready to write.
        result += "\n"
        let caret = (result as NSString).length
        if breakFollows {
            // The existing break ends the line; the one just added would be a
            // blank line, so it is the caret's line instead.
            return (String(result.dropLast()), caret)
        }
        return (result, caret)
    }

    /// A label never holds brackets or line breaks, which would end it.
    private static func escape(_ label: String) -> String {
        label
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescape(_ label: String) -> String { label }

    /// The label line with a new description, for Edit Description….
    static func relabel(_ reference: Reference, to label: String, in text: String) -> String {
        let ns = text as NSString
        let replaced = token(id: reference.id, isImage: reference.isImage, label: label)
        return ns.replacingCharacters(in: reference.range, with: replaced)
    }

    /// What stands in for an attachment that is not drawn or written out, in
    /// words: "[Image: a red barn]", "[File: Invoice.pdf]". `name` is the
    /// file's own name, said for a file whose line has no label.
    static func words(for reference: Reference, name: String? = nil) -> String {
        if reference.isImage {
            return "[" + (reference.label.isEmpty ? L("Image") : L("Image: %@", reference.label)) + "]"
        }
        return "[" + L("File: %@", reference.label.isEmpty ? (name ?? L("Attachment")) : reference.label) + "]"
    }

    /// The 25 MB a single attachment may weigh.
    static let maximumSize = 25 * 1024 * 1024
}
