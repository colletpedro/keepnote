import Foundation

/// The on-disk form of one note in the sync folder.
///
/// Deliberately a plain UTF-8 text file with a small header: the spec asks for
/// data that stays readable without the app, and a folder full of these opens
/// fine in any editor. The body is *not* encrypted here — the database key is
/// device-bound and never syncs, so encrypting the file would make it
/// unreadable on the very Macs the folder exists to serve. The folder's own
/// protection (FileVault, iCloud Drive) is what covers it.
struct HMNoteFile: Equatable {
    static let schemaVersion = 1
    static let headerFence = "--- keepnote ---"
    static let bodyFence = "---"

    var id: UUID
    var title: String
    var color: NoteColor
    var state: NoteState
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    /// `edited: <date>`: when the text last changed. A file from before the
    /// two dates were kept apart has no such line; the note then reads as edited
    /// when it was last updated.
    var editedAt: Date?
    /// Set on a tombstone. A tombstone carries no body.
    var deletedAt: Date?
    var body: String
    /// Optional in the file: older files have neither line.
    var dailyDay: DailyDay?
    var dailyKept: Bool
    /// "Keep on Deck", written as `keep: yes` only when it is on.
    var keepOnDeck: Bool
    /// `pinned: <date>` when the note is pinned to the center.
    var pinnedAt: Date?
    /// `opened: <day>`: the day the note was last opened.
    var lastOpenedDay: DailyDay?
    /// `auto-archived: <day>` on a note the time rule archived.
    var autoArchivedDay: DailyDay?

    init(note: Note) {
        self.id = note.id
        self.title = note.title
        self.color = note.color
        self.state = note.state
        self.tags = note.tags
        self.createdAt = note.createdAt
        self.updatedAt = note.updatedAt
        self.editedAt = note.editedAt
        self.deletedAt = nil
        self.body = note.body
        self.dailyDay = note.dailyDay
        self.dailyKept = note.dailyKept
        self.keepOnDeck = note.keepOnDeck
        self.pinnedAt = note.pinnedAt
        self.lastOpenedDay = note.lastOpenedDay
        self.autoArchivedDay = note.autoArchivedDay
    }

    init(
        id: UUID, title: String, color: NoteColor, state: NoteState, tags: [String],
        createdAt: Date, updatedAt: Date, editedAt: Date? = nil, deletedAt: Date?, body: String,
        dailyDay: DailyDay? = nil, dailyKept: Bool = false, keepOnDeck: Bool = false,
        pinnedAt: Date? = nil, lastOpenedDay: DailyDay? = nil,
        autoArchivedDay: DailyDay? = nil
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.state = state
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.body = body
        self.dailyDay = dailyDay
        self.dailyKept = dailyKept
        self.keepOnDeck = keepOnDeck
        self.pinnedAt = pinnedAt
        self.lastOpenedDay = lastOpenedDay
        self.autoArchivedDay = autoArchivedDay
    }

    static func tombstone(id: UUID, deletedAt: Date) -> HMNoteFile {
        HMNoteFile(
            id: id, title: "", color: .default, state: .active, tags: [],
            createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt, body: ""
        )
    }

    var isTombstone: Bool { deletedAt != nil }

    var note: Note {
        Note(
            id: id, title: title, body: body, color: color, state: state,
            sortIndex: 0, tags: tags, createdAt: createdAt, updatedAt: updatedAt, editedAt: editedAt,
            deletedAt: nil, dailyDay: dailyDay, dailyKept: dailyKept, keepOnDeck: keepOnDeck,
            pinnedAt: pinnedAt, lastOpenedDay: lastOpenedDay,
            autoArchivedDay: autoArchivedDay
        )
    }

    var fileName: String { "\(id.uuidString).\(AppPaths.noteFileExtension)" }

    // MARK: - Serialisation

    func serialized() -> String {
        var lines: [String] = [Self.headerFence]
        lines.append("schema: \(Self.schemaVersion)")
        lines.append("id: \(id.uuidString)")
        lines.append("title: \(Self.escape(title))")
        lines.append("color: \(color.rawValue)")
        lines.append("state: \(state.rawValue)")
        lines.append("tags: \(tags.joined(separator: ","))")
        if let dailyDay {
            lines.append("daily: \(dailyDay.string)")
            if dailyKept { lines.append("daily-kept: yes") }
        }
        if keepOnDeck { lines.append("keep: yes") }
        if let pinnedAt { lines.append("pinned: \(Self.isoFormatter.string(from: pinnedAt))") }
        if let lastOpenedDay { lines.append("opened: \(lastOpenedDay.string)") }
        if let autoArchivedDay { lines.append("auto-archived: \(autoArchivedDay.string)") }
        lines.append("created: \(Self.isoFormatter.string(from: createdAt))")
        lines.append("updated: \(Self.isoFormatter.string(from: updatedAt))")
        if let editedAt { lines.append("edited: \(Self.isoFormatter.string(from: editedAt))") }
        if let deletedAt {
            lines.append("deleted: \(Self.isoFormatter.string(from: deletedAt))")
        }
        lines.append(Self.bodyFence)
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    static func parse(_ contents: String) -> HMNoteFile? {
        var lines = contents.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == headerFence else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var bodyStart: Int?
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == bodyFence {
                bodyStart = index + 1
                break
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let idString = fields["id"], let id = UUID(uuidString: idString) else { return nil }

        var body = ""
        if let bodyStart, bodyStart < lines.count {
            var bodyLines = Array(lines[bodyStart...])
            // The serialiser writes one blank line after the fence.
            if bodyLines.first?.isEmpty == true { bodyLines.removeFirst() }
            body = bodyLines.joined(separator: "\n")
        }

        return HMNoteFile(
            id: id,
            title: unescape(fields["title"] ?? ""),
            color: NoteColor.resolve(rawValue: Int(fields["color"] ?? "") ?? 0),
            state: NoteState(rawValue: fields["state"] ?? "active") ?? .active,
            tags: Note.parseTags(fields["tags"] ?? ""),
            createdAt: fields["created"].flatMap { isoFormatter.date(from: $0) } ?? Date(),
            updatedAt: fields["updated"].flatMap { isoFormatter.date(from: $0) } ?? Date(),
            editedAt: fields["edited"].flatMap { isoFormatter.date(from: $0) },
            deletedAt: fields["deleted"].flatMap { isoFormatter.date(from: $0) },
            body: body,
            dailyDay: fields["daily"].flatMap { DailyDay(string: $0) },
            dailyKept: fields["daily-kept"] == "yes",
            keepOnDeck: fields["keep"] == "yes",
            pinnedAt: fields["pinned"].flatMap { isoFormatter.date(from: $0) },
            lastOpenedDay: fields["opened"].flatMap { DailyDay(string: $0) },
            autoArchivedDay: fields["auto-archived"].flatMap { DailyDay(string: $0) }
        )
    }

    /// Titles are one header line, so newlines have to survive a round trip.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var isEscaping = false
        for character in value {
            if isEscaping {
                switch character {
                case "n": result.append("\n")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Fractional seconds matter: last-writer-wins compares these timestamps,
    /// and two edits a few hundred milliseconds apart are not unusual.
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
