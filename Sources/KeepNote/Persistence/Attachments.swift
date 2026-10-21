import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// What the store knows about one attachment without opening it.
struct AttachmentInfo: Equatable, Sendable {
    /// The SHA-256 of the bytes, lower-case hex: also the name the text uses.
    let id: String
    /// The file's name when it was added: what a card shows, and what Save
    /// As… and Open start from.
    var name: String
    /// Its type, as a UTType identifier.
    var type: String
    var size: Int
    /// In pixels; zero for anything that is not an image.
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date

    var isImage: Bool { pixelWidth > 0 && pixelHeight > 0 }

    var utType: UTType { UTType(type) ?? .data }

    /// The name with an extension, for a file written out of the note.
    var fileName: String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? L("Attachment") : base
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}")
        var cleaned = safe.components(separatedBy: illegal).joined(separator: "-")
        if (cleaned as NSString).pathExtension.isEmpty, let ext = utType.preferredFilenameExtension {
            cleaned += "." + ext
        }
        return cleaned
    }

    /// The extension a plain copy of it is written with.
    var fileExtension: String {
        let fromName = (name as NSString).pathExtension
        if !fromName.isEmpty { return fromName.lowercased() }
        return utType.preferredFilenameExtension ?? "bin"
    }

    /// "1.2 MB".
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

enum AttachmentError: LocalizedError, Equatable {
    case tooLarge(name: String, size: Int)
    case unreadable(name: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let size):
            return L("\u{201C}%@\u{201D} is %@, more than the 25 MB an attachment can be.", name,
                     ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        case .unreadable(let name):
            return L("\u{201C}%@\u{201D} could not be read.", name)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .tooLarge: return L("Make it smaller, or keep it in a folder and add a link to it instead.")
        case .unreadable: return nil
        }
    }
}

extension AttachmentInfo {
    /// The info for `data`, measured: its hash, size and, for an image, its
    /// pixel size.
    static func measure(_ data: Data, name: String, type: UTType?, now: Date) -> AttachmentInfo {
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var width = 0
        var height = 0
        var resolved = type
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int,
           let h = properties[kCGImagePropertyPixelHeight] as? Int {
            // A PDF reads as an image too; it stays a file, shown as a card.
            let sourceType = CGImageSourceGetType(source).map { $0 as String }
            let isPDF = sourceType == UTType.pdf.identifier || type?.conforms(to: .pdf) == true
            if !isPDF {
                width = w
                height = h
                if resolved == nil, let sourceType { resolved = UTType(sourceType) }
            }
        }
        if resolved == nil, !(name as NSString).pathExtension.isEmpty {
            resolved = UTType(filenameExtension: (name as NSString).pathExtension)
        }
        return AttachmentInfo(
            id: id, name: name, type: (resolved ?? .data).identifier, size: data.count,
            pixelWidth: width, pixelHeight: height, createdAt: now
        )
    }
}

// MARK: - The store

extension NoteStore {
    /// Adds a file and returns what the text should refer to. The same bytes
    /// added again — in this note or another — are the attachment already
    /// there. More than 25 MB is refused with `AttachmentError.tooLarge`.
    @discardableResult
    func addAttachment(_ data: Data, name: String, type: UTType? = nil) throws -> AttachmentInfo {
        guard data.count <= AttachmentText.maximumSize else {
            throw AttachmentError.tooLarge(name: name, size: data.count)
        }
        guard !data.isEmpty else { throw AttachmentError.unreadable(name: name) }
        let info = AttachmentInfo.measure(data, name: name, type: type, now: Date())
        if let existing = attachments[info.id] { return existing }
        attachments[info.id] = info
        attachmentCache.setObject(data as NSData, forKey: info.id as NSString)
        writer.save([.attachment(info, data)])
        NotificationCenter.default.post(name: .keepNoteAttachmentsChanged, object: self)
        return info
    }

    /// An attachment that arrived from elsewhere (the sync folder, an
    /// archive) with its bytes: kept only if the bytes are what its name
    /// says they are.
    @discardableResult
    func receiveAttachment(_ data: Data, id: String, name: String, type: UTType? = nil) -> AttachmentInfo? {
        guard attachments[id] == nil else { return attachments[id] }
        guard data.count <= AttachmentText.maximumSize else { return nil }
        let info = AttachmentInfo.measure(data, name: name, type: type, now: Date())
        guard info.id == id else { return nil }
        attachments[id] = info
        attachmentCache.setObject(data as NSData, forKey: id as NSString)
        writer.save([.attachment(info, data)])
        NotificationCenter.default.post(name: .keepNoteAttachmentsChanged, object: self)
        return info
    }

    /// The bytes, opened with this Mac's key; `nil` if there is no such
    /// attachment here (yet) or it cannot be opened.
    func attachmentData(_ id: String) -> Data? {
        if let cached = attachmentCache.object(forKey: id as NSString) { return cached as Data }
        guard attachments[id] != nil, let data = try? writer.loadAttachment(id) else { return nil }
        attachmentCache.setObject(data as NSData, forKey: id as NSString)
        return data
    }

    /// The image, decoded once and kept.
    func attachmentImage(_ id: String) -> NSImage? {
        if let cached = imageCache.object(forKey: id as NSString) { return cached }
        guard let info = attachments[id], info.isImage, let data = attachmentData(id),
              let image = NSImage(data: data) else { return nil }
        // Drawn at its pixel size in points over two: a Retina screenshot
        // comes in at the size it was on screen.
        image.size = NSSize(width: CGFloat(info.pixelWidth) / 2, height: CGFloat(info.pixelHeight) / 2)
        imageCache.setObject(image, forKey: id as NSString)
        return image
    }

    /// The attachments a note's text refers to that this store holds.
    func attachments(of note: Note) -> [AttachmentInfo] {
        AttachmentText.references(in: note.body).compactMap { attachments[$0.id] }
    }

    /// Every attachment some text still refers to: the notes, those still
    /// inside their undo window, and the daily template.
    private var referencedAttachments: Set<String> {
        var ids = Set<String>()
        for note in notes { ids.formUnion(AttachmentText.ids(in: note.body)) }
        for note in pendingDeletions.values { ids.formUnion(AttachmentText.ids(in: note.body)) }
        ids.formUnion(AttachmentText.ids(in: dailyTemplate.body))
        return ids
    }

    /// Removes the attachments no text refers to any more: after a note is
    /// deleted for good, and at launch. Not while a note is locked: its text
    /// cannot be read, so what it refers to cannot be known.
    @discardableResult
    func removeOrphanAttachments() -> [String] {
        guard !notes.contains(where: \.isLocked), !pendingDeletions.values.contains(where: \.isLocked) else { return [] }
        let referenced = referencedAttachments
        let orphans = attachments.keys.filter { !referenced.contains($0) }.sorted()
        guard !orphans.isEmpty else { return [] }
        for id in orphans {
            attachments.removeValue(forKey: id)
            attachmentCache.removeObject(forKey: id as NSString)
            imageCache.removeObject(forKey: id as NSString)
        }
        writer.save([.removeAttachments(orphans)])
        return orphans
    }

    /// A copy in the container's temporary folder, for Open and Quick Look:
    /// the bytes never leave the container in the clear otherwise.
    func temporaryFile(for id: String) -> URL? {
        guard let info = attachments[id], let data = attachmentData(id) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let url = folder.appendingPathComponent(info.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    /// An attachment arrived or went: editors draw their notes again.
    static let keepNoteAttachmentsChanged = Notification.Name("keepNote.attachmentsChanged")
}
