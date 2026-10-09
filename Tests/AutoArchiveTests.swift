import Foundation

func runAutoArchiveTests() {
    expect("auto archive: the choices", AutoArchive.choices.map(String.init).joined(separator: ","), "7,14,30")
    expect("auto archive: fourteen days by default", String(AutoArchive.defaultDays), "14")
    expect("auto archive: a choice stands", String(AutoArchive.normalized(30)), "30")
    expect("auto archive: anything else is the default", String(AutoArchive.normalized(10)), "14")
    expect("auto archive: zero, as an unset preference reads", String(AutoArchive.normalized(0)), "14")
}

func runOpenedDayTests() {
    func day(_ y: Int, _ m: Int, _ d: Int) -> DailyDay { DailyDay(year: y, month: m, day: d) }

    // Day arithmetic: by hand, no calendar.
    expect("days: the epoch", String(day(1970, 1, 1).epochDay), "0")
    expect("days: a known day", String(day(2026, 10, 8).epochDay), "20734")
    expect("days: a leap day follows its February", String(day(2024, 3, 1).days(after: day(2024, 2, 28))), "2")
    expect("days: and a plain year does not", String(day(2025, 3, 1).days(after: day(2025, 2, 28))), "1")
    expect("days: across a year end", String(day(2027, 1, 2).days(after: day(2026, 12, 30))), "3")
    expect("days: across a century that is not a leap year", String(day(2100, 3, 1).days(after: day(2100, 2, 28))), "1")
    expect("days: across the year 2000, which is", String(day(2000, 3, 1).days(after: day(2000, 2, 28))), "2")
    expect("days: a whole year", String(day(2026, 10, 8).days(after: day(2025, 10, 8))), "365")
    expect("days: before is negative", String(day(2026, 10, 1).days(after: day(2026, 10, 8))), "-7")
    var consecutive = true
    var previous = day(2020, 12, 25).epochDay
    for offset in 1...800 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.date(from: DateComponents(year: 2020, month: 12, day: 25))!)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let value = day(parts.year!, parts.month!, parts.day!).epochDay
        if value != previous + 1 { consecutive = false }
        previous = value
    }
    expectTrue("days: every day of 800 is one after the last, as the calendar has them", consecutive)

    var roundTrips = true
    for epoch in stride(from: -800, through: 40_000, by: 7) where DailyDay(epoch: epoch).epochDay != epoch { roundTrips = false }
    expectTrue("days: a day from its number and back", roundTrips)
    expect("days: day zero", DailyDay(epoch: 0).string, "1970-01-01")
    expect("days: a leap day", DailyDay(epoch: day(2024, 2, 29).epochDay).string, "2024-02-29")

    // The day a note was last opened.
    let today = day(2026, 10, 8)
    expect("opened: a note with none starts counting today", AutoArchive.settled(nil, today: today).string, "2026-10-08")
    expect("opened: one that has a day keeps it", AutoArchive.settled(day(2026, 9, 1), today: today).string, "2026-09-01")
    expectTrue("opened: the first opening is written", AutoArchive.shouldRecordOpening(last: nil, today: today))
    expectTrue("opened: an earlier day is replaced by today", AutoArchive.shouldRecordOpening(last: day(2026, 10, 7), today: today))
    expectTrue("opened: today is written once", !AutoArchive.shouldRecordOpening(last: today, today: today))
    expectTrue("opened: a later day (the clock went back) is not moved back", !AutoArchive.shouldRecordOpening(last: day(2026, 10, 9), today: today))
    expect("opened: two copies, the later", AutoArchive.merged(day(2026, 10, 1), day(2026, 10, 5))?.string, "2026-10-05")
    expect("opened: whichever order", AutoArchive.merged(day(2026, 10, 5), day(2026, 10, 1))?.string, "2026-10-05")
    expect("opened: one with none says nothing", AutoArchive.merged(nil, day(2026, 10, 1))?.string, "2026-10-01")
    expect("opened: neither", AutoArchive.merged(nil, nil)?.string, nil)
}

// MARK: - The rule

private struct Probe: AutoArchiveItem {
    var id = UUID()
    var name = ""
    var isArchived = false
    var isDeleted = false
    var keepOnDeck = false
    var isPinned = false
    var isDaily = false
    var lastOpenedDay: DailyDay?
}

func runAutoArchiveRuleTests() {
    func day(_ y: Int, _ m: Int, _ d: Int) -> DailyDay { DailyDay(year: y, month: m, day: d) }
    let today = day(2026, 10, 8)
    func opened(_ daysAgo: Int, _ name: String = "") -> Probe {
        var probe = Probe(name: name)
        probe.lastOpenedDay = DailyDay(epoch: today.epochDay - daysAgo)
        return probe
    }
    func names(_ ids: [UUID], in items: [Probe]) -> String {
        ids.compactMap { id in items.first { $0.id == id }?.name }.sorted().joined(separator: ",")
    }

    // The boundary: a note not opened for exactly the setting's days goes.
    let items = [opened(0, "today"), opened(6, "6"), opened(7, "7"), opened(8, "8"), opened(13, "13"), opened(14, "14"),
                 opened(29, "29"), opened(30, "30"), opened(400, "400")]
    expect("rule: seven days", names(AutoArchive.plan(items, today: today, days: 7), in: items), "14,30,400,7,8,13,29".split(separator: ",").sorted().joined(separator: ","))
    expect("rule: fourteen days", names(AutoArchive.plan(items, today: today, days: 14), in: items), "14,30,400,29".split(separator: ",").sorted().joined(separator: ","))
    expect("rule: thirty days", names(AutoArchive.plan(items, today: today, days: 30), in: items), "30,400")
    expect("rule: a setting that is not a choice counts as fourteen", names(AutoArchive.plan(items, today: today, days: 3), in: items),
           names(AutoArchive.plan(items, today: today, days: 14), in: items))

    // What it never touches.
    var kept = opened(100, "kept"); kept.keepOnDeck = true
    var pinned = opened(100, "pinned"); pinned.isPinned = true
    var daily = opened(100, "daily"); daily.isDaily = true
    var archived = opened(100, "archived"); archived.isArchived = true
    var deleted = opened(100, "deleted"); deleted.isDeleted = true
    let stale = opened(100, "stale")
    let exempt = [kept, pinned, daily, archived, deleted, stale]
    expect("rule: only the plain stale note", names(AutoArchive.plan(exempt, today: today, days: 14), in: exempt), "stale")
    expect("rule: a note a window shows waits", names(AutoArchive.plan(exempt, open: [stale.id], today: today, days: 14), in: exempt), "")
    expect("rule: ...and goes when it closes", names(AutoArchive.plan(exempt, open: [], today: today, days: 14), in: exempt), "stale")
    expectTrue("rule: kept, pinned, daily, archived and deleted are exempt",
               [kept, pinned, daily, archived, deleted].allSatisfy { AutoArchive.isExempt($0) } && !AutoArchive.isExempt(stale))
    var pinnedAndKept = opened(100, "both"); pinnedAndKept.keepOnDeck = true; pinnedAndKept.isPinned = true
    expectTrue("rule: pinned and kept is no less safe", AutoArchive.plan([pinnedAndKept], today: today, days: 7).isEmpty)

    // A note that has no day yet is never archived; the store gives it one.
    let undated = Probe(name: "undated")
    expectTrue("rule: no day, no archiving", AutoArchive.plan([undated], today: today, days: 7).isEmpty)
    var future = Probe(name: "future"); future.lastOpenedDay = day(2027, 1, 1)
    expectTrue("rule: a day in the future (the clock moved, or another Mac's) is not idleness", AutoArchive.plan([future], today: today, days: 7).isEmpty)

    // The update: every note starts counting the day this version first runs.
    let firstRun = day(2026, 10, 8)
    let existing = (0..<5).map { index -> Probe in
        var probe = Probe(name: "old\(index)")
        probe.lastOpenedDay = AutoArchive.settled(nil, today: firstRun)
        return probe
    }
    expectTrue("update: nothing goes on the day it first runs", AutoArchive.plan(existing, today: firstRun, days: 7).isEmpty)
    for (days, last) in [(7, 6), (14, 13), (30, 29)] {
        let before = DailyDay(epoch: firstRun.epochDay + last)
        let at = DailyDay(epoch: firstRun.epochDay + days)
        expectTrue("update: with \\(days) days, nothing goes before day \\(days)", AutoArchive.plan(existing, today: before, days: days).isEmpty)
        expect("update: and every note goes on day \\(days)", String(AutoArchive.plan(existing, today: at, days: days).count), "5")
    }

    // Only ever archives: what it names is neither deleted nor archived already.
    let mixed = [opened(50, "a"), archived, deleted, opened(50, "b")]
    expectTrue("rule: only notes that are on the deck", AutoArchive.plan(mixed, today: today, days: 7).allSatisfy { id in
        mixed.first { $0.id == id }.map { !$0.isArchived && !$0.isDeleted } ?? false })

    // The same answer wherever and however often it is asked.
    let crowd = (0..<60).map { index -> Probe in
        var probe = opened(index, "n\(index)")
        probe.keepOnDeck = index % 7 == 0
        probe.isDaily = index % 11 == 0
        probe.isPinned = index % 13 == 0
        return probe
    }
    let plan = AutoArchive.plan(crowd, today: today, days: 14)
    expectTrue("rule: asked again, the same", AutoArchive.plan(crowd, today: today, days: 14) == plan)
    expectTrue("rule: in any order, the same", AutoArchive.plan(crowd.reversed(), today: today, days: 14) == plan)
    expectTrue("rule: shuffled, the same", AutoArchive.plan(crowd.shuffled(), today: today, days: 14) == plan)
    expectTrue("rule: sorted by id", plan == plan.sorted { $0.uuidString < $1.uuidString })
    // Two Macs that agree on the notes agree on the plan.
    let otherMac = crowd.map { probe -> Probe in var copy = probe; copy.name += "'"; return copy }
    expectTrue("rule: two Macs with the same notes archive the same notes", AutoArchive.plan(otherMac, today: today, days: 14) == plan)
    // Applied, the next plan is empty — and so is every one after it.
    let applied = crowd.map { probe -> Probe in var copy = probe; copy.isArchived = plan.contains(copy.id); return copy }
    expectTrue("rule: once applied, there is nothing more to do", AutoArchive.plan(applied, today: today, days: 14).isEmpty)
    expect("rule: it archived some, not all", String(plan.count > 0 && plan.count < crowd.count), "true")
    // A longer setting archives a subset of a shorter one's.
    let p7 = Set(AutoArchive.plan(crowd, today: today, days: 7)), p14 = Set(plan), p30 = Set(AutoArchive.plan(crowd, today: today, days: 30))
    expectTrue("rule: thirty days archives no more than fourteen, which no more than seven", p30.isSubset(of: p14) && p14.isSubset(of: p7))
    // Opening a note puts it out of reach.
    var rescued = crowd
    for index in rescued.indices where rescued[index].lastOpenedDay != nil && plan.contains(rescued[index].id) {
        rescued[index].lastOpenedDay = today
    }
    expectTrue("rule: opened today, nothing is left to archive", AutoArchive.plan(rescued, today: today, days: 14).isEmpty)

    // The warning: the last two days.
    func left(_ idle: Int, days: Int = 14) -> Int? { AutoArchive.daysLeft(opened(idle), today: today, days: days) }
    expect("warning: far from it, nothing", String(describing: left(5)), "nil")
    expect("warning: three days left, still nothing", String(describing: left(11)), "nil")
    expect("warning: two days left", String(describing: left(12)), "Optional(2)")
    expect("warning: one day left", String(describing: left(13)), "Optional(1)")
    expect("warning: due, it is the rule's to apply", String(describing: left(14)), "nil")
    expect("warning: with seven days", String(describing: left(5, days: 7)) + String(describing: left(6, days: 7)), "Optional(2)Optional(1)")
    expect("warning: with thirty days", String(describing: left(28, days: 30)) + String(describing: left(29, days: 30)), "Optional(2)Optional(1)")
    expect("warning: two days", AutoArchive.warning(daysLeft: 2), "Archives in 2 days")
    expect("warning: tomorrow", AutoArchive.warning(daysLeft: 1), "Archives tomorrow")
    expect("warning: no day, no warning", String(describing: AutoArchive.daysLeft(Probe(), today: today, days: 14)), "nil")
    for exemptNote in [kept, pinned, daily, archived, deleted] {
        var close = exemptNote
        close.lastOpenedDay = DailyDay(epoch: today.epochDay - 13)
        expect("warning: \(exemptNote.name) is never warned about", String(describing: AutoArchive.daysLeft(close, today: today, days: 14)), "nil")
    }
    // The warning and the rule agree: the day after the last warning it is archived.
    let tomorrow = DailyDay(epoch: today.epochDay + 1)
    let aboutTo = opened(13, "about")
    expect("warning: warned today", String(describing: AutoArchive.daysLeft(aboutTo, today: today, days: 14)), "Optional(1)")
    expect("warning: archived tomorrow", String(AutoArchive.plan([aboutTo], today: tomorrow, days: 14).count), "1")
    expect("warning: not today", String(AutoArchive.plan([aboutTo], today: today, days: 14).count), "0")

    // The footer.
    expect("footer: kept", AutoArchive.footerLine(kept, today: today, days: 14), "Kept on deck")
    expect("footer: pinned", AutoArchive.footerLine(pinned, today: today, days: 14), "Pinned to center")
    var both = kept; both.isPinned = true
    expect("footer: kept and pinned says kept", AutoArchive.footerLine(both, today: today, days: 14), "Kept on deck")
    expect("footer: two days", AutoArchive.footerLine(opened(12), today: today, days: 14), "Archives in 2 days")
    expect("footer: tomorrow", AutoArchive.footerLine(opened(13), today: today, days: 14), "Archives tomorrow")
    expect("footer: nothing to say", AutoArchive.footerLine(opened(2), today: today, days: 14), nil)
    expect("footer: a daily says nothing of it", AutoArchive.footerLine(daily, today: today, days: 14), nil)
    expect("footer: archived says nothing here", AutoArchive.footerLine(archived, today: today, days: 14), nil)
}

func runArchivedLineTests() {
    expect("archived line: says it was the rule, and when",
           AutoArchive.archivedLine(day: DailyDay(year: 2026, month: 10, day: 8), formatted: "Oct 8, 2026"),
           "Archived automatically \u{00B7} Oct 8, 2026")
    expect("archived line: the label", AutoArchive.archivedLabel, "Archived automatically")
}
