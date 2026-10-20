import AppKit
import CryptoKit

/// Unfinished tasks from the last daily, end to end: a new daily made the way
/// the calendar button, ⌥⌘Y and the menu make it (`openTodaysDaily`), in each
/// of the three modes.
@MainActor
func runCarryOverTests() {
    final class Clock { var date = Date() }
    let calendar = Calendar.current
    func noon(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))! }
    let previousMode = AppSettings.shared.carryOverMode
    defer { AppSettings.shared.carryOverMode = previousMode }

    let thursdayBody = """
    # Thursday
    - [ ] Send the invoice
        - [ ] Attach the receipt
    - [x] Book the room
    - [ ] Pay rent
    Some notes.
    ```
    - [ ] not a task, it is code
    ```
    """
    let template = "## Today\n- [ ] pay  RENT\n- [ ] "

    /// A store whose Thursday has two dailies, and a coordinator on Monday.
    func world(_ mode: CarryOverMode, second: String? = "- [ ] Water the plants\n- [ ] send the invoice",
               first: String = thursdayBody) -> (NoteStore, AppCoordinator, Clock, [UUID]) {
        let clock = Clock()
        clock.date = noon(15)
        let url = scratchDirectory().appendingPathComponent("carry-\(UUID().uuidString).sqlite")
        let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)), now: { clock.date })
        var ids = [try! store.create(title: "Daily 15/10", body: first, tags: ["daily"]).id]
        if let second {
            clock.date = noon(15).addingTimeInterval(600)
            ids.append(try! store.create(title: "Daily 15/10", body: second, tags: ["daily"]).id)
        }
        store.setDailyTemplate(template)
        clock.date = noon(19)    // Monday
        AppSettings.shared.carryOverMode = mode
        return (store, AppCoordinator(store: store), clock, ids)
    }
    func todays(_ store: NoteStore) -> Note? { DailyNotes.todays(store.notes, today: store.today) }
    let block = """
    ### From Thursday, 15/10
    - [ ] Send the invoice
        - [ ] Attach the receipt
    - [ ] Water the plants
    """

    // Don't bring.
    do {
        let (store, coordinator, _, earlier) = world(.never)
        coordinator.openTodaysDaily()
        let daily = todays(store)!
        expect("never: the new daily is just the template", daily.body, template)
        expectTrue("never: no banner", coordinator.noteWindowForTesting(daily.id)?.carryOverOfferForTesting == nil)
        expect("never: Thursday untouched", store.note(id: earlier[0])?.body, thursdayBody)
        closeAll()
    }

    // Ask each time, Not now.
    do {
        let (store, coordinator, _, earlier) = world(.ask)
        coordinator.openTodaysDaily()
        let daily = todays(store)!
        let window = coordinator.noteWindowForTesting(daily.id)
        let banner = window?.carryOverOfferForTesting
        expect("ask: three tasks, from both of Thursday's dailies, none the template has", banner.map { String($0.count) }, "3")
        expect("ask: the question", banner?.message, "3 unfinished tasks from Thursday. Bring them?")
        expect("ask: nothing brought before the answer", store.note(id: daily.id)?.body, template)
        window?.answerCarryOverForTesting(bring: false)
        expectTrue("ask: Not now takes the banner away", window?.carryOverOfferForTesting == nil)
        expect("ask: and brings nothing", store.note(id: daily.id)?.body, template)
        window?.answerCarryOverForTesting(bring: true)
        expect("ask: an answer is given once", store.note(id: daily.id)?.body, template)
        closeAll()
        coordinator.openTodaysDaily()
        expectTrue("ask: opening the daily again does not offer again",
                   coordinator.noteWindowForTesting(daily.id)?.carryOverOfferForTesting == nil)
        expect("ask: Thursday untouched", store.note(id: earlier[0])?.body, thursdayBody)
        closeAll()
    }

    // Ask each time, Bring.
    do {
        let (store, coordinator, _, earlier) = world(.ask)
        coordinator.openTodaysDaily()
        let daily = todays(store)!
        let window = coordinator.noteWindowForTesting(daily.id)
        window?.answerCarryOverForTesting(bring: true)
        store.waitUntilSaved()
        expect("bring: at the end, under the day, subitems indented", store.note(id: daily.id)?.body, template + "\n\n" + block + "\n")
        expectTrue("bring: the banner is gone", window?.carryOverOfferForTesting == nil)
        expect("bring: the first Thursday daily untouched", store.note(id: earlier[0])?.body, thursdayBody)
        expect("bring: the second too", store.note(id: earlier[1])?.body, "- [ ] Water the plants\n- [ ] send the invoice")
        closeAll()
    }

    // Bring automatically, and Undo.
    do {
        let (store, coordinator, _, earlier) = world(.automatic)
        coordinator.openTodaysDaily()
        let daily = todays(store)!
        store.waitUntilSaved()
        expect("automatic: brought at once", store.note(id: daily.id)?.body, template + "\n\n" + block + "\n")
        expectTrue("automatic: no banner", coordinator.noteWindowForTesting(daily.id)?.carryOverOfferForTesting == nil)
        expect("automatic: the notice", coordinator.undoToastForTesting.messageForTesting, "3 tasks brought from Thursday")
        expectTrue("automatic: the notice is wide enough for it", coordinator.undoToastForTesting.widthForTesting >= 300)
        coordinator.undoToastForTesting.undoForTesting?()
        store.waitUntilSaved()
        expect("automatic: Undo takes them out again", store.note(id: daily.id)?.body, template + "\n")
        expect("automatic: Thursday untouched", store.note(id: earlier[0])?.body, thursdayBody)
        closeAll()
    }

    // Nothing unfinished: no banner, no notice.
    do {
        let (store, coordinator, _, _) = world(.ask, second: nil, first: "- [x] Done\nJust text")
        coordinator.openTodaysDaily()
        expectTrue("none: no banner", coordinator.noteWindowForTesting(todays(store)!.id)?.carryOverOfferForTesting == nil)
        closeAll()
        let (store2, coordinator2, _, _) = world(.automatic, second: nil, first: "- [x] Done")
        coordinator2.openTodaysDaily()
        expect("none: nothing brought", todays(store2)?.body, template)
        expect("none: no notice", coordinator2.undoToastForTesting.messageForTesting ?? "none", "none")
        closeAll()
    }

    // Only the day's first daily is offered: a note tagged daily today first.
    do {
        let (store, coordinator, _, _) = world(.automatic)
        let tagged = try! store.create(title: "Standup", body: "", tags: ["daily"])
        coordinator.openTodaysDaily()
        expect("first only: today already had a daily, which is opened as it is", store.note(id: tagged.id)?.body, "")
        expectTrue("first only: no notice", coordinator.undoToastForTesting.messageForTesting == nil)
        closeAll()
    }

    // The heading and the notice in both languages.
    let thursday = DailyDay(year: 2026, month: 10, day: 15)
    expect("dates: English", DailyCarryOver.heading(for: thursday, locale: Locale(identifier: "en_BR"), calendar: calendar, language: "en"),
           "From Thursday, 15/10")
    expect("dates: Portuguese", DailyCarryOver.heading(for: thursday, locale: Locale(identifier: "pt_BR"), calendar: calendar, language: "pt-BR"),
           "De quinta-feira, 15/10")
    expect("words: the banner in Portuguese",
           String(format: L("%d unfinished tasks from %@. Bring them?", in: "pt-BR"), 3, DailyCarryOver.weekday(of: thursday, locale: Locale(identifier: "pt_BR"), calendar: calendar)),
           "3 tarefas pendentes de quinta-feira. Trazer?")
    expect("words: the notice in Portuguese",
           String(format: L("%d tasks brought from %@", in: "pt-BR"), 3, "quinta-feira"), "3 tarefas trazidas de quinta-feira")

    func closeAll() {
        NSApp.windows.compactMap { $0 as? NoteWindow }.forEach { $0.orderOut(nil) }
    }
}
