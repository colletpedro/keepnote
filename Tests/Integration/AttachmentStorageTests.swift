import AppKit
import CryptoKit

// MARK: - Attachments: kept, carried and cleaned up

@MainActor
func runAttachmentStorageTests() {
    let key = SymmetricKey(size: .bits256)
    let png = samplePNG(width: 320, height: 160)
    let pdf = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) })

    // Round trip through the database, sealed.
    do {
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        var store: NoteStore? = reopened(url, key: key)
        let image = try! store!.addAttachment(png, name: "Chart.png")
        let file = try! store!.addAttachment(pdf, name: "Report.pdf", type: .pdf)
        _ = try! store!.create(title: "Both", body: AttachmentText.token(id: image.id, isImage: true, label: "")
                               + "\n" + AttachmentText.token(id: file.id, isImage: false, label: "Report.pdf"))
        store!.waitUntilSaved()
        store = nil
        let raw = try! Data(contentsOf: url)
        expectTrue("storage: the bytes are sealed in the database", raw.range(of: pdf.prefix(64)) == nil)
        let again = reopened(url, key: key)
        expect("storage: both come back", String(again.attachments.count), "2")
        expectTrue("storage: the image's bytes are the same", again.attachmentData(image.id) == png)
        expectTrue("storage: the file's too", again.attachmentData(file.id) == pdf)
        expect("storage: with its name", again.attachments[file.id]?.name, "Report.pdf")
        expectTrue("storage: and its pixel size", again.attachments[image.id]?.pixelWidth == 320)
        // Another Mac's key opens nothing.
        let foreign = reopened(url, key: SymmetricKey(size: .bits256))
        expectTrue("storage: another key cannot open them", foreign.attachmentData(file.id) == nil)
    }

    // The same bytes twice are one attachment.
    do {
        let store = reopened(scratchDirectory().appendingPathComponent("dedup.sqlite"), key: key)
        let first = try! store.addAttachment(png, name: "One.png")
        let second = try! store.addAttachment(png, name: "Copy of one.png")
        expect("dedup: the same id", second.id, first.id)
        expect("dedup: kept once", String(store.attachments.count), "1")
        store.waitUntilSaved()
        let rows = try! SQLiteDatabase(readOnlyPath: scratch.last!.appendingPathComponent("dedup.sqlite").path)
            .scalarInt("SELECT count(*) FROM attachments;")
        expect("dedup: one row on disk", String(rows), "1")
        let other = try! store.addAttachment(samplePNG(width: 320, height: 160, color: .systemRed), name: "Two.png")
        expectTrue("dedup: different bytes, another one", other.id != first.id)
    }

    // 25 MB at most.
    do {
        let store = reopened(scratchDirectory().appendingPathComponent("limit.sqlite"), key: key)
        let tooBig = Data(count: AttachmentText.maximumSize + 1)
        var refused: Error?
        do { try store.addAttachment(tooBig, name: "Movie.mov") } catch { refused = error }
        expectTrue("limit: over 25 MB is refused", (refused as? AttachmentError) == .tooLarge(name: "Movie.mov", size: AttachmentText.maximumSize + 1))
        expectTrue("limit: and says so clearly (\(refused?.localizedDescription ?? ""))",
                   refused?.localizedDescription.contains("25 MB") == true && refused?.localizedDescription.contains("Movie.mov") == true)
        expect("limit: nothing kept", String(store.attachments.count), "0")
        let atLimit = Data(repeating: 1, count: AttachmentText.maximumSize)
        expectTrue("limit: exactly 25 MB is fine", (try? store.addAttachment(atLimit, name: "Big.bin")) != nil)
        // A file too large is refused before it is read.
        let file = scratchDirectory().appendingPathComponent("Huge.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.truncate(atOffset: UInt64(AttachmentText.maximumSize + 10))
        try! handle.close()
        expect("limit: seen from the file's size", MarkdownTextView.candidate(fromFile: file)?.oversize.map(String.init),
               String(AttachmentText.maximumSize + 10))
    }

    // Orphans: an attachment no note refers to goes once its note is deleted for good.
    do {
        let store = reopened(scratchDirectory().appendingPathComponent("orphans.sqlite"), key: key)
        let shared = try! store.addAttachment(png, name: "Shared.png")
        let alone = try! store.addAttachment(pdf, name: "Alone.pdf", type: .pdf)
        let a = try! store.create(title: "A", body: AttachmentText.token(id: shared.id, isImage: true, label: "")
                                  + "\n" + AttachmentText.token(id: alone.id, isImage: false, label: "Alone.pdf"))
        _ = try! store.create(title: "B", body: AttachmentText.token(id: shared.id, isImage: true, label: ""))
        try! store.delete(id: a.id)
        expect("orphans: kept while the delete can be undone", String(store.attachments.count), "2")
        try! store.purge(id: a.id)
        expectTrue("orphans: its own file goes", store.attachments[alone.id] == nil)
        expectTrue("orphans: one another note has stays", store.attachments[shared.id] != nil)
        store.waitUntilSaved()
        expectTrue("orphans: gone from the database too", reopened(scratch.last!.appendingPathComponent("orphans.sqlite"), key: key).attachments[alone.id] == nil)
        // Nothing is removed while a note cannot be read.
        let lockedURL = scratchDirectory().appendingPathComponent("locked.sqlite")
        var owner: NoteStore? = reopened(lockedURL, key: key)
        let kept = try! owner!.addAttachment(pdf, name: "Kept.pdf", type: .pdf)
        _ = try! owner!.create(title: "Mine", body: AttachmentText.token(id: kept.id, isImage: false, label: "Kept.pdf"))
        owner!.waitUntilSaved()
        owner = nil
        let other = reopened(lockedURL, key: SymmetricKey(size: .bits256))
        expectTrue("orphans: not while a note is locked", other.attachments[kept.id] != nil && other.removeOrphanAttachments().isEmpty)
    }

    // Sync: two Macs, one folder.
    do {
        let folder = scratchDirectory().appendingPathComponent("Sync", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let macA = reopened(scratchDirectory().appendingPathComponent("a.sqlite"), key: SymmetricKey(size: .bits256))
        let macB = reopened(scratchDirectory().appendingPathComponent("b.sqlite"), key: SymmetricKey(size: .bits256))
        let syncA = FolderSyncService(store: macA, folder: folder)
        let syncB = FolderSyncService(store: macB, folder: folder)
        spin(0.3)
        let info = try! macA.addAttachment(png, name: "Map.png")
        let note = try! macA.create(title: "Trip", body: "Route\n" + AttachmentText.token(id: info.id, isImage: true, label: "The route"))
        syncA.waitUntilWritten()
        let copy = folder.appendingPathComponent("Attachments/\(info.id).png")
        expectTrue("sync: a plain copy beside the notes", (try? Data(contentsOf: copy)) == png)
        // The folder keeps its name, exactly, so folders that exist keep working.
        let syncEntries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        expectTrue("sync: the folder is still called Attachments, not attachments",
                   syncEntries.contains("Attachments") && !syncEntries.contains("attachments"))
        expectTrue("sync: the note's file is there", noteFile(in: folder, id: note.id) != nil)
        for _ in 0..<40 where macB.attachments[info.id] == nil { spin(0.1) }
        expect("sync: the other Mac has the note", macB.note(id: note.id)?.title, "Trip")
        expectTrue("sync: and the image, byte for byte", macB.attachmentData(info.id) == png)
        expectTrue("sync: sealed with its own key", macB.attachments[info.id]?.isImage == true)
        // A copy whose bytes do not match its name is not taken.
        let liar = String(repeating: "d", count: 64)
        try! png.write(to: folder.appendingPathComponent("Attachments/\(liar).png"))
        try! macA.setBody("Route\n" + AttachmentText.token(id: liar, isImage: true, label: ""), id: note.id)
        syncA.waitUntilWritten()
        spin(1)
        syncB.importMissingAttachments()
        syncB.waitUntilWritten()
        spin(0.3)
        expectTrue("sync: a file that is not what it says is refused", macB.attachments[liar] == nil)
        withExtendedLifetime((syncA, syncB)) {}
    }

    // Archive: the files go along, in a folder the text names.
    do {
        let store = reopened(scratchDirectory().appendingPathComponent("arch.sqlite"), key: key)
        let image = try! store.addAttachment(png, name: "Chart.png")
        let file = try! store.addAttachment(pdf, name: "Report.pdf", type: .pdf)
        let note = try! store.create(title: "Quarter", body: "Numbers\n" + AttachmentText.token(id: image.id, isImage: true, label: "Sales")
                                     + "\n" + AttachmentText.token(id: file.id, isImage: false, label: "Report.pdf"))
        let plain = try! store.create(title: "Plain", body: "no files")
        let source: AttachmentSource = { id in store.attachments[id].flatMap { info in store.attachmentData(id).map { (info, $0) } } }
        let out = scratchDirectory()
        let archive = out.appendingPathComponent("Export.hmnotearchive")
        try! NoteArchive.write(notes: [store.note(id: note.id)!, plain], dailyTemplate: nil, attachments: source, to: archive)
        expectTrue("archive: its folder is still called Attachments",
                   ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []).contains("Attachments"))
        let files = NoteArchive.readAttachments(in: archive.appendingPathComponent("Attachments"))
        expect("archive: a package with both files", String(files.count), "2")
        expectTrue("archive: named as the text names them", files[image.id]?.lastPathComponent == "\(image.id).png")
        // Read back into a new Mac.
        let elsewhere = reopened(scratchDirectory().appendingPathComponent("elsewhere.sqlite"), key: SymmetricKey(size: .bits256))
        let result = try! NoteImporter.importContents(of: archive, into: elsewhere)
        expect("archive: both notes come in", String(result.applied), "2")
        expectTrue("archive: with the image", elsewhere.attachmentData(image.id) == png)
        expectTrue("archive: and the file", elsewhere.attachmentData(file.id) == pdf)
        expect("archive: the file keeps its name", elsewhere.attachments[file.id]?.name, "Report.pdf")
        // Without attachments it stays one JSON file, as before.
        let flat = out.appendingPathComponent("Flat.hmnotearchive")
        try! NoteArchive.write(notes: [plain], dailyTemplate: nil, attachments: source, to: flat)
        var isDirectory: ObjCBool = true
        FileManager.default.fileExists(atPath: flat.path, isDirectory: &isDirectory)
        expectTrue("archive: no attachments, one file", !isDirectory.boolValue)

        // Markdown export: the files beside the notes, linked.
        let exportFolder = scratchDirectory()
        try! ExportService.writePerNote(notes: [store.note(id: note.id)!], format: .markdownPerNote, into: exportFolder, attachments: source)
        let markdown = try! String(contentsOf: exportFolder.appendingPathComponent("Quarter.md"), encoding: .utf8)
        expectTrue("export: the image is linked from the text", markdown.contains("![Sales](attachments/Chart.png)"))
        expectTrue("export: the file too", markdown.contains("[Report.pdf](attachments/Report.pdf)"))
        expectTrue("export: the image is written there", (try? Data(contentsOf: exportFolder.appendingPathComponent("attachments/Chart.png"))) == png)
        expectTrue("export: and the file", (try? Data(contentsOf: exportFolder.appendingPathComponent("attachments/Report.pdf"))) == pdf)
        expectTrue("export: no attachment ids left in the text", !markdown.contains("attachment:"))
        // No name starts with a dot, in files or in attachments.
        let hidden = try! store.addAttachment(samplePNG(width: 9, height: 9, color: .systemPurple), name: ".secret.png")
        let dotted = try! store.create(title: "..", body: "x\n" + AttachmentText.token(id: hidden.id, isImage: true, label: "s"))
        let dotFolder = scratchDirectory()
        try! ExportService.writePerNote(notes: [store.note(id: dotted.id)!, store.note(id: plain.id)!, store.note(id: plain.id)!],
                                        format: .markdownPerNote, into: dotFolder, attachments: source)
        let dotNames = (try? FileManager.default.contentsOfDirectory(atPath: dotFolder.path)) ?? []
        expectTrue("export: no file name starts with a dot", !dotNames.isEmpty && dotNames.allSatisfy { !$0.hasPrefix(".") })
        expectTrue("export: a repeated title is numbered", dotNames.contains("Plain.md") && dotNames.contains("Plain 2.md"))
        expectTrue("export: an attachment named with a dot is written without it",
                   (try? Data(contentsOf: dotFolder.appendingPathComponent("attachments/secret.png"))) != nil)
        // Plain text says what was there.
        let text = ExportService.plainText(for: store.note(id: note.id)!)
        expectTrue("export: plain text names the image", text.contains("[" + L("Image: %@", "Sales") + "]"))
        expectTrue("export: and the file", text.contains("[" + L("File: %@", "Report.pdf") + "]"))
    }

    // Backup and restore carry the attachments.
    do {
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        var store: NoteStore? = reopened(url, key: key)
        let info = try! store!.addAttachment(pdf, name: "Lease.pdf", type: .pdf)
        let id = try! store!.create(title: "Flat", body: AttachmentText.token(id: info.id, isImage: false, label: "Lease.pdf")).id
        let backup = try! store!.backUp(kind: .manual)
        try! store!.setBody("lease removed", id: id)
        store!.removeOrphanAttachments()
        store!.waitUntilSaved()
        expectTrue("backup: the file went with its line", store!.attachments[info.id] == nil)
        store = nil
        try! Backups.restore(backup.url, to: url)
        let restored = reopened(url, key: key)
        expectTrue("backup: restored, the note has its file again", restored.attachmentData(info.id) == pdf)
        expect("backup: and its line", AttachmentText.references(in: restored.note(id: id)!.body).first?.id, info.id)
    }
}
