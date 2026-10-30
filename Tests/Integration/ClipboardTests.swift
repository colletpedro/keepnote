import AppKit
import CryptoKit

/// Copying a note, or part of one, with its pictures, and Export as Markdown….

/// What the three formats on a pasteboard hold.
private struct Pasted {
    var html: String
    var plain: String
    var pictures: [Data]   // from the RTFD, in order

    @MainActor
    init(_ board: NSPasteboard) {
        html = board.string(forType: .html) ?? ""
        plain = board.string(forType: .string) ?? ""
        pictures = []
        if let data = board.data(forType: .rtfd), let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let wrapper = (value as? NSTextAttachment)?.fileWrapper, let bytes = wrapper.regularFileContents {
                    pictures.append(bytes)
                }
            }
        }
    }

    /// The bytes of every `data:` image in the HTML.
    var htmlPictures: [Data] {
        var found: [Data] = []
        var rest = Substring(html)
        while let start = rest.range(of: ";base64,") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            if let data = Data(base64Encoded: String(rest[..<end])) { found.append(data) }
            rest = rest[end...]
        }
        return found
    }
}

@MainActor
private func privateBoard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("keepnote-tests-\(UUID().uuidString)"))
    board.clearContents()
    return board
}

@MainActor
func runClipboardTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("clipboard.sqlite"), key: SymmetricKey(size: .bits256))
    let barn = samplePNG(width: 300, height: 200, color: .systemRed)
    let sky = samplePNG(width: 120, height: 90, color: .systemBlue)
    let barnInfo = try! store.addAttachment(barn, name: "Barn.png")
    let skyInfo = try! store.addAttachment(sky, name: "Barn.png")   // another picture, the same name
    let report = Data("%PDF-1.4 not really".utf8)
    let reportInfo = try! store.addAttachment(report, name: "Report.pdf")
    let source: AttachmentSource = { id in
        guard let info = store.attachments[id], let data = store.attachmentData(id) else { return nil }
        return (info, data)
    }

    let barnLine = AttachmentText.token(id: barnInfo.id, isImage: true, label: "A red barn")
    let skyLine = AttachmentText.token(id: skyInfo.id, isImage: true, label: "")
    let fileLine = AttachmentText.token(id: reportInfo.id, isImage: false, label: "Report.pdf")
    let markdown = """
        # Farm visit
        Some **bold** and a [link](https://example.com).
        - [x] seen
        - [ ] photographed
        \(barnLine)
        between
        \(skyLine)
        \(barnLine)
        \(fileLine)
        """

    // MARK: Every format holds the pictures

    let board = privateBoard()
    NoteClipboard.copy(markdown: markdown, attachments: source, to: board)
    let pasted = Pasted(board)
    expectTrue("clip: the three formats are there", Set(board.types ?? []).isSuperset(of: [.html, .rtfd, .string]))
    expectTrue("clip: HTML has a title", pasted.html.contains("<h1>Farm visit</h1>"))
    expectTrue("clip: HTML has bold and the link",
               pasted.html.contains("<strong>bold</strong>") && pasted.html.contains("<a href=\"https://example.com\">link</a>"))
    expectTrue("clip: HTML has its tasks",
               pasted.html.contains("<input type=\"checkbox\" disabled checked> seen")
                && pasted.html.contains("<input type=\"checkbox\" disabled> photographed"))
    expect("clip: HTML has an image for each picture line", String(pasted.htmlPictures.count), "3")
    expectTrue("clip: HTML pictures are the originals, byte for byte", pasted.htmlPictures == [barn, sky, barn])
    expectTrue("clip: HTML names their type", pasted.html.contains("src=\"data:image/png;base64,"))
    expectTrue("clip: HTML says what the picture is", pasted.html.contains("alt=\"A red barn\""))
    expectTrue("clip: HTML leaves the attachment hash out", !pasted.html.contains("attachment:"))
    expect("clip: RTFD has an attachment for each picture", String(pasted.pictures.count), "3")
    expectTrue("clip: RTFD pictures are the originals, byte for byte", pasted.pictures == [barn, sky, barn])
    expectTrue("clip: plain text is Markdown with the picture's name",
               pasted.plain.contains("![Barn](Barn.png)"))
    expectTrue("clip: two pictures called alike do not share a name", pasted.plain.contains("![Barn 2](Barn%202.png)"))
    expectTrue("clip: the same picture twice keeps its name", pasted.plain.components(separatedBy: "![Barn](Barn.png)").count == 3)
    expectTrue("clip: plain text keeps the Markdown", pasted.plain.contains("**bold**") && pasted.plain.contains("- [x] seen"))
    expectTrue("clip: plain text names the file", pasted.plain.contains("[" + L("File: %@", "Report.pdf") + "]"))
    expectTrue("clip: and has no hash", !pasted.plain.contains("attachment:"))

    // A picture the store lost is said in words, in every format.
    let lost = AttachmentText.token(id: String(repeating: "c", count: 64), isImage: true, label: "Gone")
    let lostBoard = privateBoard()
    NoteClipboard.copy(markdown: "x\n\(lost)\ny", attachments: source, to: lostBoard)
    let lostPasted = Pasted(lostBoard)
    expectTrue("clip: a missing picture is words in plain text", lostPasted.plain.contains("[" + L("Image: %@", "Gone") + "]"))
    expectTrue("clip: and in HTML", lostPasted.html.contains("[" + L("Image: %@", "Gone") + "]") && !lostPasted.html.contains("<img"))
    expect("clip: and no picture in RTFD", String(lostPasted.pictures.count), "0")

    // A note with no pictures: the same text, nothing added.
    let plainNote = try! store.create(title: "Shopping", body: "milk\n- eggs\n- [ ] bread")
    try! store.update(id: plainNote.id) { $0.tags = ["home", "weekly"] }
    let plainBoard = privateBoard()
    NoteClipboard.copy(note: store.note(id: plainNote.id)!, attachments: source, to: plainBoard)
    let plainPasted = Pasted(plainBoard)
    expect("clip: no pictures, the Markdown as it is", plainPasted.plain, "# Shopping\n\n#home #weekly\n\nmilk\n- eggs\n- [ ] bread")
    expectTrue("clip: no pictures, no <img>", !plainPasted.html.contains("<img"))
    expect("clip: no pictures, none in RTFD", String(plainPasted.pictures.count), "0")
    expectTrue("clip: the RTFD still reads", (plainBoard.data(forType: .rtfd).flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) }?.string ?? "").contains("bread"))

    // Hostile text stays text.
    let hostile = privateBoard()
    NoteClipboard.copy(markdown: "<script>alert(1)</script> [x](javascript:alert(1))", attachments: source, to: hostile)
    let hostileHTML = Pasted(hostile).html
    expectTrue("clip: markup in a note is escaped", !hostileHTML.contains("<script>") && hostileHTML.contains("&lt;script&gt;"))
    expectTrue("clip: a script link is not a link", !hostileHTML.contains("javascript:"))

    // MARK: Copying a piece of the text

    let note = try! store.create(title: "Pieces", body: "Intro text\n\(barnLine)\nmiddle\n\(skyLine)\nend")
    let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
    window.window.contentView?.layoutSubtreeIfNeeded()
    spin(0.2)
    guard let body = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView else {
        expectTrue("clip: the editor is there", false)
        return
    }
    let target = privateBoard()
    body.copyTarget = target
    let text = body.string as NSString

    // Only the second picture and the line before it.
    let middle = text.range(of: "middle")
    let second = text.range(of: skyLine)
    body.setSelectedRange(NSRange(location: middle.location, length: NSMaxRange(second) - middle.location))
    body.copy(nil)
    let piece = Pasted(target)
    expect("copy: a piece with one picture carries one", String(piece.pictures.count), "1")
    expectTrue("copy: it is that picture", piece.pictures == [sky] && piece.htmlPictures == [sky])
    expectTrue("copy: and its words", piece.plain.hasPrefix("middle\n![") && piece.html.contains("middle"))
    expectTrue("copy: not the other picture or the text outside", !piece.plain.contains("Intro") && !piece.plain.contains("end"))

    // A selection that stops inside a picture's line takes the whole line.
    let first = text.range(of: barnLine)
    let board3 = privateBoard()
    body.copyTarget = board3
    body.setSelectedRange(NSRange(location: first.location + 4, length: 10))
    body.copy(nil)
    expectTrue("copy: part of a picture's line is the picture", Pasted(board3).pictures == [barn])

    // The whole text: both pictures, in order.
    let board4 = privateBoard()
    body.copyTarget = board4
    body.selectAll(nil)
    body.copy(nil)
    expectTrue("copy: everything has both pictures", Pasted(board4).pictures == [barn, sky])

    // A piece with no picture is copied as it always was: nothing of ours
    // on the private board, the text on the system's.
    let untouched = privateBoard()
    body.copyTarget = untouched
    let saved = snapshot(NSPasteboard.general)
    let intro = text.range(of: "Intro text")
    body.setSelectedRange(intro)
    body.copy(nil)
    expectTrue("copy: no picture, nothing of ours written", (untouched.types ?? []).isEmpty)
    expect("copy: no picture, the plain copy", NSPasteboard.general.string(forType: .string), "Intro text")
    expectTrue("copy: no picture, no picture format", NSPasteboard.general.data(forType: .rtfd) == nil || Pasted(NSPasteboard.general).pictures.isEmpty)
    restore(saved, to: NSPasteboard.general)

    // Cut takes the lines out and keeps the pictures.
    let cutBoard = privateBoard()
    body.copyTarget = cutBoard
    let before = body.string
    let line = (before as NSString).range(of: skyLine)
    body.setSelectedRange(line)
    body.cut(nil)
    expectTrue("cut: the picture is on the clipboard", Pasted(cutBoard).pictures == [sky])
    expectTrue("cut: and gone from the text", !body.string.contains(skyInfo.id))
    expectTrue("cut: the rest stays", body.string.contains("Intro text") && body.string.contains(barnInfo.id))
    window.close()

    // MARK: Export as Markdown…

    let work = store.createGroup(name: "Work \"main\"")!
    let trip = try! store.create(title: "Trip", body: "Start\n\(barnLine)\nthen\n\(skyLine)\nand\n\(barnLine)\n\(fileLine)")
    try! store.update(id: trip.id) { $0.tags = ["travel", "2026"]; $0.groupID = work.id }
    let trip2 = try! store.create(title: "Trip", body: "Second trip\n\(skyLine)")
    let trip3 = try! store.create(title: "trip", body: "No pictures")
    let odd = try! store.create(title: "a/b: c? \"d\" #e [f]", body: "odd")
    let dots = try! store.create(title: "..", body: "dots")
    let empty = try! store.create(title: "", body: "Only a body")
    let notes = [trip, trip2, trip3, odd, dots, empty].map { store.note(id: $0.id)! }

    let out = scratchDirectory()
    let folders = try! ExportService.writeMarkdownFolders(notes: notes, into: out, groups: store.groups, attachments: source)
    let names = folders.map(\.lastPathComponent)
    expect("export: one folder per note, each its own", Set(names).count == notes.count ? "unique" : "collision", "unique")
    expect("export: repeated names are numbered", names.prefix(3).joined(separator: "|"), "Trip|Trip 2|trip 3")
    expectTrue("export: nothing climbs out of the folder", names.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") && !$0.isEmpty })
    expect("export: illegal characters are replaced", names[3], "a-b- c- -d- -e -f-")
    expectTrue("export: a name of dots gets a stand-in", names[4] == L("Untitled") || !names[4].hasPrefix("."))
    expect("export: a note with no title is named by its text", names[5], "Only a body")
    expect("export: nothing else was written beside them", String((try! FileManager.default.contentsOfDirectory(atPath: out.path)).count), String(notes.count))

    // Each note is its folder's .md; its pictures are in attachments/.
    let tripFolder = folders[0]
    let tripMarkdown = try! String(contentsOf: tripFolder.appendingPathComponent("Trip.md"), encoding: .utf8)
    expectTrue("export: front matter says the group",
               tripMarkdown.hasPrefix("---\ngroup: \"Work \\\"main\\\"\"\n---\n\n"))
    expectTrue("export: the title and the tags as #tag", tripMarkdown.contains("# Trip\n\n#travel #2026\n\nStart"))
    expectTrue("export: no attachment hashes", !tripMarkdown.contains("attachment:"))
    expect("export: the first picture", String(tripMarkdown.components(separatedBy: "![A red barn](attachments/Barn.png)").count - 1), "2")
    expectTrue("export: the second, its name numbered", tripMarkdown.contains("![](attachments/Barn%202.png)"))
    expectTrue("export: the file too", tripMarkdown.contains("[Report.pdf](attachments/Report.pdf)"))
    let attachments = tripFolder.appendingPathComponent("attachments")
    expectTrue("export: attachments/ holds the picture, byte for byte", (try? Data(contentsOf: attachments.appendingPathComponent("Barn.png"))) == barn)
    expectTrue("export: and the other one", (try? Data(contentsOf: attachments.appendingPathComponent("Barn 2.png"))) == sky)
    expectTrue("export: and the file", (try? Data(contentsOf: attachments.appendingPathComponent("Report.pdf"))) == report)
    expect("export: each file once", String((try! FileManager.default.contentsOfDirectory(atPath: attachments.path)).count), "3")

    // Every link in every exported note points at a file that is there.
    var checked = 0
    for folder in folders {
        let name = folder.lastPathComponent
        let markdownURL = folder.appendingPathComponent(name + ".md")
        guard let written = try? String(contentsOf: markdownURL, encoding: .utf8) else {
            expectTrue("export: \(name) has its .md", false)
            continue
        }
        for target in linkTargets(in: written) where !target.hasPrefix("http") {
            checked += 1
            let decoded = target.removingPercentEncoding ?? target
            let url = folder.appendingPathComponent(decoded)
            expectTrue("export: \(name) links to \(decoded), which exists", FileManager.default.fileExists(atPath: url.path))
            expectTrue("export: and stays inside its folder", url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))
        }
    }
    expectTrue("export: the links were checked (\(checked))", checked == 5)

    let two = try! String(contentsOf: folders[1].appendingPathComponent("Trip 2.md"), encoding: .utf8)
    expectTrue("export: no group, no front matter", !two.hasPrefix("---"))
    expectTrue("export: another note's picture under its own name", two.contains("![](attachments/Barn.png)"))
    expectTrue("export: a note without pictures has no attachments folder",
               !FileManager.default.fileExists(atPath: folders[2].appendingPathComponent("attachments").path))

    // Exporting again beside the first: numbered, nothing overwritten.
    let again = try! ExportService.writeMarkdownFolders(notes: [notes[0]], into: out, groups: store.groups, attachments: source)
    expect("export: a second time is a new folder", again.first?.lastPathComponent, "Trip 4")
    expectTrue("export: the first is as it was", (try? String(contentsOf: tripFolder.appendingPathComponent("Trip.md"), encoding: .utf8)) == tripMarkdown)

    // One note, one pass: the same.
    let single = scratchDirectory()
    let oneFolder = try! ExportService.writeMarkdownFolders(notes: [notes[1]], into: single, groups: store.groups, attachments: source)
    expect("export: a single note", oneFolder.map(\.lastPathComponent).joined(), "Trip")
    expectTrue("export: with its picture", (try? Data(contentsOf: oneFolder[0].appendingPathComponent("attachments/Barn.png"))) == sky)
}

/// The targets of the Markdown links and images in `text`.
private func linkTargets(in text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
    let ns = text as NSString
    return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}

@MainActor
private func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
    (board.pasteboardItems ?? []).map { item in
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
        return types
    }
}

@MainActor
private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
    board.clearContents()
    for entry in saved {
        let item = NSPasteboardItem()
        for (type, data) in entry { item.setData(data, forType: type) }
        board.writeObjects([item])
    }
}
