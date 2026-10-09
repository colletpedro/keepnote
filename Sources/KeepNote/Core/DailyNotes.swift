import Foundation

/// A calendar day with no time and no zone: the "day of the daily" a note was
/// given when it received the tag. It is kept as the local day it was on that
/// Mac, so it reads the same on every Mac the note syncs to, and it is stored
/// as text (`2026-10-08`), which also sorts the way the days do.
struct DailyDay: Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `epochDay` days after 1970-01-01.
    init(epoch: Int) {
        // civil_from_days, by arithmetic alone.
        let shifted = epoch + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPart = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
        let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `calendar` (the local one by default).
    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `2026-10-08`; anything else is `nil`.
    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Noon of the day in `calendar`, for showing it.
    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// Days since 1970-01-01 in the Gregorian calendar, worked out by
    /// arithmetic alone — no calendar, no zone — so it reads the same on
    /// every Mac and in every test.
    var epochDay: Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// How many days this day is after `earlier` (negative if before).
    func days(after earlier: DailyDay) -> Int {
        epochDay - earlier.epochDay
    }

    static func < (lhs: DailyDay, rhs: DailyDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// What the daily rule needs to know about a note. `Note` conforms; the tests
/// use a plain struct.
protocol DailyItem {
    var id: UUID { get }
    var tags: [String] { get }
    var dailyDay: DailyDay? { get }
    var dailyKept: Bool { get }
    var editedAt: Date { get }
    var isArchived: Bool { get }
    var isDeleted: Bool { get }
    /// Kept on the deck by hand (Keep on Deck, or pinned): no rule archives it.
    var staysOnDeck: Bool { get }
}

extension DailyItem {
    var staysOnDeck: Bool { false }
}

/// Daily notes: a note that carries the reserved `daily` tag. This file is
/// Foundation only, so everything the rule needs can be tested without AppKit.
enum DailyNotes {
    /// The reserved tag. It exists whether or not a note carries it, it is
    /// offered when typing tags, and it can be neither renamed, merged into
    /// nor deleted.
    static let tag = "daily"

    /// Whether `name` (with or without `#`, any case or accents) is the
    /// reserved tag.
    static func isReserved(_ name: String) -> Bool {
        TagText.fold(TagText.name(ofToken: name)) == tag
    }

    /// Whether a note's tags make it a daily note.
    static func hasTag(_ tags: [String]) -> Bool {
        tags.contains { isReserved($0) }
    }

    /// `usage` with the reserved tag in it, used by no note if no note has it,
    /// so it is always among the tags the field can suggest.
    static func including(_ usage: [TagText.Usage]) -> [TagText.Usage] {
        usage.contains { isReserved($0.tag) } ? usage : usage + [TagText.Usage(tag: tag, count: 0)]
    }

    /// Why a rename may not happen, or `nil` when the reserved tag is not
    /// involved: it cannot be renamed, and no other tag can be renamed (that
    /// is, merged) into it.
    static func renameBlock(_ old: String, to new: String) -> (title: String, detail: String)? {
        if isReserved(old) {
            return ("\u{201C}#\(tag)\u{201D} cannot be renamed",
                    "It is the tag daily notes are made with, so it keeps its name.")
        }
        if isReserved(new) {
            return ("\u{201C}#\(tag)\u{201D} is reserved",
                    "Other tags cannot be renamed or merged into it. Add the tag to a note to make it a daily note.")
        }
        return nil
    }

    // MARK: - The day of a daily

    /// What a note's daily fields become when its tags change from
    /// `previousTags` to `tags`.
    ///
    /// - Without the tag there is no day, and no "kept" mark either.
    /// - A note that had the tag keeps its day (and the mark): the day never
    ///   moves. One that has the tag but no day — it came from a file written
    ///   before dailies existed — is given `today`.
    /// - A note that has just received the tag is given `today`, whatever it
    ///   carried before: taking the tag off and putting it back starts over.
    static func reconcile(
        previousTags: [String], tags: [String], day: DailyDay?, kept: Bool, today: DailyDay
    ) -> (day: DailyDay?, kept: Bool) {
        guard hasTag(tags) else { return (nil, false) }
        guard hasTag(previousTags) else { return (today, false) }
        return (day ?? today, kept)
    }

    /// A note as it is stored or received: the tag decides whether it has a
    /// day, and a daily without one is given `today`.
    static func settled(tags: [String], day: DailyDay?, kept: Bool, today: DailyDay) -> (day: DailyDay?, kept: Bool) {
        reconcile(previousTags: tags, tags: tags, day: day, kept: kept, today: today)
    }

    // MARK: - Today's daily

    /// The daily to open for `today`: of those whose day is today, on the
    /// deck or archived, the one edited last (then by id, so the choice is
    /// the same wherever it is made). `nil` when there is none.
    static func todays<T: DailyItem>(_ items: [T], today: DailyDay) -> T? {
        items
            .filter { isDay($0) && $0.dailyDay == today }
            .max { a, b in
                a.editedAt != b.editedAt ? a.editedAt < b.editedAt : a.id.uuidString < b.id.uuidString
            }
    }

    /// The title of a new daily: "Daily" and the day and month in the
    /// system's short format and order (`Daily 08/10`, `Daily 10/8`).
    static func title(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dM")
        return "Daily " + formatter.string(from: date)
    }

    // MARK: - The archive rule

    /// How many days with a daily stay on the deck.
    static let daysOnDeck = 2

    private static func isDay(_ item: some DailyItem) -> Bool {
        !item.isDeleted && item.dailyDay != nil && hasTag(item.tags)
    }

    /// The days whose dailies stay: the two most recent days that have a
    /// daily at all. A day counts whatever became of its notes (on the deck,
    /// archived, kept), so the answer depends only on the notes themselves,
    /// not on the clock or on which Mac asks.
    static func retainedDays<T: DailyItem>(_ items: [T]) -> Set<DailyDay> {
        let days = Set(items.filter { isDay($0) }.compactMap(\.dailyDay))
        return Set(days.sorted(by: >).prefix(daysOnDeck))
    }

    /// The dailies to archive: those on the deck whose day is older than the
    /// retained ones, except
    /// - a note in `open` (a window is showing it, docked or floating), which
    ///   waits until it is closed,
    /// - one brought back to the deck by hand (`dailyKept`),
    /// - one kept on the deck (Keep on Deck) or pinned.
    ///
    /// Only ever archives: nothing here deletes. The same notes always give
    /// the same answer (sorted by id), and once the plan is applied the next
    /// plan is empty.
    static func archivalPlan<T: DailyItem>(_ items: [T], open: Set<UUID> = []) -> [UUID] {
        let retained = retainedDays(items)
        return items
            .filter { item in
                guard isDay(item), !item.isArchived, !item.dailyKept, !item.staysOnDeck, !open.contains(item.id),
                      let day = item.dailyDay else { return false }
                return !retained.contains(day)
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Whether bringing the note back to the deck by hand has to be
    /// remembered: only when the rule would archive it again — its day is
    /// older than the retained ones.
    static func restoreKeeps<T: DailyItem>(_ id: UUID, in items: [T]) -> Bool {
        guard let item = items.first(where: { $0.id == id }), isDay(item), let day = item.dailyDay else { return false }
        return !retainedDays(items).contains(day)
    }

    // MARK: - The history

    /// The dailies of one day.
    struct DayGroup<T> {
        var day: DailyDay
        var items: [T]
    }

    /// Dailies grouped by day, the most recent day first; within a day the
    /// one edited last first. A note that is not a daily is left out.
    static func groups<T: DailyItem>(_ items: [T]) -> [DayGroup<T>] {
        var byDay: [DailyDay: [T]] = [:]
        for item in items where isDay(item) {
            if let day = item.dailyDay { byDay[day, default: []].append(item) }
        }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(day: day, items: byDay[day]!.sorted { a, b in
                a.editedAt != b.editedAt ? a.editedAt > b.editedAt : a.id.uuidString < b.id.uuidString
            })
        }
    }

    // MARK: - The chip's menu

    /// How many earlier dailies the menu on a note's `daily` chip lists.
    static let menuLimit = 10

    /// The dailies before the note's own day: the `limit` most recent of those
    /// on earlier days, grouped by day, latest first. Other dailies of the
    /// note's own day, and the note itself, are not "previous".
    static func previous<T: DailyItem>(before day: DailyDay, in items: [T], excluding id: UUID, limit: Int = menuLimit) -> [DayGroup<T>] {
        var taken = 0
        var result: [DayGroup<T>] = []
        for group in groups(items.filter { $0.id != id }) where group.day < day {
            let room = limit - taken
            guard room > 0 else { break }
            let items = Array(group.items.prefix(room))
            taken += items.count
            result.append(DayGroup(day: group.day, items: items))
        }
        return result
    }
}
