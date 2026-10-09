import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// One `.md` per note.
    case markdownPerNote
    /// One `.txt` per note.
    case plainTextPerNote
    /// Every selected note in one document.
    case singleDocument
    /// The app's own package: colours, states and dates survive a round trip.
    case archivePackage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdownPerNote: return "Markdown — one file per note"
        case .plainTextPerNote: return "Plain text — one file per note"
        case .singleDocument: return "Single document — all selected notes"
        case .archivePackage: return "KeepNote archive — colors, states and dates"
        }
    }

    /// Per-note formats write into a folder; the other two write one file.
    var writesToDirectory: Bool {
        switch self {
        case .markdownPerNote, .plainTextPerNote: return true
        case .singleDocument, .archivePackage: return false
        }
    }
}

/// Export and import.
///
/// Every write goes through `NSSavePanel` or `NSOpenPanel`. Under App Sandbox
/// that is not a nicety: the panel is what hands the app write access to the
/// chosen location, and nothing outside it is reachable.
@MainActor
enum ExportService {
    /// Locked notes (body could not be decrypted) are left out of every
    /// format: their body is a placeholder, not the user's text. Returns how
    /// many were skipped, or `nil` if the user cancelled the panel.
    @discardableResult
    static func run(
        notes allNotes: [Note], format: ExportFormat, suggestedName: String = "KeepNote",
        dailyTemplate: DailyTemplate? = nil
    ) throws -> Int? {
        let notes = allNotes.filter { !$0.isLocked }
        let skipped = allNotes.count - notes.count
        guard !notes.isEmpty else { return skipped }
        if format.writesToDirectory {
            guard let directory = promptForDirectory() else { return nil }
            try writePerNote(notes: notes, format: format, into: directory)
        } else {
            guard let url = promptForFile(format: format, suggestedName: suggestedName) else { return nil }
            try writeSingleFile(notes: notes, format: format, to: url, dailyTemplate: dailyTemplate)
        }
        return skipped
    }

    // MARK: - Panels

    private static func promptForDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported notes."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func promptForFile(format: ExportFormat, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch format {
        case .archivePackage:
            panel.nameFieldStringValue = "\(suggestedName).\(AppPaths.archiveFileExtension)"
            panel.allowedContentTypes = [UTType(filenameExtension: AppPaths.archiveFileExtension) ?? .data]
        default:
            panel.nameFieldStringValue = "\(suggestedName).md"
            panel.allowedContentTypes = [.plainText]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Writers

    private static func writePerNote(notes: [Note], format: ExportFormat, into directory: URL) throws {
        let isMarkdown = format == .markdownPerNote
        var usedNames = Set<String>()
        for note in notes {
            let base = safeFileName(for: note, taken: &usedNames)
            let url = directory.appendingPathComponent("\(base).\(isMarkdown ? "md" : "txt")")
            let contents = isMarkdown ? markdown(for: note) : plainText(for: note)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func writeSingleFile(notes: [Note], format: ExportFormat, to url: URL, dailyTemplate: DailyTemplate?) throws {
        switch format {
        case .archivePackage:
            let data = try NoteArchive.encode(notes: notes, dailyTemplate: dailyTemplate)
            try data.write(to: url, options: .atomic)
        case .singleDocument:
            let document = notes
                .sorted { $0.editedAt > $1.editedAt }
                .map { markdown(for: $0) }
                .joined(separator: "\n\n---\n\n")
            try document.write(to: url, atomically: true, encoding: .utf8)
        case .markdownPerNote, .plainTextPerNote:
            // Handled by `writePerNote`.
            return
        }
    }

    // MARK: - Renderers

    static func markdown(for note: Note) -> String {
        var lines = ["# \(note.displayTitle)", ""]
        if !note.tags.isEmpty {
            lines.append(note.tags.map { "#\($0)" }.joined(separator: " "))
            lines.append("")
        }
        lines.append(note.body)
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("*Created \(dateFormatter.string(from: note.createdAt)) · Edited \(dateFormatter.string(from: note.editedAt))\(note.state == .archived ? " · Archived" : "")*")
        return lines.joined(separator: "\n")
    }

    static func plainText(for note: Note) -> String {
        var lines = [note.displayTitle, String(repeating: "=", count: max(3, note.displayTitle.count)), ""]
        lines.append(note.body)
        if !note.tags.isEmpty {
            lines.append("")
            lines.append("Tags: \(note.tags.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Titles become file names, so anything a file system dislikes goes, and
    /// duplicates get a numeric suffix rather than silently overwriting.
    private static func safeFileName(for note: Note, taken: inout Set<String>) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        var base = note.displayTitle
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Untitled" }
        if base.count > 60 { base = String(base.prefix(60)) }

        var candidate = base
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The `.hmnotearchive` package: JSON, one entry per note, nothing lost.
///
/// Not a Stickies file. Apple's Stickies keeps RTFD inside its own container
/// and there is no supported way to write it; this is KeepNote's own format,
/// and `NoteImporter` reads it back with every field intact.
enum NoteArchive {
    struct Payload: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var notes: [Entry]
        /// The daily template, once it has been set; archives from before it
        /// existed have none.
        var dailyTemplate: TemplateEntry?
    }

    struct TemplateEntry: Codable {
        var body: String
        var updatedAt: Date
    }

    struct Entry: Codable {
        var id: UUID
        var title: String
        var body: String
        var color: Int
        var state: String
        var tags: [String]
        var createdAt: Date
        var updatedAt: Date
        /// Archives from before the two dates were kept apart have none.
        var editedAt: Date?
        /// Daily notes only; archives from before dailies existed have neither.
        var dailyDay: String?
        var dailyKept: Bool?
        /// Only when on; archives from before it existed have none.
        var keepOnDeck: Bool?
        var pinnedAt: Date?
        var lastOpenedDay: String?
        var autoArchivedDay: String?
    }

    static let formatIdentifier = "com.keepnote.archive"
    static let version = 1

    static func encode(notes: [Note], dailyTemplate: DailyTemplate? = nil) throws -> Data {
        let payload = Payload(
            format: formatIdentifier,
            version: version,
            exportedAt: Date(),
            notes: notes.map { note in
                Entry(
                    id: note.id,
                    title: note.title,
                    body: note.body,
                    color: note.color.rawValue,
                    state: note.state.rawValue,
                    tags: note.tags,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    editedAt: note.editedAt,
                    dailyDay: note.dailyDay?.string,
                    dailyKept: note.dailyKept ? true : nil,
                    keepOnDeck: note.keepOnDeck ? true : nil,
                    pinnedAt: note.pinnedAt,
                    lastOpenedDay: note.lastOpenedDay?.string,
                    autoArchivedDay: note.autoArchivedDay?.string
                )
            },
            dailyTemplate: dailyTemplate.flatMap { $0.isSet ? TemplateEntry(body: $0.body, updatedAt: $0.updatedAt) : nil }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> [Note] {
        try decodeContents(data).notes
    }

    /// The daily template an archive carries, if it has one.
    static func decodeTemplate(_ data: Data) throws -> DailyTemplate? {
        try decodeContents(data).template
    }

    private static func decodeContents(_ data: Data) throws -> (notes: [Note], template: DailyTemplate?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.format == formatIdentifier else {
            throw ImportError.unrecognizedFormat
        }
        let template = payload.dailyTemplate.map { DailyTemplate(body: $0.body, updatedAt: $0.updatedAt) }
        return (payload.notes.map { entry in
            Note(
                id: entry.id,
                title: entry.title,
                body: entry.body,
                color: NoteColor.resolve(rawValue: entry.color),
                state: NoteState(rawValue: entry.state) ?? .active,
                sortIndex: 0,
                tags: Note.normalizeTags(entry.tags),
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                editedAt: entry.editedAt,
                dailyDay: entry.dailyDay.flatMap { DailyDay(string: $0) },
                dailyKept: entry.dailyKept ?? false,
                keepOnDeck: entry.keepOnDeck ?? false,
                pinnedAt: entry.pinnedAt,
                lastOpenedDay: entry.lastOpenedDay.flatMap { DailyDay(string: $0) },
                autoArchivedDay: entry.autoArchivedDay.flatMap { DailyDay(string: $0) }
            )
        }, template)
    }
}

enum ImportError: LocalizedError {
    case unrecognizedFormat
    case unreadableNote
    case deletedNote

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat: return "That file is not a KeepNote archive."
        case .unreadableNote: return "That file is not a KeepNote note."
        case .deletedNote: return "That note was deleted."
        }
    }
}

@MainActor
enum NoteImporter {
    /// Reads a `.hmnotearchive`, or a folder of `.hmnote` files, back into the
    /// store. Existing notes are merged by `updatedAt`, so re-importing an
    /// older export never clobbers newer work.
    static func run(into store: NoteStore) throws -> Int {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a KeepNote archive, or a folder of .hmnote files."
        guard panel.runModal() == .OK, let url = panel.url else { return 0 }
        return try importContents(of: url, into: store).applied
    }

    /// `applied` counts the notes that were new or newer than the copy here;
    /// `ids` lists every note the file held, applied or not.
    static func importContents(of url: URL, into store: NoteStore) throws -> (applied: Int, ids: [UUID]) {
        var imported: [Note] = []
        var template: DailyTemplate?

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for file in contents where file.pathExtension == AppPaths.noteFileExtension {
                guard
                    let text = try? String(contentsOf: file, encoding: .utf8),
                    let parsed = HMNoteFile.parse(text),
                    !parsed.isTombstone
                else { continue }
                imported.append(parsed.note)
            }
            template = contents
                .filter { $0.pathExtension == AppPaths.templateFileExtension }
                .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap(DailyTemplateFile.parse) }
                .max { $0.updatedAt < $1.updatedAt }
        } else if url.pathExtension == AppPaths.noteFileExtension {
            // One note, in the sync folder's plain-text format, not an archive.
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let parsed = HMNoteFile.parse(text) else { throw ImportError.unreadableNote }
            guard !parsed.isTombstone else { throw ImportError.deletedNote }
            imported = [parsed.note]
        } else {
            let data = try Data(contentsOf: url)
            imported = try NoteArchive.decode(data)
            template = try NoteArchive.decodeTemplate(data)
        }

        // One transaction and one change for the lot. `.importer`, not
        // `.sync`: imported notes are new to the sync folder too.
        let applied = try store.applyIncoming(imported, origin: .importer)
        // Newer than the template here, or not at all, like a note.
        if let template { store.applyIncomingTemplate(template, origin: .importer) }
        return (applied.count, imported.map(\.id))
    }
}
