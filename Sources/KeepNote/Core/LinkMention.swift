import Foundation

/// A link shown as a mention: an icon for its site and a readable title, the
/// way Notion's "Paste as mention" looks — made from the address alone. Nothing
/// is fetched: KeepNote has no network access, so the title is the address's
/// own words ("…/jack-johnson/traffic-in-the-sky" → "Traffic in the Sky – Jack
/// Johnson") and the icon is the site's initial in a colour of its own.
///
/// In the text a mention is a Markdown link with the title "mention",
/// `[Traffic in the Sky – Jack Johnson](https://… "mention")`, so it stays
/// a plain link anywhere else the text goes.
enum LinkMention {
    static let marker = "mention"

    /// The text for a mention of `url`.
    static func token(url: String, title: String? = nil) -> String {
        let label = (title ?? self.title(for: url))
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
        return "[\(label)](\(url) \"\(marker)\")"
    }

    /// The site, as written in the address: "cifraclub.com.br".
    static func site(for url: String) -> String {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return url }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            return String(host.dropFirst(prefix.count))
        }
        return host
    }

    /// The letter on the site's icon.
    static func initial(for url: String) -> String {
        let site = site(for: url)
        return site.first.map { String($0).uppercased() } ?? "?"
    }

    /// One of eight colours, always the same for a site.
    static func colorIndex(for url: String) -> Int {
        var hash: UInt32 = 5381
        for byte in site(for: url).utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return Int(hash % 8)
    }

    /// A readable title from the address: its last two meaningful path parts,
    /// the last first, in title case; the site when there are none.
    static func title(for url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        let parts = components.path
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
            .map(stripExtension)
            .filter(isMeaningful)
        let picked = parts.suffix(2).reversed().map(words)
        guard !picked.isEmpty else { return site(for: url) }
        return picked.joined(separator: " \u{2013} ")
    }

    private static func stripExtension(_ part: String) -> String {
        for ext in [".html", ".htm", ".php", ".aspx", ".asp", ".jsp"] where part.lowercased().hasSuffix(ext) {
            return String(part.dropLast(ext.count))
        }
        return part
    }

    /// Not an id, a number, a language code or a generic page name.
    private static func isMeaningful(_ part: String) -> Bool {
        let lower = part.lowercased()
        guard part.count >= 2, !["index", "default", "home", "watch", "view", "post", "p", "en", "pt", "pt-br", "en-us", "br", "amp"].contains(lower) else { return false }
        let letters = part.filter(\.isLetter).count
        let digits = part.filter(\.isNumber).count
        guard letters > 0 else { return false }
        // "a1b2c3d4e5…": an id, not words.
        if part.count >= 12, !part.contains("-"), !part.contains("_"), digits * 3 >= part.count { return false }
        return true
    }

    private static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with", "vs",
        "de", "da", "do", "das", "dos", "e", "em", "na", "no", "nas", "nos", "um", "uma", "com", "por", "para",
    ]

    /// "traffic-in-the-sky" → "Traffic in the Sky".
    private static func words(_ part: String) -> String {
        let spaced = part.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
        let raw = spaced.split(separator: " ").map(String.init)
        return raw.enumerated().map { index, word in
            // A word with capitals of its own ("iPhone", "NASA") is kept.
            if word.contains(where: \.isUppercase) { return word }
            if index > 0, smallWords.contains(word) { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Links in the text

    enum Kind: Equatable {
        /// An address written out: `https://…`.
        case bare
        /// `[label](url)`.
        case link
        /// `[label](url "mention")`.
        case mention
    }

    struct Span: Equatable {
        var range: NSRange
        var kind: Kind
        var url: String
        var label: String
    }

    // swiftlint:disable force_try
    private static let mentionPattern = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\s]+) \"mention\"\\)")
    private static let linkPattern = try! NSRegularExpression(pattern: "!?\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    private static let barePattern = try! NSRegularExpression(pattern: "https?://[^\\s<>)\\]]+")
    // swiftlint:enable force_try

    /// The link the character at `index` belongs to, if any.
    static func span(at index: Int, in text: String) -> Span? {
        let ns = text as NSString
        guard index >= 0, index <= ns.length else { return nil }
        let line = ns.paragraphRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        let lineText = ns.substring(with: line)
        let local = NSRange(location: 0, length: (lineText as NSString).length)
        func absolute(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }
        func touches(_ r: NSRange) -> Bool { index >= r.location && index <= NSMaxRange(r) }
        var taken: [NSRange] = []
        for m in mentionPattern.matches(in: lineText, range: local) {
            let r = absolute(m.range)
            taken.append(m.range)
            if touches(r) {
                return Span(range: r, kind: .mention, url: (lineText as NSString).substring(with: m.range(at: 2)),
                            label: (lineText as NSString).substring(with: m.range(at: 1)))
            }
        }
        for m in linkPattern.matches(in: lineText, range: local) where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            taken.append(m.range)
            // An image or an attachment is not a link to open.
            guard (lineText as NSString).substring(with: m.range).first != "!" else { continue }
            let r = absolute(m.range)
            if touches(r) {
                return Span(range: r, kind: .link, url: (lineText as NSString).substring(with: m.range(at: 2)),
                            label: (lineText as NSString).substring(with: m.range(at: 1)))
            }
        }
        for m in barePattern.matches(in: lineText, range: local) where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let r = absolute(m.range)
            if touches(r) {
                let url = (lineText as NSString).substring(with: m.range)
                return Span(range: r, kind: .bare, url: url, label: url)
            }
        }
        return nil
    }

    /// The span shown as a mention (or, for a mention, as a plain link).
    static func converted(_ span: Span, toMention: Bool) -> String {
        if toMention {
            let label = span.kind == .link && span.label != span.url ? span.label : title(for: span.url)
            return token(url: span.url, title: label)
        }
        return "[\(span.label)](\(span.url))"
    }
}
