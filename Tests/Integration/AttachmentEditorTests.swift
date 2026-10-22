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
    expect("card: its size, as the Finder writes it", info.sizeText, Lbytes(150_000))
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

// MARK: - Where else attachments show

@MainActor
func runAttachmentDisplayTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("display.sqlite"), key: SymmetricKey(size: .bits256))
    let picture = try! store.addAttachment(samplePNG(width: 600, height: 300), name: "Beach.png")
    let file = try! store.addAttachment(Data(repeating: 3, count: 4000), name: "Ticket.pdf", type: .pdf)
    let body = AttachmentText.token(id: file.id, isImage: false, label: "Ticket.pdf") + "\n"
        + AttachmentText.token(id: picture.id, isImage: true, label: "") + "\nPack the bag"
    let untitled = try! store.create(title: "", body: body)
    let plain = try! store.create(title: "Plain", body: "no files")
    let note = store.note(id: untitled.id)!

    expectTrue("list: a note with attachments is marked", note.hasAttachments)
    expectTrue("list: one without is not", !store.note(id: plain.id)!.hasAttachments)
    expect("labels: the title skips the attachments", note.displayTitle, "Pack the bag")
    expect("labels: the deck's label too", note.spineLabel, "Pack the bag")
    expect("search: a file's name is not searched as text", String(store.search("Ticket").count), "0")
    expect("search: the text still is", String(store.search("bag").count), "1")

    // The peek shows the first image, small.
    let provider: (Note) -> NSImage? = { note in
        AttachmentText.references(in: note.body).lazy.filter(\.isImage).compactMap { store.attachmentImage($0.id) }.first
    }
    let thumbnail = provider(note)
    expectTrue("peek: the first image", thumbnail != nil && thumbnail!.size.width == 300)
    expectTrue("peek: none for a note without", provider(store.note(id: plain.id)!) == nil)
}

// MARK: - Attachments with VoiceOver

@MainActor
func runAttachmentAccessibilityTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("a11y.sqlite"), key: SymmetricKey(size: .bits256))
    let picture = try! store.addAttachment(samplePNG(width: 200, height: 100), name: "Barn.png")
    let file = try! store.addAttachment(Data(repeating: 5, count: 3000), name: "Deed.pdf", type: .pdf)
    let note = try! store.create(title: "Farm", body: AttachmentText.token(id: picture.id, isImage: true, label: "A red barn")
                                 + "\n" + AttachmentText.token(id: file.id, isImage: false, label: "Deed.pdf"))
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView else {
        expectTrue("a11y: the editor is there", false)
        return
    }
    let elements = body.attachmentElements()
    expect("a11y: both are elements", String(elements.count), "2")
    expect("a11y: the image reads its description", elements.first?.accessibilityLabel(), "Image, A red barn")
    expectTrue("a11y: as an image", elements.first?.accessibilityRole() == .image)
    expect("a11y: the file reads its name and size", elements.last?.accessibilityLabel(), "File, Deed.pdf, \(file.sizeText)")
    let imageActions = elements.first?.accessibilityCustomActions()?.map(\.name) ?? []
    expectTrue("a11y: Edit Description… among the image's actions (\(imageActions))", imageActions.contains(L("Edit Description\u{2026}")))
    expectTrue("a11y: and Remove", imageActions.contains(L("Remove")))
    let fileActions = elements.last?.accessibilityCustomActions()?.map(\.name) ?? []
    expectTrue("a11y: a file has no description to edit", !fileActions.contains(L("Edit Description\u{2026}")))
    // Remove through VoiceOver's action.
    if let remove = elements.last?.accessibilityCustomActions()?.first(where: { $0.name == L("Remove") }) {
        _ = remove.handler?()
        expect("a11y: VoiceOver's Remove takes the file out", String(AttachmentText.references(in: body.string).count), "1")
    }
    // The description is the image's tooltip; a card says a click opens it.
    if let image = body.allAttachmentLayouts.first {
        expect("a11y: the description as a tooltip", body.attachmentHint(image), "A red barn")
    }
    // Edit Description… changes the line's description, which is what is read.
    if let image = body.allAttachmentLayouts.first {
        body.replaceText(image.reference.range, with: AttachmentText.token(id: picture.id, isImage: true, label: "A barn at dusk"))
        spin(0.05)
        expect("a11y: a new description is read", body.attachmentElements().first?.accessibilityLabel(), "Image, A barn at dusk")
    }
    window.close()
}

// MARK: - ⌘V with a picture on the clipboard

@MainActor
func runPasteImageTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("paste.sqlite"), key: SymmetricKey(size: .bits256))
    let note = try! store.create(title: "Paste", body: "Before")
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView else {
        expectTrue("paste: the editor is there", false)
        return
    }
    let board = NSPasteboard(name: NSPasteboard.Name("keepnote-tests-\(UUID().uuidString)"))
    body.pasteSource = board
    let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    func paste(_ fill: () -> Void) {
        board.clearContents()
        fill()
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.paste(nil)
        spin(0.05)
    }

    // A screenshot: a picture and nothing else.
    board.clearContents()
    board.setData(samplePNG(width: 200, height: 100), forType: .png)
    expectTrue("paste: Paste is enabled with only a picture on the clipboard", body.validateUserInterfaceItem(pasteItem))
    paste { board.setData(samplePNG(width: 200, height: 100), forType: .png) }
    expect("paste: a screenshot becomes an image", String(AttachmentText.references(in: body.string).filter(\.isImage).count), "1")

    // A picture copied in a browser: TIFF and its address.
    paste {
        let tiff = NSImage(data: samplePNG(width: 120, height: 90, color: .systemOrange))!.tiffRepresentation!
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(tiff, forType: .tiff)
        board.setString("https://example.com/photo.jpg", forType: .string)
    }
    expect("paste: an image copied in a browser becomes an image too", String(AttachmentText.references(in: body.string).count), "2")

    // Text from a document that carries a picture of itself: text.
    paste {
        board.declareTypes([.string, .tiff], owner: nil)
        board.setString("Plain words", forType: .string)
        board.setData(NSImage(data: samplePNG())!.tiffRepresentation!, forType: .tiff)
    }
    expectTrue("paste: copied text stays text", body.string.hasSuffix("Plain words"))
    expect("paste: and adds no image", String(AttachmentText.references(in: body.string).count), "2")
    window.flush()
    expectTrue("paste: the images are saved with the note", AttachmentText.references(in: store.note(id: note.id)!.body).count == 2)
    window.close()
}
