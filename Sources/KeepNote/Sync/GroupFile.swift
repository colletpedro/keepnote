import Foundation

/// One group in the sync folder: a plain text file with the same header fence
/// as a note, under its own extension so nothing mistakes it for a note. One
/// file per group, like one per note, so two Macs that each make a group never
/// overwrite each other's, and each group is last-writer-wins on its own.
///
/// A deleted group is the same file with a `deleted` line: that is its
/// tombstone, and it stays.
enum GroupFile {
    static let kind = "group"

    static func fileName(for id: UUID) -> String {
        "\(id.uuidString).\(AppPaths.groupFileExtension)"
    }

    static func serialized(_ record: GroupRecord) -> String {
        let group = record.group
        var lines = [
            HMNoteFile.headerFence,
            "schema: \(HMNoteFile.schemaVersion)",
            "kind: \(kind)",
            "id: \(group.id.uuidString)",
            "name: \(HMNoteFile.escape(group.name))",
            "color: \(group.color.rawValue)",
            "order: \(group.order)",
            "created: \(HMNoteFile.isoFormatter.string(from: group.createdAt))",
            "updated: \(HMNoteFile.isoFormatter.string(from: group.updatedAt))",
        ]
        if let deletedAt = record.deletedAt { lines.append("deleted: \(HMNoteFile.isoFormatter.string(from: deletedAt))") }
        lines.append(HMNoteFile.bodyFence)
        return lines.joined(separator: "\n")
    }

    /// `nil` for anything that is not a group file.
    static func parse(_ contents: String) -> GroupRecord? {
        var lines = contents.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == HMNoteFile.headerFence else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == HMNoteFile.bodyFence { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            fields[key] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard fields["kind"] == kind,
              let id = fields["id"].flatMap({ UUID(uuidString: $0) }),
              let name = fields["name"].map(HMNoteFile.unescape).flatMap(NoteGroup.cleaned),
              let updated = fields["updated"].flatMap({ HMNoteFile.isoFormatter.date(from: $0) })
        else { return nil }
        let group = NoteGroup(
            id: id,
            name: name,
            color: GroupColor.resolve(rawValue: Int(fields["color"] ?? "") ?? GroupColor.default.rawValue),
            order: Int(fields["order"] ?? "") ?? 0,
            createdAt: fields["created"].flatMap { HMNoteFile.isoFormatter.date(from: $0) } ?? updated,
            updatedAt: updated
        )
        return GroupRecord(group: group, deletedAt: fields["deleted"].flatMap { HMNoteFile.isoFormatter.date(from: $0) })
    }
}
