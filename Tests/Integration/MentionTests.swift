import AppKit
import CryptoKit

// MARK: - Links open on a click; addresses become mentions

@MainActor
func runMentionTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("mentions.sqlite"), key: SymmetricKey(size: .bits256))
    let url = "https://www.cifraclub.com.br/jack-johnson/traffic-in-the-sky/"
    let body = "- \(LinkMention.token(url: url))\nRead [the brief](https://example.com/brief) today\nhttps://example.org/notes"
    let note = try! store.create(title: "Songs", body: body)
    expect("mention: the preview reads its title", store.note(id: note.id)?.preview.hasPrefix("\u{2022} Traffic in the Sky") == true ? "yes" : store.note(id: note.id)?.preview, "yes")
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let view = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView,
          let layoutManager = view.layoutManager, let container = view.textContainer, let storage = view.textStorage else {
        expectTrue("mention: the editor is there", false)
        return
    }
    var opened: [URL] = []
    view.openURL = { opened.append($0) }
    view.offersMentionOnPaste = false
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    spin(0.05)

    // Drawn: the icon in the room the hidden "[" keeps, beside the title,
    // centred on its capitals and inside its line.
    var iconRange = NSRange()
    let open = (view.string as NSString).range(of: "[Traffic").location
    expectTrue("mention: the \"[\" carries the site", storage.attribute(MarkdownStyler.mentionKey, at: open, effectiveRange: &iconRange) as? String == url)
    if let icon = view.mentionIconRect(iconRange) {
        let titleStart = (view.string as NSString).range(of: "Traffic").location
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: titleStart, length: 1), actualCharacterRange: nil)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let letter = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        expectTrue("mention: the icon before the title", icon.maxX <= letter.minX)
        expectTrue("mention: inside its line", fragment.contains(icon))
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyphs.location).y
        let font = view.textFont(after: iconRange)
        expectTrue("mention: centred on the title's capitals", abs(icon.midY - (baseline - font.capHeight / 2)) <= 0.5)
        // A click on the icon or the title opens the address.
        for point in [NSPoint(x: icon.midX, y: icon.midY), NSPoint(x: letter.midX, y: letter.midY)] {
            view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        expect("mention: a click opens it", opened.map(\.absoluteString).joined(separator: ","), "\(url),\(url)")
    } else {
        expectTrue("mention: an icon is drawn", false)
    }
    expectTrue("mention: the markup is hidden", ((storage.attribute(.font, at: open, effectiveRange: nil) as? NSFont)?.pointSize ?? 14) < 1)

    // A plain link opens on a click too; ⌥-click puts the caret in it instead.
    opened = []
    let brief = (view.string as NSString).range(of: "brief").location + 1
    let briefGlyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: brief, length: 1), actualCharacterRange: nil)
    let briefBox = layoutManager.boundingRect(forGlyphRange: briefGlyph, in: container)
        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    let briefPoint = view.convert(NSPoint(x: briefBox.midX, y: briefBox.midY), to: nil)
    view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: briefPoint, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    expect("link: a click opens it", opened.first?.absoluteString, "https://example.com/brief")

    // The right click: Open Link, Copy Link and the other way to show it.
    let titles = view.linkMenuItems(at: NSPoint(x: briefBox.midX, y: briefBox.midY)).map(\.title)
    expectTrue("link: the right click offers Open, Copy and Show as Mention (\(titles))",
               titles == [L("Open Link"), L("Copy Link"), L("Show as Mention")])

    // Pasting an address: written out, then made a mention when chosen.
    let board = NSPasteboard(name: NSPasteboard.Name("keepnote-tests-\(UUID().uuidString)"))
    board.clearContents()
    board.setString("https://www.cifraclub.com.br/jack-johnson/crying-shame/", forType: .string)
    view.pasteSource = board
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    view.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    let start = view.selectedRange().location
    view.paste(nil)
    let pasted = NSRange(location: start, length: ("https://www.cifraclub.com.br/jack-johnson/crying-shame/" as NSString).length)
    expect("paste: the address goes in as it is", (view.string as NSString).substring(with: pasted), "https://www.cifraclub.com.br/jack-johnson/crying-shame/")
    view.makeMention(range: pasted)
    expectTrue("paste: chosen as a mention, it becomes one", view.string.hasSuffix("[Crying Shame \u{2013} Jack Johnson](https://www.cifraclub.com.br/jack-johnson/crying-shame/ \"mention\")"))
    window.flush()
    expectTrue("paste: saved", store.note(id: note.id)?.body.contains("Crying Shame") == true)
    expect("search: a mention's title is found", String(store.search("Crying Shame").count), "1")
    window.close()
}
