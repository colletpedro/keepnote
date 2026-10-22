import AppKit
import CryptoKit

/// Links: a hand and "Click to open · ⌥-click to edit" over them, nothing elsewhere; a
/// file's card gets the hand too.
@MainActor
func runLinkHoverTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("links.sqlite"), key: SymmetricKey(size: .bits256))
    let file = try! store.addAttachment(Data(repeating: 9, count: 2000), name: "Menu.pdf", type: .pdf)
    let note = try! store.create(title: "Links", body: "Read [the guide](https://example.com/guide) today\n"
                                 + AttachmentText.token(id: file.id, isImage: false, label: "Menu.pdf"))
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView,
          let layoutManager = body.layoutManager, let container = body.textContainer else {
        expectTrue("hover: the editor is there", false)
        return
    }
    // Away from the caret, so the link's markup is hidden as it is at rest.
    body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
    func point(ofCharacter index: Int) -> NSPoint {
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return NSPoint(x: rect.midX + body.textContainerOrigin.x, y: rect.midY + body.textContainerOrigin.y)
    }
    let linkIndex = (body.string as NSString).range(of: "guide").location + 2
    let onLink = point(ofCharacter: linkIndex)
    expect("hover: over a link, the hint", body.hoverHint(at: onLink), "Click to open \u{00B7} \u{2325}-click to edit")
    expectTrue("hover: over a link, a hand", body.hoverCursor(at: onLink) === NSCursor.pointingHand)
    let onText = point(ofCharacter: 1)
    expectTrue("hover: over plain text, no hint", body.hoverHint(at: onText) == nil)
    expectTrue("hover: over plain text, the I-beam stays", body.hoverCursor(at: onText) == nil)
    let pastEnd = NSPoint(x: container.size.width - 4, y: onLink.y)
    expectTrue("hover: past the end of the line, no hint", body.hoverHint(at: pastEnd) == nil)
    if let card = body.allAttachmentLayouts.first, let rect = body.attachmentRect(card) {
        expectTrue("hover: over a file's card, a hand", body.hoverCursor(at: NSPoint(x: rect.midX, y: rect.midY)) === NSCursor.pointingHand)
    }
    expect("hover: in Portuguese", L("Click to open \u{00B7} \u{2325}-click to edit", in: "pt-BR"), "Clique para abrir \u{00B7} \u{2325}-clique para editar")
    window.close()
}

/// No code that could reach the network: links open in the browser, images
/// dragged from a browser bring their own pixels.
func runNoNetworkSourceTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    var found: [String] = []
    for file in sources {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for needle in ["URLSession", "NSURLConnection", "WKWebView", "CFNetwork", "Network.framework", "NWConnection"]
        where text.contains(needle) {
            found.append("\(file.lastPathComponent): \(needle)")
        }
    }
    expect("network: nothing in the app can make a request", found.joined(separator: "\n"), "")
    let entitlements = (try? String(contentsOf: root.appendingPathComponent("Resources/KeepNote.entitlements"), encoding: .utf8)) ?? ""
    expectTrue("network: no network entitlement", !entitlements.contains("<key>com.apple.security.network"))
}
