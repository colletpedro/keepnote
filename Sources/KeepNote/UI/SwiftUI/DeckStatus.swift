import Foundation

/// What a note's footer, the peek, the reading pane and the Archive say about
/// its place on the deck, read from the clock and the setting as they are
/// right now.
@MainActor
enum DeckStatus {
    /// In the last two days before the time rule archives it.
    static func isExpiring(_ note: Note, now: Date = Date()) -> Bool {
        AutoArchive.daysLeft(note, today: DailyDay(now), days: AppSettings.shared.archiveAfterDays) != nil
    }

    /// Kept, pinned, about to be archived — or, in the Archive, archived by
    /// the rule and when.
    static func line(for note: Note, now: Date = Date()) -> String? {
        if note.state == .archived { return archivedLine(for: note) }
        return AutoArchive.footerLine(note, today: DailyDay(now), days: AppSettings.shared.archiveAfterDays)
    }

    /// "Archived automatically · Oct 8, 2026", for a note the rule archived.
    static func archivedLine(for note: Note) -> String? {
        guard note.state == .archived, let day = note.autoArchivedDay else { return nil }
        return AutoArchive.archivedLine(day: day, formatted: dayFormatter.string(from: day.date() ?? Date()))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
