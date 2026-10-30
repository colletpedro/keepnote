import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A note, or a piece of one, on the clipboard in three forms at once, so
/// whatever it is pasted into takes the richest it understands:
///
/// - HTML, the Markdown drawn as HTML with each picture inside its `<img>` as
///   a `data:` address: what a browser, Obsidian and most editors read;
/// - RTFD, for Mail, Pages, TextEdit and Notes, with each picture an attachment;
/// - plain text, the Markdown, each picture a link to a file of its name.
///
/// The pictures' bytes travel in the clipboard itself; nothing is written to a
/// file, and an attachment in the text is only ever a line naming the hash.
enum NoteClipboard {
    struct Contents {
        var html: String
        var rtfd: Data
        var plain: String
    }

    /// One attachment of the text, found in the store.
    private struct Found {
        var info: AttachmentInfo
        var data: Data
        /// The name it travels under: its own, numbered when two share one.
        var name: String
        /// What HTML and RTFD carry: the picture itself, or a smaller copy of
        /// a very large one, under the name and type that copy has.
        var sent: (data: Data, mime: String, name: String)
    }

    /// The longest side, in pixels, a picture goes out at on the clipboard.
    static let maximumSide = 2560
    static let jpegQuality = 0.85

    /// Whether any pixel of `image` is not fully opaque. A channel that is
    /// all 255 — a screenshot saved as RGBA — does not count.
    private static func isTransparent(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }   // cannot tell: keep it lossless
        var index = 3
        while index < pixels.count {
            if pixels[index] != 255 { return true }
            index += 4
        }
        return false
    }

    /// `data` as it travels on the clipboard. A picture longer than
    /// `maximumSide` on its longer side is scaled to it and recompressed —
    /// JPEG at 0.85, or PNG when it has transparency; any other is returned
    /// as it is, as is one that cannot be read. The attachment itself is
    /// never touched.
    static func forClipboard(_ info: AttachmentInfo, _ data: Data, name: String) -> (data: Data, mime: String, name: String) {
        let original = (data, info.utType.preferredMIMEType ?? "application/octet-stream", name)
        guard info.isImage, max(info.pixelWidth, info.pixelHeight) > maximumSide,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumSide,
              ] as CFDictionary) else { return original }
        let hasAlpha = isTransparent(image)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return original }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return original }
        let stem = (name as NSString).deletingPathExtension
        return (output as Data, type.preferredMIMEType ?? "application/octet-stream", stem + "." + (type.preferredFilenameExtension ?? "png"))
    }

    // MARK: - Building

    static func contents(markdown: String, attachments: AttachmentSource) -> Contents {
        let found = resolve(markdown, attachments)
        let blocks = MarkdownBlocks.parse(markdown)
        let body = MarkdownHTML.render(blocks) { reference in
            htmlForAttachment(reference, found[reference.id])
        }
        return Contents(
            html: "<meta charset=\"utf-8\">\n" + body,
            rtfd: AttributedBuilder(found: found.mapValues { ($0.info, $0.sent.data, $0.sent.name) }).rtfd(for: blocks),
            plain: plainText(markdown, found)
        )
    }

    private static func resolve(_ markdown: String, _ source: AttachmentSource) -> [String: Found] {
        var found: [String: Found] = [:]
        var taken = Set<String>()
        for reference in AttachmentText.references(in: markdown) where found[reference.id] == nil {
            guard let (info, data) = source(reference.id) else { continue }
            let name = ExportNames.unique(ExportNames.fileName(info.fileName, fallback: L("Attachment")), taken: &taken)
            found[reference.id] = Found(info: info, data: data, name: name, sent: forClipboard(info, data, name: name))
        }
        return found
    }

    private static func htmlForAttachment(_ reference: AttachmentText.Reference, _ found: Found?) -> String {
        guard let found else { return "<p>\(MarkdownHTML.escape(words(for: reference)))</p>" }
        guard found.info.isImage else { return "<p>\(MarkdownHTML.escape(words(for: reference, name: found.info.name)))</p>" }
        let alt = reference.label.isEmpty ? found.name : reference.label
        return "<p><img src=\"data:\(found.sent.mime);base64,\(found.sent.data.base64EncodedString())\" alt=\"\(MarkdownHTML.escape(alt))\"></p>"
    }

    /// What stands in for an attachment that is not drawn: "[Image: a barn]".
    private static func words(for reference: AttachmentText.Reference, name: String? = nil) -> String {
        if reference.isImage {
            return "[" + (reference.label.isEmpty ? L("Image") : L("Image: %@", reference.label)) + "]"
        }
        let label = reference.label.isEmpty ? (name ?? L("Attachment")) : reference.label
        return "[" + L("File: %@", label) + "]"
    }

    /// The Markdown with each attachment line made a link to a file of its
    /// name — `![photo](photo.png)` — which is what lands in a plain-text
    /// field, ready to sit beside the pictures.
    private static func plainText(_ markdown: String, _ found: [String: Found]) -> String {
        let text = NSMutableString(string: markdown)
        for reference in AttachmentText.references(in: markdown).reversed() {
            let replacement: String
            if let item = found[reference.id], item.info.isImage {
                let stem = (item.name as NSString).deletingPathExtension
                replacement = "![\(stem)](\(ExportNames.linkTarget(item.name)))"
            } else {
                replacement = words(for: reference, name: found[reference.id]?.info.name)
            }
            text.replaceCharacters(in: reference.range, with: replacement)
        }
        return text as String
    }

    // MARK: - Writing

    /// Replaces what the pasteboard holds with `contents`.
    static func write(_ contents: Contents, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .rtfd, .string], owner: nil)
        pasteboard.setString(contents.html, forType: .html)
        pasteboard.setData(contents.rtfd, forType: .rtfd)
        pasteboard.setString(contents.plain, forType: .string)
    }

    static func copy(markdown: String, attachments: AttachmentSource, to pasteboard: NSPasteboard = .general) {
        write(contents(markdown: markdown, attachments: attachments), to: pasteboard)
    }

    /// The note as it is copied: its title as a heading, its tags as `#tag`
    /// and its text.
    static func copy(note: Note, attachments: AttachmentSource, to pasteboard: NSPasteboard = .general) {
        copy(markdown: ExportService.document(for: note), attachments: attachments, to: pasteboard)
    }

    /// `range` widened to take whole any attachment line it touches, so a
    /// selection that ends inside one still carries the picture.
    static func expanded(_ range: NSRange, in text: String) -> NSRange {
        var result = range
        for reference in AttachmentText.references(in: text) {
            let line = reference.range
            if NSIntersectionRange(line, range).length > 0 || (range.length == 0 && NSLocationInRange(range.location, line)) {
                result = NSUnionRange(result, line)
            }
        }
        return result
    }
}

// MARK: - Rich text

/// The blocks as an attributed string whose pictures are text attachments
/// holding the very bytes, written out as RTFD.
private struct AttributedBuilder {
    var found: [String: (info: AttachmentInfo, data: Data, name: String)]

    private struct Style {
        var size: CGFloat = 13
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var highlight = false
        var link: String?
    }

    func rtfd(for blocks: [MarkdownBlock]) -> Data {
        let text = NSMutableAttributedString()
        append(blocks, to: text, indent: 0, italic: false)
        while text.string.hasSuffix("\n\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) ?? Data()
    }

    private func font(_ style: Style) -> NSFont {
        let base = style.code
            ? NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: style.bold ? .bold : .regular)
            : NSFont.systemFont(ofSize: style.size, weight: style.bold ? .bold : .regular)
        guard style.italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: style.size) ?? base
    }

    private func attributes(_ style: Style, indent: CGFloat, spacing: CGFloat = 4) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = spacing
        var result: [NSAttributedString.Key: Any] = [.font: font(style), .paragraphStyle: paragraph]
        if style.strike { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.highlight { result[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.4) }
        if let link = style.link, MarkdownHTML.isFollowable(link), let url = URL(string: link) { result[.link] = url }
        return result
    }

    private func append(_ spans: [MarkdownSpan], style: Style, indent: CGFloat, to text: NSMutableAttributedString) {
        for span in spans {
            var inner = style
            switch span {
            case .text(let string):
                text.append(NSAttributedString(string: string, attributes: attributes(style, indent: indent)))
                continue
            case .code(let string):
                inner.code = true
                text.append(NSAttributedString(string: string, attributes: attributes(inner, indent: indent)))
                continue
            case .bold(let children): inner.bold = true; append(children, style: inner, indent: indent, to: text)
            case .italic(let children): inner.italic = true; append(children, style: inner, indent: indent, to: text)
            case .strike(let children): inner.strike = true; append(children, style: inner, indent: indent, to: text)
            case .highlight(let children): inner.highlight = true; append(children, style: inner, indent: indent, to: text)
            case .link(let children, let url): inner.link = url; append(children, style: inner, indent: indent, to: text)
            }
        }
    }

    private func line(_ text: NSMutableAttributedString, _ string: String, _ style: Style, indent: CGFloat) {
        text.append(NSAttributedString(string: string, attributes: attributes(style, indent: indent)))
    }

    private func append(_ blocks: [MarkdownBlock], to text: NSMutableAttributedString, indent: CGFloat, italic: Bool) {
        var base = Style()
        base.italic = italic
        for block in blocks {
            switch block {
            case .heading(let level, let spans):
                var style = base
                style.bold = true
                style.size = [22, 19, 16, 14, 13, 13][min(max(level, 1), 6) - 1]
                append(spans, style: style, indent: indent, to: text)
                line(text, "\n", style, indent: indent)
            case .paragraph(let lines):
                for (offset, spans) in lines.enumerated() {
                    append(spans, style: base, indent: indent, to: text)
                    line(text, offset == lines.count - 1 ? "\n" : "\u{2028}", base, indent: indent)
                }
            case .list(let list):
                append(list, to: text, indent: indent + 18, base: base)
            case .quote(let inner):
                append(inner, to: text, indent: indent + 16, italic: true)
            case .code(let code):
                var style = base
                style.code = true
                line(text, code + "\n", style, indent: indent + 8)
            case .rule:
                line(text, "\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\n", base, indent: indent)
            case .table(let header, let rows):
                for (offset, row) in ([header] + rows).enumerated() {
                    var style = base
                    style.bold = offset == 0
                    for (column, cell) in row.enumerated() {
                        if column > 0 { line(text, "\t", style, indent: indent) }
                        append(cell, style: style, indent: indent, to: text)
                    }
                    line(text, "\n", style, indent: indent)
                }
            case .attachment(let reference):
                appendAttachment(reference, to: text, style: base, indent: indent)
            }
        }
    }

    private func append(_ list: MarkdownList, to text: NSMutableAttributedString, indent: CGFloat, base: Style) {
        for (offset, item) in list.items.enumerated() {
            let marker: String
            if let done = item.task {
                marker = done ? "\u{2611} " : "\u{2610} "
            } else {
                marker = list.ordered ? "\(list.start + offset). " : "\u{2022} "
            }
            line(text, marker, base, indent: indent)
            append(item.spans, style: base, indent: indent, to: text)
            line(text, "\n", base, indent: indent)
            for sub in item.sublists { append(sub, to: text, indent: indent + 18, base: base) }
        }
    }

    private func appendAttachment(_ reference: AttachmentText.Reference, to text: NSMutableAttributedString, style: Style, indent: CGFloat) {
        guard let item = found[reference.id], item.info.isImage else {
            let words = reference.isImage
                ? "[" + (reference.label.isEmpty ? L("Image") : L("Image: %@", reference.label)) + "]"
                : "[" + L("File: %@", reference.label.isEmpty ? (found[reference.id]?.info.name ?? L("Attachment")) : reference.label) + "]"
            line(text, words + "\n", style, indent: indent)
            return
        }
        let wrapper = FileWrapper(regularFileWithContents: item.data)
        wrapper.preferredFilename = item.name
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let picture = NSMutableAttributedString(attachment: attachment)
        picture.addAttributes(attributes(style, indent: indent), range: NSRange(location: 0, length: picture.length))
        text.append(picture)
        line(text, "\n", style, indent: indent)
    }
}
