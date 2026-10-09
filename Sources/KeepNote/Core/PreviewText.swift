import Foundation

/// The one-line summary of a note's body, for list rows and the peek.
enum PreviewText {
    static let empty = "No additional text"

    /// `plainBody` with its first line dropped when that line is only the title
    /// said again: either the title is empty and the line stands in for it, or
    /// the line (a `# Heading`, once its markup is stripped) equals the title.
    static func make(title: String, plainBody: String) -> String {
        var lines = plainBody.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first non-blank line is the one that can repeat the title.
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let line = lines[first].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.isEmpty || line.caseInsensitiveCompare(trimmedTitle) == .orderedSame {
                lines.removeSubrange(0...first)
            }
        }
        let joined = lines
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return joined.isEmpty ? empty : joined
    }
}
