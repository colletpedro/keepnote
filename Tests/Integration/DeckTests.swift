import AppKit

// The deck as built for this Mac's main screen, driven with mouse events the
// way AppKit delivers them. Reduce Motion is on, so every spring lands at once
// and frames can be read straight after an event.

@MainActor
final class DeckFixture {
    let controller: EdgePanelController
    let notes: [Note]

    convenience init(count: Int) {
        self.init(notes: (0..<count).map { Note(title: "Note \($0)", body: "", sortIndex: $0) })
    }

    init(notes: [Note]) {
        Motion.reduceMotionOverride = true
        self.notes = notes
        controller = EdgePanelController(screen: NSScreen.main!)
        controller.update(notes: notes)
        controller.cursorDidEnter()
    }

    var stack: EdgeStackView { controller.stackViewForTesting }

    /// The cards, in the deck's order, wherever in the deck they were put.
    var cards: [NoteCardView] {
        func collect(_ view: NSView) -> [NoteCardView] {
            (view as? NoteCardView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        let order = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.id, $0) })
        return collect(stack).sorted { (order[$0.noteID] ?? 0) < (order[$1.noteID] ?? 0) }
    }

    /// The middle of the part of tab `index` that shows, in window coordinates.
    func pointOnSlice(_ index: Int) -> NSPoint {
        let card = cards[index]
        return card.convert(NSPoint(x: card.bounds.midX + 4, y: card.bounds.maxY - card.visibleSlice / 2), to: nil)
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: stack.window?.windowNumber ?? 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func move(to point: NSPoint) { stack.mouseMoved(with: event(.mouseMoved, at: point)) }

    func close() {
        controller.collapse()
        controller.hidePanel()
        Motion.reduceMotionOverride = nil
    }
}

@MainActor
func runDeckTests() {
    let deck = DeckFixture(count: 30)
    let cards = deck.cards
    expect("deck: a tab per note", String(cards.count), "30")
    let resting = cards.map(\.frame)
    expectTrue("deck: tabs overlap at thirty", resting[0].minY < resting[1].maxY)
    expectTrue("deck: full-height tabs", resting.allSatisfy { $0.height == EdgeMetrics.tabHeight })
    expectTrue("deck: dealt in to where the geometry puts them", resting == deck.stack.geometry.frames)

    let point = deck.pointOnSlice(12)
    deck.move(to: point)
    expectTrue("hover: the tab under the cursor", deck.stack.hoveredNoteID == deck.notes[12].id)
    expect("hover: whole", String(Double(cards[12].visibleSlice)), String(Double(EdgeMetrics.tabHeight)))
    expect("hover: reaches 12 pt further", String(Double(cards[12].frame.width)), String(Double(EdgeMetrics.tabWidth + 12)))
    let inClip = cards[12].superview!.convert(point, from: nil)
    expectTrue("hover: still under the cursor", cards[12].frame.contains(inClip))
    expectTrue("hover: neighbours open part of the way",
               cards[11].visibleSlice > cards[5].visibleSlice && cards[11].visibleSlice < EdgeMetrics.tabHeight)
    expectTrue("hover: first and last tabs stay", cards[0].frame == resting[0] && cards[29].frame == resting[29])

    deck.move(to: NSPoint(x: point.x, y: point.y - 20))
    expectTrue("hover: moving within the open tab keeps it", deck.stack.hoveredNoteID == deck.notes[12].id)

    deck.move(to: deck.pointOnSlice(13))
    expectTrue("hover: onto the neighbour below", deck.stack.hoveredNoteID == deck.notes[13].id)

    deck.stack.mouseExited(with: deck.event(.mouseMoved, at: .zero))
    expectTrue("hover: leaving the deck closes it up", deck.stack.hoveredNoteID == nil && cards.map(\.frame) == resting)
    deck.close()
}

@MainActor
final class DeckDelegate: EdgePanelControllerDelegate {
    var activated: [UUID] = []
    var newNotes = 0
    var dailies = 0
    func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?) { activated.append(id) }
    func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID) {}
    func edgePanelDidRequestNewNote(_ controller: EdgePanelController) { newNotes += 1 }
    func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController) { dailies += 1 }
    func edgePanelDidRequestAllNotes(_ controller: EdgePanelController) {}
    func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu? { nil }
}

@MainActor
func runDeckClickTests() {
    let deck = DeckFixture(count: 30)
    let delegate = DeckDelegate()
    deck.controller.delegate = delegate

    /// A click where AppKit would deliver it: to whatever the deck hit-tests.
    func click(_ point: NSPoint) -> UUID? {
        delegate.activated.removeAll()
        let target = deck.stack.hitTest(deck.stack.superview?.convert(point, from: nil) ?? point)
        target?.mouseDown(with: deck.event(.leftMouseDown, at: point))
        return delegate.activated.last
    }

    var resting = true
    for index in 0..<30 where click(deck.pointOnSlice(index)) != deck.notes[index].id { resting = false }
    expectTrue("click: every visible slice opens its own note, deck at rest", resting)

    deck.move(to: deck.pointOnSlice(10))
    var open = true
    for index in 0..<30 where click(deck.pointOnSlice(index)) != deck.notes[index].id { open = false }
    expectTrue("click: and with a tab open", open)

    // The peek follows the open tab.
    deck.move(to: deck.pointOnSlice(20))
    let peek = deck.controller.peekForTesting
    let tab = deck.stack.screenFrame(forNoteID: deck.notes[20].id)!
    expectTrue("peek: shows the open tab's note", peek.noteID == deck.notes[20].id)
    let screen = NSScreen.main!.visibleFrame
    let centred = abs(peek.frame.midY - tab.midY) < 1
    let clamped = peek.frame.minY <= screen.minY + 8.5 || peek.frame.maxY >= screen.maxY - 8.5
    expectTrue("peek: centred on the open tab (or held on screen)", centred || clamped)
    expectTrue("peek: the open tab's frame is where it comes to rest",
               tab == deck.stack.window!.convertToScreen(deck.cards[20].convert(deck.cards[20].bounds, to: nil)))
    deck.close()
}

@MainActor
func runDeckUpdateTests() {
    let deck = DeckFixture(count: 24)
    Motion.reduceMotionOverride = false
    let stack = deck.stack
    func onScreen(_ card: NoteCardView) -> NSRect {
        card.window!.convertToScreen(card.convert(card.bounds, to: nil))
    }
    spin(0.8)
    let before = Dictionary(uniqueKeysWithValues: deck.cards.map { ($0.noteID, $0) })
    let screenBefore = before.mapValues(onScreen)
    let stepBefore = stack.geometry.step

    // A new note goes on top, as the store puts it.
    let created = Note(title: "New", body: "", sortIndex: -1)
    deck.controller.update(notes: [created] + deck.notes)
    let after = deck.cards
    expect("add: one more tab", String(after.count), "25")
    expectTrue("add: the step closes up", stack.geometry.step < stepBefore)
    expectTrue("add: the other tabs are the same cards", after.dropFirst().allSatisfy { before[$0.noteID] === $0 })
    expectTrue("add: none of them jumps", after.dropFirst().allSatisfy { abs(onScreen($0).minY - screenBefore[$0.noteID]!.minY) < 0.5 })
    expectTrue("add: they are on their way to the new step",
               after.enumerated().allSatisfy { $1.targetFrame == stack.geometry.frames[$0] })
    expectTrue("add: the new tab comes in from the edge", after[0].frame.minX >= stack.geometry.frames[0].maxX - 0.5)
    spin(1.2)
    expectTrue("add: and they settle there", after.enumerated().allSatisfy { $1.frame == stack.geometry.frames[$0] })

    // Deleting one in the middle.
    let removed = deck.notes[10].id
    deck.controller.update(notes: [created] + deck.notes.filter { $0.id != removed })
    expectTrue("delete: the step opens up again", abs(stack.geometry.step - stepBefore) < 0.01)
    expectTrue("delete: the removed tab leaves", !deck.cards.contains { $0.noteID == removed && $0.alphaValue > 0.99 && $0.targetFrame.minX < 74 })
    spin(1.2)
    expect("delete: and is gone", String(deck.cards.count), "24")
    expectTrue("delete: the rest settle at the new step",
               deck.cards.enumerated().allSatisfy { $1.frame == stack.geometry.frames[$0] })
    deck.close()
}

// MARK: - The round buttons under the deck

@MainActor
func runDeckButtonTests() {
    for count in [2, 30] {
        let deck = DeckFixture(count: count)
        let delegate = DeckDelegate()
        deck.controller.delegate = delegate
        let buttons = deck.stack.subviews.compactMap { $0 as? PlusButtonView }
        let plus = buttons.first { $0.glyph == .plus }
        let daily = buttons.first { $0.glyph == .calendar }
        expectTrue("buttons (\(count)): a plus and a calendar", plus != nil && daily != nil && buttons.count == 2)
        guard let plus, let daily else { deck.close(); continue }
        expectTrue("buttons (\(count)): side by side, the calendar to the left", daily.frame.maxX < plus.frame.minX && daily.frame.minY == plus.frame.minY)
        expectTrue("buttons (\(count)): apart", plus.frame.minX - daily.frame.maxX >= 4)
        expectTrue("buttons (\(count)): inside the deck", daily.frame.minX >= 0 && plus.frame.maxX <= deck.stack.bounds.width)
        daily.mouseEntered(with: deck.event(.mouseMoved, at: .zero))
        expect("buttons (\(count)): hovering the calendar names it", deck.stack.hoverLabelForTesting.textForTesting, "adicionar daily")
        daily.mouseExited(with: deck.event(.mouseMoved, at: .zero))
        expectTrue("buttons (\(count)): and leaving takes the label away", !deck.stack.hoverLabelForTesting.isShowing)
        plus.mouseEntered(with: deck.event(.mouseMoved, at: .zero))
        expectTrue("buttons (\(count)): the plus has no label", !deck.stack.hoverLabelForTesting.isShowing)
        plus.mouseExited(with: deck.event(.mouseMoved, at: .zero))

        func click(_ button: PlusButtonView) {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let target = deck.stack.hitTest(deck.stack.superview?.convert(point, from: nil) ?? point)
            target?.mouseDown(with: deck.event(.leftMouseDown, at: point))
        }
        click(daily)
        expect("buttons (\(count)): the calendar asks for today's daily", "\(delegate.dailies) \(delegate.newNotes)", "1 0")
        click(plus)
        expect("buttons (\(count)): the plus still makes a new note", "\(delegate.dailies) \(delegate.newNotes)", "1 1")
        deck.close()
    }
}

@MainActor
func runDailyMarkTests() {
    var note = Note(title: "Daily 08/10", body: "", tags: ["daily"], dailyDay: DailyDay(year: 2026, month: 10, day: 8))
    let card = NoteCardView(note: note, height: EdgeMetrics.tabHeight)
    expectTrue("mark: a daily's tab carries the calendar", card.isDaily)
    note.tags = ["work"]
    card.show(note)
    expectTrue("mark: gone with the tag", !card.isDaily)
    note.tags = ["daily"]
    card.show(note)
    expectTrue("mark: and back", card.isDaily)
    expectTrue("mark: an ordinary tab has none", !NoteCardView(note: Note(title: "x"), height: EdgeMetrics.tabHeight).isDaily)
}


// MARK: - Pinned notes on the deck

@MainActor
func runPinnedDeckTests() {
    var notes = (0..<30).map { Note(title: "Note \($0)", body: "", sortIndex: $0) }
    let pinnedIndexes = [12, 5, 20]
    for (rank, index) in pinnedIndexes.enumerated() {
        notes[index].pinnedAt = Date(timeIntervalSince1970: 1_790_000_000 + Double(rank))
        notes[index].keepOnDeck = true
    }
    let deck = DeckFixture(notes: notes)
    let arranged = PinnedDeck.arrange(notes)
    let geometry = deck.stack.geometry
    func card(_ note: Note) -> NoteCardView { deck.cards.first { $0.noteID == note.id }! }

    expect("pinned deck: a tab per note", String(deck.cards.count), "30")
    expect("pinned deck: three pinned", String(arranged.pinned), "3")
    expectTrue("pinned deck: every tab where the geometry puts it",
               arranged.items.enumerated().allSatisfy { card($1).frame == geometry.frames[$0] })
    // Pinned in the order 12, 5, 20: the middle is 12, 5 above it, 20 below.
    let block = arranged.items[arranged.above..<(arranged.above + 3)].map(\.title)
    expect("pinned deck: the first pinned in the middle, the second above, the third below",
           block.joined(separator: ","), "Note 5,Note 12,Note 20")
    expectTrue("pinned deck: pinned tabs are whole",
               arranged.items[arranged.above..<(arranged.above + 3)].allSatisfy {
                   card($0).visibleSlice == EdgeMetrics.tabHeight && card($0).frame.height == EdgeMetrics.tabHeight })
    expectTrue("pinned deck: and in a part of their own",
               card(notes[12]).superview !== card(notes[0]).superview && card(notes[5]).superview === card(notes[12]).superview)

    expectTrue("pinned deck: a pinned tab carries the pin, the others do not",
               pinnedIndexes.allSatisfy { card(notes[$0]).isPinned } && !card(notes[0]).isPinned)

    // The block is centred on the screen's height.
    let area = NSScreen.main!.visibleFrame
    let middleCard = card(notes[12])
    let screenMiddle = deck.stack.window!.convertToScreen(middleCard.convert(middleCard.bounds, to: nil)).midY
    expectTrue("pinned deck: the block is centred on the screen's height",
               abs(deck.stack.window!.frame.midY - area.midY) < 1 && abs(screenMiddle - area.midY) < EdgeMetrics.tabHeight / 2 + EdgeMetrics.tabSpacing)

    // The cursor opens a pinned tab, and a tab of either side.
    deck.move(to: deck.pointOnSlice(5))
    expectTrue("pinned deck: hovering a pinned tab opens it", deck.stack.hoveredNoteID == notes[5].id)
    expectTrue("pinned deck: the pinned tab stays whole", card(notes[5]).visibleSlice == EdgeMetrics.tabHeight)
    deck.move(to: deck.pointOnSlice(2))
    expectTrue("pinned deck: and a tab above the block", deck.stack.hoveredNoteID == notes[2].id)
    deck.move(to: deck.pointOnSlice(17))
    expectTrue("pinned deck: and one below it", deck.stack.hoveredNoteID == notes[17].id)
    expectTrue("pinned deck: clicks go to the tab under the cursor",
               deck.stack.hitTest(deck.stack.convert(deck.pointOnSlice(12), from: nil)) === card(notes[12]))
    deck.close()
}

// MARK: - Tabs about to be archived

@MainActor
func runExpiringMarkTests() {
    let today = DailyDay(Date())
    func note(_ title: String, idle: Int, _ change: (inout Note) -> Void = { _ in }) -> Note {
        var note = Note(title: title, body: "", lastOpenedDay: DailyDay(epoch: today.epochDay - idle))
        change(&note)
        return note
    }
    let notes = [
        note("fresh", idle: 1), note("last two days", idle: 12), note("tomorrow", idle: 13), note("due", idle: 14),
        note("kept", idle: 13) { $0.keepOnDeck = true }, note("pinned", idle: 13) { $0.pinnedAt = Date() },
        note("daily", idle: 13) { $0.tags = ["daily"]; $0.dailyDay = today },
    ]
    let deck = DeckFixture(notes: notes)
    func marked(_ title: String) -> Bool { deck.cards.first { $0.noteID == notes.first { $0.title == title }!.id }!.isExpiring }
    expectTrue("expiring: nothing on a fresh note", !marked("fresh"))
    expectTrue("expiring: a clock two days before", marked("last two days"))
    expectTrue("expiring: and the day before", marked("tomorrow"))
    expectTrue("expiring: none once it is due — the rule archives it", !marked("due"))
    expectTrue("expiring: none on a kept note", !marked("kept"))
    expectTrue("expiring: nor a pinned one", !marked("pinned"))
    expectTrue("expiring: nor a daily", !marked("daily"))

    // Opened today, the clock goes: the deck redraws for a change nobody announced.
    var refreshed = notes
    refreshed[2].lastOpenedDay = today
    deck.controller.update(notes: refreshed)
    expectTrue("expiring: the clock goes when the note is opened", !marked("tomorrow") && marked("last two days"))
    deck.close()
}
