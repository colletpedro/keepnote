import AppKit
import Quartz
import UniformTypeIdentifiers

/// Panels and alerts a note puts up for itself (Save As…, Insert Image…, Edit
/// Description…, Quick Look) take the keyboard from the note's window; while
/// one is up, an anchored note must not take that as a click elsewhere.
@MainActor
enum NoteFocusHold {
    private(set) static var depth = 0
    static var isHolding: Bool { depth > 0 }

    static func during<T>(_ body: () throws -> T) rethrows -> T {
        depth += 1
        defer { depth -= 1 }
        return try body()
    }

    static func begin() { depth += 1 }
    static func end() { depth = max(0, depth - 1) }
}

/// One file to attach, read from a drop, the clipboard or a panel.
struct AttachmentCandidate {
    var data: Data
    var name: String
    var type: UTType?
    /// Seen to be too large before it was read: its size.
    var oversize: Int?
}

// MARK: - Drawing

extension MarkdownTextView {
    /// Every attachment line laid out in `characters`.
    func attachmentLayouts(in characters: NSRange) -> [AttachmentLayout] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let range = NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))
        var found: [AttachmentLayout] = []
        storage.enumerateAttribute(MarkdownStyler.attachmentKey, in: range) { value, _, _ in
            if let layout = value as? AttachmentLayout, !found.contains(where: { $0 === layout }) { found.append(layout) }
        }
        return found
    }

    var allAttachmentLayouts: [AttachmentLayout] {
        attachmentLayouts(in: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    /// Where an attachment is drawn, in view coordinates.
    func attachmentRect(_ layout: AttachmentLayout) -> NSRect? {
        guard let layoutManager, let container = textContainer,
              NSMaxRange(layout.reference.range) <= (textStorage?.length ?? 0) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: layout.reference.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(
            x: origin.x + line.minX + container.lineFragmentPadding,
            y: origin.y + line.minY + AttachmentLayout.inset,
            width: layout.size.width,
            height: layout.size.height
        )
    }

    func isSelected(_ layout: AttachmentLayout) -> Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        return NSIntersectionRange(selection, layout.reference.range).length == layout.reference.range.length
    }

    func drawAttachment(_ layout: AttachmentLayout) {
        guard let rect = attachmentRect(layout) else { return }
        let radius = AttachmentLayout.cornerRadius
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if layout.showsImage, let image = library?.attachmentImage(layout.reference.id) {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            // A hairline, so a white image keeps its edge on white paper.
            inkColor.withAlphaComponent(0.12).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        } else {
            drawCard(layout, in: rect)
        }
        if isSelected(layout) {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2)
            ring.lineWidth = 2.5
            accentColor.setStroke()
            ring.stroke()
        }
    }

    /// A file: its icon, name and size on a quiet card.
    private func drawCard(_ layout: AttachmentLayout, in rect: NSRect) {
        let radius = AttachmentLayout.cornerRadius
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        inkColor.withAlphaComponent(0.05).setFill()
        card.fill()
        inkColor.withAlphaComponent(0.18).setStroke()
        card.lineWidth = 1
        card.stroke()

        let scale = rect.height / 46
        let iconSide = (30 * scale).rounded()
        let iconRect = NSRect(x: rect.minX + (8 * scale).rounded(), y: rect.midY - iconSide / 2, width: iconSide, height: iconSide)
        let info = layout.info
        let icon: NSImage = {
            if let info { return NSWorkspace.shared.icon(for: info.utType) }
            return NSWorkspace.shared.icon(for: layout.reference.isImage ? .image : .data)
        }()
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: info == nil ? 0.5 : 1,
                  respectFlipped: true, hints: nil)

        let name = layout.reference.isImage
            ? (layout.reference.label.isEmpty ? (info?.name ?? L("Image")) : layout.reference.label)
            : (layout.reference.label.isEmpty ? (info?.name ?? L("Attachment")) : layout.reference.label)
        let detail = info.map(\.sizeText) ?? L("Not on this Mac yet")
        let textX = iconRect.maxX + (8 * scale).rounded()
        let textWidth = max(10, rect.maxX - textX - (10 * scale).rounded())
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: (12.5 * scale).rounded(.toNearestOrEven), weight: .semibold),
            .foregroundColor: inkColor, .paragraphStyle: paragraph,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11 * scale),
            .foregroundColor: inkColor.withAlphaComponent(0.62), .paragraphStyle: paragraph,
        ]
        let nameFont = nameAttributes[.font] as! NSFont
        let detailFont = detailAttributes[.font] as! NSFont
        let nameHeight = ceil(nameFont.ascender - nameFont.descender)
        let detailHeight = ceil(detailFont.ascender - detailFont.descender)
        let gap: CGFloat = 1
        let top = rect.midY - (nameHeight + gap + detailHeight) / 2
        (name as NSString).draw(with: NSRect(x: textX, y: top, width: textWidth, height: nameHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttributes)
        (detail as NSString).draw(with: NSRect(x: textX, y: top + nameHeight + gap, width: textWidth, height: detailHeight),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: detailAttributes)
    }

    /// The attachment under `point`, if any.
    func attachment(at point: NSPoint) -> AttachmentLayout? {
        allAttachmentLayouts.first { attachmentRect($0)?.insetBy(dx: -2, dy: -2).contains(point) == true }
    }

    /// The attachment the selection is exactly on.
    var selectedAttachment: AttachmentLayout? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        return attachmentLayouts(in: selection).first(where: isSelected)
    }

    /// The attachment line a caret position touches (at its start or end).
    func attachmentLine(touching location: Int) -> AttachmentLayout? {
        let probe = NSRange(location: max(0, location - 1), length: 2)
        return attachmentLayouts(in: probe).first {
            location == $0.reference.range.location || location == NSMaxRange($0.reference.range)
        }
    }
}

// MARK: - Actions

extension MarkdownTextView {
    /// Selects the attachment, as a click on it does.
    func select(_ layout: AttachmentLayout) {
        window?.makeFirstResponder(self)
        setSelectedRange(layout.reference.range)
        needsDisplay = true
    }

    func openAttachment(_ layout: AttachmentLayout) {
        guard let url = library?.temporaryFile(for: layout.reference.id) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    func quickLook(_ layout: AttachmentLayout) {
        guard let url = library?.temporaryFile(for: layout.reference.id) else { NSSound.beep(); return }
        quickLookURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        NoteFocusHold.begin()
        quickLookHolding = true
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func saveAttachmentAs(_ layout: AttachmentLayout) {
        guard let library, let info = layout.info, let data = library.attachmentData(info.id) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = info.fileName
        panel.canCreateDirectories = true
        guard NoteFocusHold.during({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NoteFocusHold.during { _ = NSAlert(error: error).runModal() }
        }
    }

    func removeAttachment(_ layout: AttachmentLayout) {
        let text = string as NSString
        var range = layout.reference.range
        // The line goes with its line break.
        if NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 0x0A {
            range.length += 1
        } else if range.location > 0, text.character(at: range.location - 1) == 0x0A {
            range.location -= 1
            range.length += 1
        }
        replaceText(range, with: "")
        setSelectedRange(NSRange(location: min(range.location, (string as NSString).length), length: 0))
    }

    /// Edit Description…: what VoiceOver reads for the image.
    func editDescription(_ layout: AttachmentLayout) {
        let alert = NSAlert()
        alert.messageText = L("Image Description")
        alert.informativeText = L("Describe the image for VoiceOver and for anyone who cannot see it.")
        let field = NSTextField(string: layout.reference.label)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = L("Description")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard NoteFocusHold.during({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = AttachmentText.token(id: layout.reference.id, isImage: true, label: label)
        replaceText(layout.reference.range, with: token)
        setSelectedRange(NSRange(location: layout.reference.range.location, length: (token as NSString).length))
    }

    /// The menu of an attachment, on the right click.
    func menu(for layout: AttachmentLayout) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget(action)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        let available = layout.info != nil
        add(L("Open")) { [weak self] in self?.openAttachment(layout) }
        add(L("Quick Look")) { [weak self] in self?.quickLook(layout) }
        add(L("Save As\u{2026}")) { [weak self] in self?.saveAttachmentAs(layout) }
        if !available { menu.items.forEach { $0.isEnabled = false } }
        if layout.reference.isImage && isEditable {
            menu.addItem(.separator())
            add(L("Edit Description\u{2026}")) { [weak self] in self?.editDescription(layout) }
        }
        if isEditable {
            menu.addItem(.separator())
            add(L("Remove")) { [weak self] in self?.removeAttachment(layout) }
        }
        menu.autoenablesItems = false
        return menu
    }

    // MARK: Adding

    /// Insert Image… in Tools: one or more pictures from a panel.
    @objc func insertImage(_ sender: Any?) {
        guard isEditable else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("Insert")
        panel.message = L("Choose the images to put in the note.")
        guard NoteFocusHold.during({ panel.runModal() }) == .OK else { return }
        let candidates = panel.urls.compactMap(Self.candidate(fromFile:))
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        insertAttachments(candidates, at: selectedRange())
    }

    static func candidate(fromFile url: URL) -> AttachmentCandidate? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Too large is said, not read: the bytes would only be refused.
        if size > AttachmentText.maximumSize {
            return AttachmentCandidate(data: Data(), name: url.lastPathComponent, type: nil, oversize: size)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return AttachmentCandidate(data: data, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
    }

    /// What a pasteboard holds that can become attachments: files, then
    /// image data (a screenshot copied to the clipboard, an image dragged
    /// out of a browser). Nothing is fetched: a web image comes with its
    /// pixels, and only those are used.
    static func candidates(from pasteboard: NSPasteboard) -> [AttachmentCandidate] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls.compactMap(candidate(fromFile:)) }
        if let png = pasteboard.data(forType: .png) {
            return [AttachmentCandidate(data: png, name: L("Image") + ".png", type: .png)]
        }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [AttachmentCandidate(data: png, name: L("Image") + ".png", type: .png)]
        }
        return []
    }

    static func canAttach(from pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if types.contains(.png) || types.contains(.tiff) { return true }
        return !(pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) ?? []).isEmpty
    }

    /// Adds the files to the store and their lines to the text at `range`,
    /// each on a line of its own, as one change Undo takes back. What cannot
    /// be added (more than 25 MB) is said in one alert.
    func insertAttachments(_ candidates: [AttachmentCandidate], at range: NSRange) {
        guard isEditable, let library, !candidates.isEmpty else { return }
        var tokens: [String] = []
        var problems: [String] = []
        for candidate in candidates {
            do {
                if let size = candidate.oversize { throw AttachmentError.tooLarge(name: candidate.name, size: size) }
                let info = try library.addAttachment(candidate.data, name: candidate.name, type: candidate.type)
                let label = info.isImage ? "" : info.name
                tokens.append(AttachmentText.token(id: info.id, isImage: info.isImage, label: label))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !tokens.isEmpty {
            let length = (string as NSString).length
            let safe = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
            let insertion = AttachmentText.insertion(of: tokens, in: string, at: safe)
            replaceText(safe, with: insertion.text)
            setSelectedRange(NSRange(location: min(safe.location + insertion.caret, (string as NSString).length), length: 0))
            Announcer.say(Lplural(tokens.count, L("1 attachment added"), L("%d attachments added")))
        }
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Lplural(problems.count, L("1 file was not attached"), L("%d files were not attached"))
            alert.informativeText = problems.joined(separator: "\n") + "\n\n"
                + L("Make it smaller, or keep it in a folder and add a link to it instead.")
            NoteFocusHold.during { _ = alert.runModal() }
        }
    }

    /// File promises (a browser's image, Photos): received into the
    /// container's temporary folder, then attached at `range`.
    func receivePromises(_ receivers: [NSFilePromiseReceiver], at range: NSRange) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if error == nil { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let candidates = urls.compactMap(Self.candidate(fromFile:))
            self?.insertAttachments(candidates, at: range)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// A menu item's action as a closure, kept alive by the item.
final class ClosureMenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

// MARK: - Quick Look

extension MarkdownTextView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookURL = nil
        if quickLookHolding {
            quickLookHolding = false
            NoteFocusHold.end()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL as NSURL?
    }

    /// Space in Quick Look closes it again, as in the Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == " " {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}
