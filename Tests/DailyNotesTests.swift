import Foundation

private struct Item: TaggedItem {
    var id = UUID()
    var tags: [String]
    var isArchived = false
    var isDeleted = false
    var isLocked = false
}

func runDailyNotesTests() {
    func list(_ tags: [String]?) -> String { tags.map { $0.joined(separator: ",") } ?? "nil" }

    // MARK: The reserved tag

    expectTrue("reserved: daily", DailyNotes.isReserved("daily"))
    expectTrue("reserved: ignores #, case and accents", DailyNotes.isReserved(" #DÁily "))
    expectTrue("reserved: other tags are not", !DailyNotes.isReserved("dailies") && !DailyNotes.isReserved("") && !DailyNotes.isReserved("work"))
    expectTrue("hasTag", DailyNotes.hasTag(["work", "Daily"]))
    expectTrue("hasTag: absent", !DailyNotes.hasTag(["work"]) && !DailyNotes.hasTag([]))

    let usage = [TagText.Usage(tag: "work", count: 3)]
    expect("suggestions: the reserved tag is offered with no note using it",
           TagText.suggestions(for: "dai", usage: DailyNotes.including(usage), existing: []).joined(separator: ","), "daily")
    expect("suggestions: and after the used ones for an empty token",
           TagText.suggestions(for: "", usage: DailyNotes.including(usage), existing: []).joined(separator: ","), "work,daily")
    expect("suggestions: not when the note already has it",
           TagText.suggestions(for: "dai", usage: DailyNotes.including(usage), existing: ["daily"]).joined(separator: ","), "")
    expect("including: a used one is left alone",
           DailyNotes.including([TagText.Usage(tag: "daily", count: 4)]).map { "\($0.tag)=\($0.count)" }.joined(separator: ","), "daily=4")
    expect("create: typing daily offers no Create row",
           TagText.createCandidate(for: "daily", usage: DailyNotes.including([]), existing: []), nil)

    // MARK: Renaming, merging, deleting

    let a = Item(tags: ["daily", "work"])
    let b = Item(tags: ["work"])
    let pool = [a, b]
    expect("rename: daily cannot be renamed", TagLibrary.rename("daily", to: "journal", in: pool)?.target, nil)
    expect("rename: daily cannot be renamed, however spelled", TagLibrary.rename("#Daily", to: "journal", in: pool)?.target, nil)
    expect("rename: nothing can be merged into daily", TagLibrary.rename("work", to: "daily", in: pool)?.target, nil)
    expect("rename: nor renamed to a spelling of it", TagLibrary.rename("work", to: "#DAILY", in: pool)?.target, nil)
    expect("rename plan: changes nothing for daily", String(TagLibrary.renamePlan("daily", to: "journal", in: pool).changes.count), "0")
    expect("rename plan: nor onto daily", String(TagLibrary.renamePlan("work", to: "daily", in: pool).changes.count), "0")
    expect("rename: other tags still rename", TagLibrary.rename("work", to: "job", in: pool)?.target, "job")
    expect("delete plan: daily is never deleted", String(TagLibrary.deletePlan("daily", in: pool).changes.count), "0")
    expect("delete plan: whatever the spelling", String(TagLibrary.deletePlan("#Daily", in: pool).changes.count), "0")
    expect("delete plan: other tags still go", String(TagLibrary.deletePlan("work", in: pool).changes.count), "2")
    expect("remove plan: the tag comes off a note, as for any tag",
           list(TagLibrary.removePlan("daily", from: pool).changes[a.id]), "work")
    expect("add plan: daily can be put on a note", list(TagLibrary.addPlan("daily", to: [b]).changes[b.id]), "work,daily")

    expect("block: renaming daily", DailyNotes.renameBlock("daily", to: "x")?.title, "\u{201C}#daily\u{201D} cannot be renamed")
    expect("block: renaming onto daily", DailyNotes.renameBlock("x", to: "Daily")?.title, "\u{201C}#daily\u{201D} is reserved")
    expect("block: other names pass", DailyNotes.renameBlock("x", to: "y")?.title, nil)

    runDailyDayTests()
}

private func runDailyDayTests() {
    // MARK: The day

    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // 23:00 on the 8th in São Paulo is already the 9th in UTC.
    let lateEvening = ISO8601DateFormatter().date(from: "2026-10-09T02:00:00Z")!
    expect("day: the calendar's zone decides the day", DailyDay(lateEvening, calendar: gregorian).string, "2026-10-08")
    expect("day: another zone, another day", DailyDay(lateEvening, calendar: utc).string, "2026-10-09")
    expect("day: text", DailyDay(year: 2026, month: 3, day: 7).string, "2026-03-07")
    expect("day: parsed", DailyDay(string: "2026-10-08").map { "\($0.year)/\($0.month)/\($0.day)" }, "2026/10/8")
    expect("day: round trip", DailyDay(string: "2026-03-07")?.string, "2026-03-07")
    for bad in ["", "2026-1-08", "2026-13-01", "2026-00-10", "2026-10-32", "x026-10-08", "2026-10", "2026-10-08-1", " 2026-10-08"] {
        expect("day: \"\(bad)\" is not a day", DailyDay(string: bad)?.string, nil)
    }
    expectTrue("day: later is greater", DailyDay(year: 2026, month: 10, day: 8) > DailyDay(year: 2026, month: 9, day: 30))
    expectTrue("day: year first", DailyDay(year: 2027, month: 1, day: 1) > DailyDay(year: 2026, month: 12, day: 31))
    expectTrue("day: text sorts like the days",
               ["2026-10-08", "2025-12-31", "2026-02-01"].sorted() == ["2025-12-31", "2026-02-01", "2026-10-08"])
    expectTrue("day: back to a date in the same day",
               DailyDay(string: "2026-10-08").flatMap { $0.date(calendar: gregorian) }.map { DailyDay($0, calendar: gregorian).string } == "2026-10-08")

    // MARK: Tags decide the day

    let today = DailyDay(year: 2026, month: 10, day: 8)
    let old = DailyDay(year: 2026, month: 10, day: 2)
    func result(_ r: (day: DailyDay?, kept: Bool)) -> String { "\(r.day?.string ?? "nil") \(r.kept)" }
    expect("reconcile: receiving the tag grants today",
           result(DailyNotes.reconcile(previousTags: ["work"], tags: ["work", "daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("reconcile: a note created with the tag has today",
           result(DailyNotes.reconcile(previousTags: [], tags: ["daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("reconcile: the day does not move afterwards",
           result(DailyNotes.reconcile(previousTags: ["daily"], tags: ["daily", "x"], day: old, kept: false, today: today)), "2026-10-02 false")
    expect("reconcile: nor does the mark",
           result(DailyNotes.reconcile(previousTags: ["daily"], tags: ["daily"], day: old, kept: true, today: today)), "2026-10-02 true")
    expect("reconcile: taking the tag off clears the day and the mark",
           result(DailyNotes.reconcile(previousTags: ["daily"], tags: ["x"], day: old, kept: true, today: today)), "nil false")
    expect("reconcile: putting it back grants today, not the old day",
           result(DailyNotes.reconcile(previousTags: ["x"], tags: ["x", "daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("reconcile: whatever was left behind is replaced when the tag arrives",
           result(DailyNotes.reconcile(previousTags: ["x"], tags: ["daily"], day: old, kept: true, today: today)), "2026-10-08 false")
    expect("reconcile: a daily without a day is given today",
           result(DailyNotes.reconcile(previousTags: ["daily"], tags: ["daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("reconcile: the tag in another spelling counts",
           result(DailyNotes.reconcile(previousTags: ["x"], tags: ["Daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("settled: a daily keeps its day", result(DailyNotes.settled(tags: ["daily"], day: old, kept: true, today: today)), "2026-10-02 true")
    expect("settled: a daily without a day gets today", result(DailyNotes.settled(tags: ["daily"], day: nil, kept: false, today: today)), "2026-10-08 false")
    expect("settled: a day without the tag goes", result(DailyNotes.settled(tags: ["x"], day: old, kept: true, today: today)), "nil false")
    expect("settled: an ordinary note has none", result(DailyNotes.settled(tags: [], day: nil, kept: false, today: today)), "nil false")
}

private struct Daily: DailyItem {
    var id = UUID()
    var tags: [String] = ["daily"]
    var dailyDay: DailyDay?
    var dailyKept = false
    var editedAt = Date(timeIntervalSince1970: 0)
    var isArchived = false
    var isDeleted = false
    var staysOnDeck = false
}

private func day(_ d: Int, month: Int = 10) -> DailyDay { DailyDay(year: 2026, month: month, day: d) }

func runDailyRuleTests() {
    func daily(_ d: Int, month: Int = 10, _ change: (inout Daily) -> Void = { _ in }) -> Daily {
        var item = Daily(dailyDay: day(d, month: month))
        change(&item)
        return item
    }
    func names(_ plan: [UUID], _ items: [Daily], label: [UUID: String]) -> String {
        plan.map { label[$0] ?? "?" }.sorted().joined(separator: ",")
    }
    func plan(_ items: [Daily], open: Set<UUID> = []) -> String {
        var label: [UUID: String] = [:]
        for (i, item) in items.enumerated() { label[item.id] = "\(i)" }
        return names(DailyNotes.archivalPlan(items, open: open), items, label: label)
    }

    // The two most recent days with a daily stay.
    let d5 = daily(5), d6 = daily(6), d7 = daily(7), d8 = daily(8)
    expect("rule: the two most recent days stay, older ones go", plan([d5, d6, d7, d8]), "0,1")
    expect("rule: two days or fewer, nothing goes", plan([d7, d8]), "")
    expect("rule: one day, nothing goes", plan([d8]), "")
    expect("rule: none, nothing goes", plan([]), "")
    expect("rule: several on one day all stay", plan([d7, daily(7), daily(7), d8, daily(8)]), "")
    expect("rule: and all the older ones go", plan([d5, daily(5), daily(6), d7, d8]), "0,1,2")
    expect("rule: days count where dailies are, not on the calendar",
           plan([daily(1), daily(20, month: 9), daily(2), daily(1, month: 8)]), "1,3")
    expect("rule: months and years order correctly",
           plan([Daily(dailyDay: DailyDay(year: 2025, month: 12, day: 31)), daily(1, month: 1), daily(2, month: 1)]), "0")

    // Archived dailies still make a day; deleted ones do not.
    expect("rule: an archived daily still counts as its day",
           plan([d5, d6, daily(8) { $0.isArchived = true }, d7]), "0,1")
    expect("rule: a deleted daily does not make a day",
           plan([d5, d6, d7, daily(8) { $0.isDeleted = true }]), "0")
    expect("rule: a deleted daily is never in the plan", plan([daily(1) { $0.isDeleted = true }, d6, d7, d8]), "1")

    // Who is left alone.
    expect("rule: archived ones are not archived again", plan([daily(5) { $0.isArchived = true }, d6, d7, d8]), "1")
    expect("rule: a daily kept by hand stays", plan([daily(5) { $0.dailyKept = true }, d6, d7, d8]), "1")
    expect("rule: a daily kept on the deck or pinned stays", plan([daily(5) { $0.staysOnDeck = true }, d6, d7, d8]), "1")
    expect("rule: a note without the tag is not a daily", plan([daily(5) { $0.tags = ["work"] }, d6, d7, d8]), "1")
    expect("rule: a note without a day is not a daily", plan([Daily(dailyDay: nil), d6, d7, d8]), "1")
    expect("rule: another spelling of the tag still counts", plan([daily(5) { $0.tags = ["Daily"] }, d6, d7, d8]), "0,1")

    // Open and floating notes wait for their window to close.
    let all = [d5, d6, d7, d8]
    expect("rule: an open note waits", plan(all, open: [d5.id]), "1")
    expect("rule: all open, none go yet", plan(all, open: [d5.id, d6.id]), "")
    expect("rule: closed, it goes", plan(all, open: []), "0,1")
    expect("rule: an open note on a retained day changes nothing", plan(all, open: [d8.id]), "0,1")

    // Same answer however the notes are listed, and the second run is empty.
    expectTrue("rule: the order of the notes does not matter",
               Set(DailyNotes.archivalPlan(all.reversed())) == Set(DailyNotes.archivalPlan(all))
               && DailyNotes.archivalPlan(all.shuffled()) == DailyNotes.archivalPlan(all))
    let ids = DailyNotes.archivalPlan(all)
    expect("rule: the plan is sorted, so it is the same on every Mac",
           ids.map(\.uuidString).joined(separator: ","), ids.map(\.uuidString).sorted().joined(separator: ","))
    var applied = all
    for index in applied.indices where ids.contains(applied[index].id) { applied[index].isArchived = true }
    expect("rule: running it again changes nothing", String(DailyNotes.archivalPlan(applied).count), "0")
    expect("rule: it never touches what stays", String(applied.filter { !$0.isArchived }.count), "2")
    var twoMacs = all.shuffled()
    for index in twoMacs.indices where DailyNotes.archivalPlan(all).contains(twoMacs[index].id) { twoMacs[index].isArchived = true }
    expect("rule: two Macs with the same notes end the same",
           twoMacs.filter(\.isArchived).map(\.id).sorted { $0.uuidString < $1.uuidString }.map(\.uuidString).joined(separator: ","),
           applied.filter(\.isArchived).map(\.id).sorted { $0.uuidString < $1.uuidString }.map(\.uuidString).joined(separator: ","))

    // Bringing one back by hand.
    var items = [d5, d6, d7, d8]
    expectTrue("restore: an old daily is remembered", DailyNotes.restoreKeeps(d5.id, in: items))
    expectTrue("restore: one still within its days is not", !DailyNotes.restoreKeeps(d8.id, in: items))
    expectTrue("restore: nor the other retained day", !DailyNotes.restoreKeeps(d7.id, in: items))
    expectTrue("restore: a note that is not a daily is not", !DailyNotes.restoreKeeps(UUID(), in: items))
    items[0].isArchived = true
    expectTrue("restore: an archived old daily, found by id", DailyNotes.restoreKeeps(items[0].id, in: items))
    items[0].isArchived = false
    items[0].dailyKept = true
    expect("restore: once remembered, the rule leaves it", String(DailyNotes.archivalPlan(items).contains(items[0].id)), "false")
    expect("restore: and still archives its neighbours", String(DailyNotes.archivalPlan(items).count), "1")
}

func runTodaysDailyTests() {
    func daily(_ d: Int, at hour: Int = 0, _ change: (inout Daily) -> Void = { _ in }) -> Daily {
        var item = Daily(dailyDay: day(d))
        item.editedAt = Date(timeIntervalSince1970: Double(hour) * 3600)
        change(&item)
        return item
    }
    let today = day(8)
    expectTrue("today: none, so nothing to open", DailyNotes.todays([daily(7), daily(9)], today: today) == nil)
    expectTrue("today: not even without dailies", DailyNotes.todays([Daily](), today: today) == nil)
    let first = daily(8, at: 1), second = daily(8, at: 5), third = daily(8, at: 3)
    expectTrue("today: the one edited last", DailyNotes.todays([first, second, third], today: today)?.id == second.id)
    expectTrue("today: whatever the order", DailyNotes.todays([third, second, first], today: today)?.id == second.id)
    expectTrue("today: only today's", DailyNotes.todays([daily(7, at: 9), first], today: today)?.id == first.id)
    let archived = daily(8, at: 9) { $0.isArchived = true }
    expectTrue("today: an archived one is opened too, not replaced", DailyNotes.todays([first, archived], today: today)?.id == archived.id)
    expectTrue("today: a deleted one is not", DailyNotes.todays([first, daily(8, at: 9) { $0.isDeleted = true }], today: today)?.id == first.id)
    expectTrue("today: a note without the tag is not", DailyNotes.todays([daily(8, at: 9) { $0.tags = ["x"] }], today: today) == nil)
    let a = daily(8, at: 2), b = daily(8, at: 2)
    expectTrue("today: a tie is broken by id, the same on every Mac",
               DailyNotes.todays([a, b], today: today)?.id == DailyNotes.todays([b, a], today: today)?.id)

    // MARK: The title

    let date = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func title(_ id: String) -> String { DailyNotes.title(for: date, locale: Locale(identifier: id), calendar: calendar) }
    expect("title: Brazil writes day first", title("pt_BR"), "Daily 08/10")
    expect("title: the US writes month first", title("en_US"), "Daily 10/8")
    expect("title: Britain", title("en_GB"), "Daily 08/10")
    expect("title: Germany", title("de_DE"), "Daily 8.10.")
    expectTrue("title: no year, no time", !title("pt_BR").contains("2026") && !title("pt_BR").contains(":"))
    var saoPaulo = calendar
    saoPaulo.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    let night = ISO8601DateFormatter().date(from: "2026-10-09T02:00:00Z")!
    expect("title: the local day, not UTC's", DailyNotes.title(for: night, locale: Locale(identifier: "pt_BR"), calendar: saoPaulo), "Daily 08/10")
}

func runDailyHistoryTests() {
    // MARK: The Daily shelf

    let notes = [
        Item(tags: ["daily"]),                                  // on the deck
        Item(tags: ["Daily", "work"], isArchived: true),        // archived daily
        Item(tags: ["daily"], isArchived: true),                // archived daily
        Item(tags: ["work"], isArchived: true),                 // archived, ordinary
        Item(tags: ["work"]),
        Item(tags: ["daily"], isDeleted: true),
    ]
    let index = TagLibrary.index(notes)
    expect("shelf: every daily, deck and archive", String(index.daily), "3")
    expect("shelf: count(of:)", String(index.count(of: .daily)), "3")
    expect("shelf: Archived leaves the archived dailies out", String(index.archived), "1")
    expect("shelf: the deck is unchanged", String(index.deck), "2")
    expect("shelf: All still counts everything live", String(index.all), "5")
    func count(_ selection: NoteSelection) -> String { String(TagLibrary.filter(notes, by: selection).count) }
    expect("shelf: Daily lists them all", count(.library(.daily)), "3")
    expect("shelf: Archived leaves them out", count(.library(.archived)), "1")
    expect("shelf: the deck is unchanged in the list", count(.library(.deck)), "2")
    expect("shelf: All still lists them", count(.library(.all)), "5")
    expect("shelf: a tag still reaches an archived daily", count(.tag("work")), "3")
    expect("shelf: titled Daily", NoteSelection.library(.daily).title, "Daily")
    expect("shelf: with a calendar", NoteLibrary.daily.symbolName, "calendar")
    expect("shelf: in the Library section after the others", NoteLibrary.allCases.map(\.rawValue).joined(separator: ","), "all,deck,archived,daily")
    expect("shelf: storage round-trips", NoteSelection(storageValue: NoteSelection.library(.daily).storageValue)?.storageValue, "library:daily")
    expect("shelf: the tag as a selection is the shelf", NoteSelection(storageValue: "tag:daily")?.storageValue, "library:daily")
    expect("shelf: whatever its spelling", NoteSelection(storageValue: "tag:#Daily")?.storageValue, "library:daily")
    expect("shelf: no daily at all", String(TagLibrary.index([Item(tags: ["x"])]).daily), "0")

    // MARK: Grouped by day

    func daily(_ d: Int, month: Int = 10, hour: Int = 0, _ change: (inout Daily) -> Void = { _ in }) -> Daily {
        var item = Daily(dailyDay: day(d, month: month))
        item.editedAt = Date(timeIntervalSince1970: Double(hour) * 3600)
        change(&item)
        return item
    }
    let a = daily(8, hour: 1), b = daily(8, hour: 5), c = daily(7, hour: 9), d = daily(2, month: 9, hour: 2)
    let plain = daily(8) { $0.tags = ["work"] }
    let gone = daily(8) { $0.isDeleted = true }
    let groups = DailyNotes.groups([c, plain, a, d, gone, b])
    expect("groups: the latest day first", groups.map(\.day.string).joined(separator: ","), "2026-10-08,2026-10-07,2026-09-02")
    expectTrue("groups: within a day, the one edited last first", groups[0].items.map(\.id) == [b.id, a.id])
    expect("groups: a note that is not a daily, or is deleted, is left out", String(groups.flatMap(\.items).count), "4")
    expect("groups: none", String(DailyNotes.groups([Daily]()).count), "0")
    expectTrue("groups: archived dailies are grouped like the rest",
               DailyNotes.groups([daily(8) { $0.isArchived = true }, daily(7)]).map(\.items.count) == [1, 1])
    expectTrue("groups: the same whatever the order",
               DailyNotes.groups([a, b, c, d]).map(\.items).map { $0.map(\.id) } == DailyNotes.groups([d, c, b, a]).map(\.items).map { $0.map(\.id) })
}

func runDailyMenuTests() {
    func daily(_ d: Int, month: Int = 10, hour: Int = 0, _ change: (inout Daily) -> Void = { _ in }) -> Daily {
        var item = Daily(dailyDay: day(d, month: month))
        item.editedAt = Date(timeIntervalSince1970: Double(hour) * 3600)
        change(&item)
        return item
    }
    func ids(_ groups: [DailyNotes.DayGroup<Daily>]) -> [UUID] { groups.flatMap { $0.items.map(\.id) } }

    let me = daily(20)
    let sameDay = daily(20, hour: 9)
    let days = (1...14).map { daily($0) }
    let all = [me, sameDay] + days
    let menu = DailyNotes.previous(before: day(20), in: all, excluding: me.id)
    expect("menu: ten", String(ids(menu).count), "10")
    expect("menu: the ten latest days, latest first", menu.map(\.day.string).joined(separator: ","),
           (5...14).reversed().map { "2026-10-\(String(format: "%02d", $0))" }.joined(separator: ","))
    expectTrue("menu: not the note itself, nor another of its own day",
               !ids(menu).contains(me.id) && !ids(menu).contains(sameDay.id))
    expect("menu: fewer when there are fewer", String(ids(DailyNotes.previous(before: day(3), in: all, excluding: me.id)).count), "2")
    expect("menu: none before the first", String(DailyNotes.previous(before: day(1), in: all, excluding: me.id).count), "0")
    let crowded = [daily(9, hour: 1), daily(9, hour: 2), daily(9, hour: 3), daily(8)]
    let cut = DailyNotes.previous(before: day(10), in: crowded, excluding: UUID(), limit: 2)
    expect("menu: the limit counts notes, cutting a day short", cut.map { "\($0.day.day):\($0.items.count)" }.joined(separator: ","), "9:2")
    expectTrue("menu: within a day, the one edited last first", cut[0].items[0].editedAt > cut[0].items[1].editedAt)
    expect("menu: archived ones are listed too",
           String(ids(DailyNotes.previous(before: day(20), in: [daily(3) { $0.isArchived = true }], excluding: me.id)).count), "1")
    expect("menu: deleted ones are not",
           String(ids(DailyNotes.previous(before: day(20), in: [daily(3) { $0.isDeleted = true }], excluding: me.id)).count), "0")
    expect("menu: the limit", String(DailyNotes.menuLimit), "10")
}
