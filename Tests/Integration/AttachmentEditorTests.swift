import Quartz
import AppKit
import CryptoKit

/// A small PNG, `width` by `height` pixels, in one colour.
func samplePNG(width: Int = 400, height: Int = 200, color: NSColor = .systemTeal) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Images in the editor

@MainActor
func runAttachmentEditorTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("images.sqlite"), key: SymmetricKey(size: .bits256))
    let png = samplePNG(width: 2400, height: 1200)
    let info = try! store.addAttachment(png, name: "Screenshot.png")
    expectTrue("image: measured as an image", info.isImage && info.pixelWidth == 2400 && info.pixelHeight == 1200)
    expect("image: its type", info.type, "public.png")

    let token = AttachmentText.token(id: info.id, isImage: true, label: "A wide picture")
    let note = try! store.create(title: "Pictures", body: "Before\n\(token)\nAfter")
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView,
          let container = body.textContainer else {
        expectTrue("image: the editor is there", false)
        return
    }
    let layouts = body.allAttachmentLayouts
    expect("image: one drawn", String(layouts.count), "1")
    guard let layout = layouts.first, let rect = body.attachmentRect(layout) else { return }
    let room = container.size.width - 2 * container.lineFragmentPadding
    expectTrue("image: fitted to the note's width (\(rect.width) ≤ \(room))", rect.width <= room + 0.5 && rect.width > room - 1)
    expectTrue("image: its proportions kept", abs(rect.width / rect.height - 2) < 0.02)
    expectTrue("image: drawn as an image", layout.showsImage)
    expectTrue("image: inside its own line", {
        let glyphs = body.layoutManager!.glyphRange(forCharacterRange: layout.reference.range, actualCharacterRange: nil)
        let line = body.layoutManager!.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: body.textContainerOrigin.x, dy: body.textContainerOrigin.y)
        return line.contains(rect.insetBy(dx: -2, dy: -2)) || (line.minY <= rect.minY - 2 && line.maxY >= rect.maxY + 2)
    }())

    // Titles, labels and search do not see it.
    expect("image: the title is the note's", store.note(id: note.id)?.displayTitle, "Pictures")
    expect("image: the preview skips it", store.note(id: note.id)?.preview, "Before After")
    expect("image: search ignores its id", String(store.search(String(info.id.prefix(12))).count), "0")

    // A click selects it.
    body.select(layout)
    expectTrue("image: a click selects it", body.selectedAttachment === layout || body.selectedAttachment?.reference.id == info.id)

    // The caret never stands inside its line.
    let inside = layout.reference.range.location + 5
    body.setSelectedRange(NSRange(location: inside, length: 0))
    let caret = body.selectedRange().location
    expectTrue("image: the caret goes to an edge of it (\(caret))",
               caret == layout.reference.range.location || caret == NSMaxRange(layout.reference.range))

    // Typing at its end starts a new line; the attachment stays whole.
    body.setSelectedRange(NSRange(location: NSMaxRange(layout.reference.range), length: 0))
    body.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    expect("image: typing beside it starts a line", body.string, "Before\n\(token)\nx\nAfter")

    // Pasting a picture (a screenshot on the clipboard): read from a private
    // pasteboard so the real clipboard is left alone.
    let board = NSPasteboard(name: NSPasteboard.Name("keepnote-tests-\(UUID().uuidString)"))
    board.clearContents()
    board.setData(samplePNG(width: 300, height: 300, color: .systemPink), forType: .png)
    let pasted = MarkdownTextView.candidates(from: board)
    expect("paste: a picture on the clipboard is one image", String(pasted.count), "1")
    body.setSelectedRange(NSRange(location: 6, length: 0))   // end of "Before"
    body.insertAttachments(pasted, at: body.selectedRange())
    spin(0.1)
    let refs = AttachmentText.references(in: body.string)
    expect("paste: on a line of its own", String(refs.count), "2")
    expectTrue("paste: right after the line it was pasted on", body.string.hasPrefix("Before\n!["))
    expect("paste: kept in the store", String(store.attachments.count), "2")

    // A file dragged from the Finder.
    let file = scratchDirectory().appendingPathComponent("Plan.png")
    try! samplePNG(width: 64, height: 64, color: .systemGreen).write(to: file)
    let dragged = NSPasteboard(name: NSPasteboard.Name("keepnote-tests-\(UUID().uuidString)"))
    dragged.clearContents()
    dragged.writeObjects([file as NSURL])
    let fromFinder = MarkdownTextView.candidates(from: dragged)
    expect("drag: a file from the Finder", fromFinder.first?.name, "Plan.png")
    expectTrue("drag: can be dropped", MarkdownTextView.canAttach(from: dragged))

    // Remove takes the line away, line break and all.
    if let first = body.allAttachmentLayouts.first {
        let before = body.string
        body.removeAttachment(first)
        expectTrue("remove: one line fewer", body.string.components(separatedBy: "\n").count
                   == before.components(separatedBy: "\n").count - 1)
    }

    // The Tools menu offers Insert Image….
    let menu = FormatCommand.makeToolsMenu(target: body)
    expectTrue("tools: Insert Image…", menu.items.contains { $0.title == L("Insert Image\u{2026}") })

    // The right click on an image: Open, Save As…, Edit Description…, Remove.
    if let layout = body.allAttachmentLayouts.first {
        let titles = body.menu(for: layout).items.map(\.title)
        for wanted in [L("Open"), L("Quick Look"), L("Save As\u{2026}"), L("Edit Description\u{2026}"), L("Remove")] {
            expectTrue("menu: \(wanted)", titles.contains(wanted))
        }
    }

    // Everything typed reached the note.
    window.flush()
    expectTrue("image: the text is saved", AttachmentText.references(in: store.note(id: note.id)!.body).count == 1)
    window.close()
}

// MARK: - Files as cards

@MainActor
func runAttachmentCardTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("cards.sqlite"), key: SymmetricKey(size: .bits256))
    let bytes = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let info = try! store.addAttachment(bytes, name: "Invoice October.pdf", type: .pdf)
    expectTrue("card: a PDF is a file, not an image", !info.isImage)
    expect("card: its size, as the Finder writes it", info.sizeText, ByteCountFormatter.string(fromByteCount: 150_000, countStyle: .file))
    let token = AttachmentText.token(id: info.id, isImage: false, label: info.name)
    let note = try! store.create(title: "Bills", body: "\(token)\nPay by Friday")
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView,
          let layout = body.allAttachmentLayouts.first, let rect = body.attachmentRect(layout) else {
        expectTrue("card: drawn", false)
        return
    }
    expectTrue("card: drawn as a card", !layout.showsImage)
    expectTrue("card: a fixed height (\(rect.height))", abs(rect.height - 46) < 0.5)
    let labels = body.attachmentElements().map { $0.accessibilityLabel() ?? "" }
    expect("card: VoiceOver hears its name and size", labels.first, "File, Invoice October.pdf, \(info.sizeText)")
    expectTrue("card: VoiceOver hears a button", body.attachmentElements().first?.accessibilityRole() == .button)

    // Open and Quick Look use a copy in the container's temporary folder.
    let copy = store.temporaryFile(for: info.id)
    expect("card: the copy has the file's name", copy?.lastPathComponent, "Invoice October.pdf")
    expectTrue("card: inside the container's temporary folder", copy?.path.hasPrefix(NoteStore.temporaryFolder.path) == true)
    expectTrue("card: with the bytes", copy.flatMap { try? Data(contentsOf: $0) } == bytes)
    NoteStore.removeTemporaryFiles()
    expectTrue("card: the copies are cleared", copy.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

    // Space on the selected card: Quick Look is pointed at the copy.
    body.select(layout)
    expectTrue("card: selected", body.selectedAttachment != nil)
    body.quickLook(layout)
    expect("card: Quick Look shows the copy", body.quickLookURL?.lastPathComponent, "Invoice October.pdf")
    QLPreviewPanel.shared()?.orderOut(nil)
    body.endPreviewPanelControl(QLPreviewPanel.shared())
    expectTrue("card: Quick Look let go of the note", !NoteFocusHold.isHolding)

    // A card for a file this Mac does not have yet.
    let unknown = String(repeating: "c", count: 64)
    body.string = "[Later.zip](attachment:\(unknown))"
    body.didChangeText()
    spin(0.1)
    let waiting = body.allAttachmentLayouts.first
    expectTrue("card: a file still to arrive is a card", waiting != nil && waiting?.info == nil)
    expect("card: and says so", body.attachmentElements().first?.accessibilityLabel(), "File, Later.zip, not on this Mac yet")

    // Attach File… is in Tools.
    expectTrue("tools: Attach File…", FormatCommand.makeToolsMenu(target: body).items.contains { $0.title == L("Attach File\u{2026}") })
    window.close()
}
