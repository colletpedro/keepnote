import Foundation

/// Markdown as HTML, for the clipboard.
///
/// `attachment` gives the HTML for an attachment line (an `<img>` with the
/// picture inside it, say); the rest is drawn from the blocks. Everything the
/// note wrote is escaped, and a link only keeps its address when it is one a
/// paste should follow.
enum MarkdownHTML {
    static func render(_ markdown: String, attachment: (AttachmentText.Reference) -> String) -> String {
        render(MarkdownBlocks.parse(markdown), attachment: attachment)
    }

    static func render(_ blocks: [MarkdownBlock], attachment: (AttachmentText.Reference) -> String) -> String {
        blocks.map { block(for: $0, attachment: attachment) }.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func block(for block: MarkdownBlock, attachment: (AttachmentText.Reference) -> String) -> String {
        switch block {
        case .heading(let level, let spans):
            let tag = "h\(min(max(level, 1), 6))"
            return "<\(tag)>\(inline(spans))</\(tag)>"
        case .paragraph(let lines):
            return "<p>" + lines.map(inline).joined(separator: "<br>") + "</p>"
        case .list(let list):
            return listHTML(list)
        case .quote(let inner):
            return "<blockquote>\n" + render(inner, attachment: attachment) + "\n</blockquote>"
        case .code(let code):
            return "<pre><code>\(escape(code))</code></pre>"
        case .rule:
            return "<hr>"
        case .table(let header, let rows):
            var html = "<table>\n<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
            for row in rows { html += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n" }
            return html + "</tbody>\n</table>"
        case .attachment(let reference):
            return attachment(reference)
        }
    }

    private static func listHTML(_ list: MarkdownList) -> String {
        let tag = list.ordered ? "ol" : "ul"
        let start = list.ordered && list.start != 1 ? " start=\"\(list.start)\"" : ""
        var html = "<\(tag)\(start)>\n"
        for item in list.items {
            html += "<li>"
            if let done = item.task {
                html += "<input type=\"checkbox\" disabled\(done ? " checked" : "")> "
            }
            html += inline(item.spans)
            for sub in item.sublists { html += "\n" + listHTML(sub) }
            html += "</li>\n"
        }
        return html + "</\(tag)>"
    }

    static func inline(_ spans: [MarkdownSpan]) -> String {
        spans.map { span in
            switch span {
            case .text(let text): return escape(text)
            case .code(let code): return "<code>\(escape(code))</code>"
            case .bold(let inner): return "<strong>\(inline(inner))</strong>"
            case .italic(let inner): return "<em>\(inline(inner))</em>"
            case .strike(let inner): return "<s>\(inline(inner))</s>"
            case .highlight(let inner): return "<mark>\(inline(inner))</mark>"
            case .link(let inner, let url):
                guard isFollowable(url) else { return inline(inner) }
                return "<a href=\"\(escape(url))\">\(inline(inner))</a>"
            }
        }.joined()
    }

    /// Web, mail and phone addresses, and relative or in-page ones; never a
    /// script or a data address.
    static func isFollowable(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        guard let colon = trimmed.firstIndex(of: ":") else { return true }
        if let slash = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }), slash < colon { return true }
        return ["http", "https", "mailto", "tel"].contains(String(trimmed[..<colon]))
    }
}
