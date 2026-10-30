import Foundation

/// File and folder names for what leaves the app: safe on every file system,
/// and never the same as another in the same folder.
enum ExportNames {
    /// What no name may hold: path separators, the characters Windows and the
    /// Finder refuse, and the ones Obsidian cannot link to.
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\u{0}").union(.controlCharacters)

    /// `name` as one path component: nothing illegal, no dots or blanks at
    /// the ends (a leading dot hides a file; `..` climbs out), at most
    /// `limit` characters. `fallback` stands in for a name nothing is left of.
    static func component(_ name: String, fallback: String, limit: Int = 60) -> String {
        var cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") || cleaned.hasSuffix(".") {
            cleaned = String(cleaned.drop { $0 == "." }).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasSuffix(".") { cleaned.removeLast() }
        }
        if cleaned.isEmpty { cleaned = fallback }
        if cleaned.count > limit { cleaned = String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// A file's name for a picture or attachment: its stem made safe and its
    /// extension kept whole, whatever the length of the stem.
    static func fileName(_ name: String, fallback: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let cleanExt = ext.components(separatedBy: illegal).joined().prefix(12)
        let cleanStem = component(stem, fallback: fallback, limit: 100)
        return cleanExt.isEmpty ? cleanStem : cleanStem + "." + cleanExt
    }

    /// `name`, or `name 2`, `name 3`… for the first one `taken` does not hold
    /// (case-insensitively, as the Finder compares), added to `taken`. The
    /// number goes before the extension.
    static func unique(_ name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// `path` as the target of a Markdown link: everything but letters,
    /// digits and `-._~/` is percent-encoded, so a space or a parenthesis in
    /// a name cannot end the link early.
    static func linkTarget(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
