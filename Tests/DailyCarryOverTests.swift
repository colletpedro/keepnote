import Foundation

func runDailyCarryOverRuleTests() {
    let thursday = DailyDay(year: 2026, month: 10, day: 16)
    let friday = DailyDay(year: 2026, month: 10, day: 17)
    let monday = DailyDay(year: 2026, month: 10, day: 20)
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
    expect("carry: from Thursday", offer?.day.string, "2026-10-16")
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
