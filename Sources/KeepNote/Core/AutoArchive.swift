import Foundation

/// What the archive-by-time rule needs to know about a note. `Note` conforms;
/// the tests use a plain struct.
protocol AutoArchiveItem {
    var id: UUID { get }
    var isArchived: Bool { get }
    var isDeleted: Bool { get }
    /// "Keep on Deck" is on.
    var keepOnDeck: Bool { get }
    var isPinned: Bool { get }
    var isDaily: Bool { get }
    var lastOpenedDay: DailyDay? { get }
}

/// Archiving notes that have not been opened for a while. Foundation only, so
/// the rule can be tested without AppKit.
///
/// The rule is a function of the notes, the day and the setting alone: it
/// reads no clock, keeps no state of its own and only ever archives. So it
/// gives the same answer wherever and as often as it is asked, and once its
/// answer has been applied the next answer is empty.
enum AutoArchive {
    /// The choices of "Archive notes not opened for", in days.
    static let choices = [7, 14, 30]
    static let defaultDays = 14

    /// `days` if it is one of the choices, the default otherwise — a value
    /// left by some other version never turns the rule into something odd.
    static func normalized(_ days: Int) -> Int {
        choices.contains(days) ? days : defaultDays
    }

    // MARK: - The day a note was last opened

    /// A note with no day yet is given `today`: for notes that already exist
    /// the time starts counting the day this version first runs, so nothing
    /// disappears because of an update.
    static func settled(_ day: DailyDay?, today: DailyDay) -> DailyDay {
        day ?? today
    }

    /// Whether opening a note on `today` has to be written: at most once a
    /// day, and never moving the day back.
    static func shouldRecordOpening(last: DailyDay?, today: DailyDay) -> Bool {
        guard let last else { return true }
        return last < today
    }

    /// The later of two copies' days: what two Macs agree on, whichever
    /// reaches the other first.
    static func merged(_ a: DailyDay?, _ b: DailyDay?) -> DailyDay? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    // MARK: - The rule

    /// Whether the rule never touches the note: it is archived or deleted
    /// already, it is kept on the deck or pinned, or it is a daily, which
    /// follows its own rule.
    static func isExempt(_ item: some AutoArchiveItem) -> Bool {
        item.isArchived || item.isDeleted || item.keepOnDeck || item.isPinned || item.isDaily
    }

    /// How many days since the note was last opened, as of `today`. `nil` for
    /// a note with no day yet, which the store gives one when it loads it.
    static func idleDays(_ item: some AutoArchiveItem, today: DailyDay) -> Int? {
        item.lastOpenedDay.map { today.days(after: $0) }
    }

    /// The notes to archive: those that have gone `days` days or more
    /// without being opened, except
    /// - one a window is showing (`open`, docked or floating), which waits
    ///   until it is closed,
    /// - the exempt ones (`isExempt`).
    ///
    /// Sorted by id, so the answer does not depend on the order of `items`.
    static func plan<T: AutoArchiveItem>(_ items: [T], open: Set<UUID> = [], today: DailyDay, days: Int) -> [UUID] {
        let limit = normalized(days)
        return items
            .filter { item in
                guard !isExempt(item), !open.contains(item.id), let idle = idleDays(item, today: today) else { return false }
                return idle >= limit
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - The warning

    /// How many days the note has left before the rule archives it, when that
    /// is one or two: the last two days. `nil` otherwise — more than that is
    /// no reason to say anything, and none left is the rule's to apply.
    static func daysLeft(_ item: some AutoArchiveItem, today: DailyDay, days: Int) -> Int? {
        guard !isExempt(item), let idle = idleDays(item, today: today) else { return nil }
        let left = normalized(days) - idle
        return (1...2).contains(left) ? left : nil
    }

    /// "Archives in 2 days" or "Archives tomorrow".
    static func warning(daysLeft: Int) -> String {
        daysLeft == 1 ? "Archives tomorrow" : "Archives in \(daysLeft) days"
    }

    /// What a note's footer says about its place on the deck: that it is kept
    /// or pinned, or that it is about to be archived. Nothing otherwise.
    static func footerLine(_ item: some AutoArchiveItem, today: DailyDay, days: Int) -> String? {
        if item.isArchived { return nil }
        if item.keepOnDeck { return "Kept on deck" }
        if item.isPinned { return "Pinned to center" }
        return daysLeft(item, today: today, days: days).map(warning(daysLeft:))
    }

    // MARK: - In the Archive

    /// The note says it was archived by the rule, and when.
    static let archivedLabel = "Archived automatically"

    static func archivedLine(day: DailyDay, formatted: String) -> String {
        "\(archivedLabel) \u{00B7} \(formatted)"
    }
}
