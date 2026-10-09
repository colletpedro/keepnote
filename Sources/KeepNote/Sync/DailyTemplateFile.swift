import Foundation

/// The daily template in the sync folder: a plain text file with the same
/// header fence as a note, under its own extension so nothing mistakes it for
/// a note. Like a note's file, the body is not encrypted here — see
/// `HMNoteFile` for why.
enum DailyTemplateFile {
    static let fileName = "daily-template.\(AppPaths.templateFileExtension)"
    static let kind = "daily-template"

    static func serialized(_ template: DailyTemplate) -> String {
        [
            HMNoteFile.headerFence,
            "schema: \(HMNoteFile.schemaVersion)",
            "kind: \(kind)",
            "updated: \(HMNoteFile.isoFormatter.string(from: template.updatedAt))",
            HMNoteFile.bodyFence,
            "",
            template.body,
        ].joined(separator: "\n")
    }

    /// `nil` for anything that is not a template file.
    static func parse(_ contents: String) -> DailyTemplate? {
        var lines = contents.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == HMNoteFile.headerFence else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var bodyStart: Int?
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == HMNoteFile.bodyFence {
                bodyStart = index + 1
                break
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            fields[key] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard fields["kind"] == kind,
              let updated = fields["updated"].flatMap({ HMNoteFile.isoFormatter.date(from: $0) })
        else { return nil }

        var body = ""
        if let bodyStart, bodyStart < lines.count {
            var bodyLines = Array(lines[bodyStart...])
            // The serialiser writes one blank line after the fence.
            if bodyLines.first?.isEmpty == true { bodyLines.removeFirst() }
            body = bodyLines.joined(separator: "\n")
        }
        return DailyTemplate(body: body, updatedAt: updated)
    }
}
