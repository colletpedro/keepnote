import Foundation

/// The attachment lines in a note's text.
func runAttachmentTextTests() {
    let id = String(repeating: "0123456789abcdef", count: 4)
    let other = String(repeating: "f", count: 64)
    let image = AttachmentText.token(id: id, isImage: true, label: "A red barn")
    let file = AttachmentText.token(id: other, isImage: false, label: "Invoice [final].pdf")
    expect("attach: an image's line", image, "![A red barn](attachment:\(id))")
    expect("attach: a file's line, brackets kept out of the name", file, "[Invoice (final).pdf](attachment:\(other))")

    let text = "Intro\n\(image)\nmiddle\n  \(file)  \nend"
    let refs = AttachmentText.references(in: text)
    expect("attach: both found", String(refs.count), "2")
    expect("attach: the image is an image", String(refs.first?.isImage ?? false), "true")
    expect("attach: its description", refs.first?.label, "A red barn")
    expect("attach: the file is not", String(refs.last?.isImage ?? true), "false")
    expect("attach: the file's name", refs.last?.label, "Invoice (final).pdf")
    expect("attach: ids, each once", AttachmentText.ids(in: text + "\n" + image).sorted().joined(separator: ","), [id, other].sorted().joined(separator: ","))
    expect("attach: the line's range", (text as NSString).substring(with: refs[0].range), image)

    // Only a line of its own is an attachment.
    expect("attach: inside a sentence it is not one", String(AttachmentText.references(in: "see \(image) here").count), "0")
    expect("attach: a short id is not one", String(AttachmentText.references(in: "![x](attachment:abc)").count), "0")
    expect("attach: an ordinary link is not one", String(AttachmentText.references(in: "[a](https://example.com)").count), "0")

    // Display and search leave them out.
    expect("attach: removed for display", AttachmentText.removingReferences(from: text), "Intro\nmiddle\nend")
    expect("attach: text without any is untouched", AttachmentText.removingReferences(from: "a\nb"), "a\nb")

    // Inserting: always a line of its own, the caret after it.
    func insert(_ before: String, at location: Int) -> String {
        let result = AttachmentText.insertion(of: ["T"], in: before, at: NSRange(location: location, length: 0))
        let ns = before as NSString
        let after = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: result.text) as NSString
        return after.replacingCharacters(in: NSRange(location: location + result.caret, length: 0), with: "|")
    }
    expect("insert: in an empty note", insert("", at: 0), "T\n|")
    expect("insert: mid-line, broken around it", insert("abcd", at: 2), "ab\nT\n|cd")
    expect("insert: at a line's end", insert("ab\ncd", at: 2), "ab\nT\n|cd")
    expect("insert: at a line's start", insert("ab\ncd", at: 3), "ab\nT\n|cd")
    expect("insert: at the end", insert("ab", at: 2), "ab\nT\n|")

    // Edit Description….
    let relabeled = AttachmentText.relabel(refs[0], to: "A barn at dusk", in: text)
    expect("describe: the line takes the new description", AttachmentText.references(in: relabeled).first?.label, "A barn at dusk")
    expect("describe: nothing else changes", AttachmentText.removingReferences(from: relabeled), "Intro\nmiddle\nend")

    expect("attach: 25 MB at most", String(AttachmentText.maximumSize), String(25 * 1024 * 1024))
    expect("a11y: an image with a description", AccessibilityText.attachment(isImage: true, label: "A barn", name: nil, size: nil), "Image, A barn")
    expect("a11y: an image without one", AccessibilityText.attachment(isImage: true, label: " ", name: "x.png", size: nil), "Image, no description")
    expect("a11y: a file, name and size", AccessibilityText.attachment(isImage: false, label: "Invoice.pdf", name: "Invoice.pdf", size: "1.2 MB"), "File, Invoice.pdf, 1.2 MB")
}
