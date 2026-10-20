import Foundation

func runDailyCarryOverRuleTests() {
    let thursday = DailyDay(year: 2026, month: 10, day: 15)
    let friday = DailyDay(year: 2026, month: 10, day: 16)
    let monday = DailyDay(year: 2026, month: 10, day: 19)
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + s) }
    func source(_ day: DailyDay, _ body: String, _ order: Double = 0) -> DailyCarryOver.Source {
        .init(day: day, createdAt: at(order), body: body)
    }
    func lines(_ offer: DailyCarryOver.Offer?) -> String { offer?.lines.joined(separator: "\n") ?? "none" }

    let body = """
    # Thursday
    Notes from the call, nothing to do here.
    - [ ] Send the invoice
    - [x] Book the room
    - [ ] Review the draft
        - [ ] Section two
        - [x] Section one
            - [ ] A footnote
    - plain bullet
    1. [ ] Numbered task
    ```
    - [ ] inside a code block
    ```
    - [ ]
    """
    let offer = DailyCarryOver.offer(for: monday, sources: [source(thursday, body)], newBody: "", othersToday: 0)
    expect("carry: unticked items, subitems indented under their parent", lines(offer), """
    - [ ] Send the invoice
    - [ ] Review the draft
        - [ ] Section two
        - [ ] A footnote
    - [ ] Numbered task
    """)
    expect("carry: from Thursday", offer?.day.string, "2026-10-15")
    expect("carry: five of them", offer.map { String($0.count) }, "5")

    // Only the last day before today with a daily; every daily of that day.
    let many = [
        source(thursday, "- [ ] From Thursday"),
        source(friday, "- [ ] Second daily of Friday", 20),
        source(friday, "- [ ] First daily of Friday\n- [ ] send  THE invóice", 10),
        source(monday, "- [ ] Today, already", 30),
    ]
    expect("carry: the last day before, all its dailies in order",
           lines(DailyCarryOver.offer(for: monday, sources: many, newBody: "", othersToday: 0)),
           "- [ ] First daily of Friday\n- [ ] send  THE invóice\n- [ ] Second daily of Friday")
    expect("carry: a day with nothing before it", lines(DailyCarryOver.offer(for: thursday, sources: many, newBody: "", othersToday: 0)), "none")

    // Duplicates: between the dailies, and with what the template wrote.
    let repeated = [
        source(friday, "- [ ] Call Ana\n- [ ] Pay rent", 1),
        source(friday, "- [ ]   call   ána \n- [ ] Water the plants", 2),
    ]
    expect("carry: the same item twice comes once",
           lines(DailyCarryOver.offer(for: monday, sources: repeated, newBody: "", othersToday: 0)),
           "- [ ] Call Ana\n- [ ] Pay rent\n- [ ] Water the plants")
    expect("carry: an item the template already has is left out",
           lines(DailyCarryOver.offer(for: monday, sources: repeated, newBody: "## Today\n- [ ] PAY RENT\n- [ ] ", othersToday: 0)),
           "- [ ] Call Ana\n- [ ] Water the plants")
    expect("carry: everything already in the template: nothing to offer",
           lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "- [ ] Pay rent")], newBody: "- [ ] pay rent", othersToday: 0)),
           "none")
    expect("carry: a repeated parent's subitem moves up",
           lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "- [ ] Pay rent\n    - [ ] Ask for the receipt")],
                                      newBody: "- [ ] Pay rent", othersToday: 0)),
           "- [ ] Ask for the receipt")

    // Nothing unfinished, or not the first daily of the day.
    expect("carry: all ticked, nothing", lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "- [x] Done\n- [X] Done too")], newBody: "", othersToday: 0)), "none")
    expect("carry: plain text only, nothing", lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "Just words.\n- a bullet")], newBody: "", othersToday: 0)), "none")
    expect("carry: no earlier daily, nothing", lines(DailyCarryOver.offer(for: monday, sources: [], newBody: "", othersToday: 0)), "none")
    expect("carry: only the first daily of a day is offered",
           lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "- [ ] Pay rent")], newBody: "", othersToday: 1)), "none")
    expect("carry: a tab is a level", lines(DailyCarryOver.offer(for: monday, sources: [source(friday, "- [ ] A\n\t- [ ] B")], newBody: "", othersToday: 0)),
           "- [ ] A\n    - [ ] B")
    expect("carry: compared without case, accents or spaces", DailyCarryOver.key("  Revisar   o RASCUNHO "), DailyCarryOver.key("revisar o rascunho"))
}

func runDailyCarryOverInsertTests() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let thursday = DailyDay(year: 2026, month: 10, day: 15)
    let english = Locale(identifier: "en_BR")
    let american = Locale(identifier: "en_US")
    let portuguese = Locale(identifier: "pt_BR")
    expect("heading: in English", DailyCarryOver.heading(for: thursday, locale: english, calendar: utc), "From Thursday, 15/10")
    expect("heading: in the US order", DailyCarryOver.heading(for: thursday, locale: american, calendar: utc), "From Thursday, 10/15")
    // The key is English in this runner; the Portuguese words come from the
    // table, the date from the locale.
    expect("heading: the day in Portuguese", DailyCarryOver.weekday(of: thursday, locale: portuguese, calendar: utc), "quinta-feira")
    expect("heading: day and month in Portuguese",
           DailyCarryOver.heading(for: thursday, locale: portuguese, calendar: utc), "From quinta-feira, 15/10")
    expect("weekday: in English", DailyCarryOver.weekday(of: thursday, locale: english, calendar: utc), "Thursday")

    let offer = DailyCarryOver.Offer(day: thursday, lines: ["- [ ] Send the invoice", "    - [ ] Attach the receipt"])
    let heading = "From Thursday, 15/10"
    let template = "## Today\n- [ ] \n\n"
    let inserted = DailyCarryOver.inserting(offer, into: template, heading: heading)
    expect("insert: at the end, under the day", inserted,
           "## Today\n- [ ] \n\n### From Thursday, 15/10\n- [ ] Send the invoice\n    - [ ] Attach the receipt\n")
    expect("insert: into an empty daily", DailyCarryOver.inserting(offer, into: "", heading: heading),
           "### From Thursday, 15/10\n- [ ] Send the invoice\n    - [ ] Attach the receipt\n")
    expect("undo: the block comes out again", DailyCarryOver.removing(offer, from: inserted, heading: heading), "## Today\n- [ ] \n")
    expect("undo: with text typed after it, that stays",
           DailyCarryOver.removing(offer, from: inserted + "More I wrote.\n", heading: heading), "## Today\n- [ ] \n\nMore I wrote.\n")
    let edited = inserted.replacingOccurrences(of: "Send the invoice", with: "Send the invoice today")
    expect("undo: a block that was edited is left alone", DailyCarryOver.removing(offer, from: edited, heading: heading), edited)
}
