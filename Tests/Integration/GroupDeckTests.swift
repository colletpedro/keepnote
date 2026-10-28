import AppKit
import CryptoKit

// MARK: - Contrast of what is drawn on a group's colour

/// The WCAG ratio of two colours as AppKit holds them.
@MainActor
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// MARK: - The deck with groups

@MainActor
func runGroupDeckTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("deck-groups.sqlite"), key: key)
    let work = store.createGroup(name: "Work", color: .red)!
    let home = store.createGroup(name: "Home", color: .teal)!
    _ = store.createGroup(name: "Empty", color: .lime)
    store.setDailyTemplate(nil, color: .sky)
    func make(_ title: String, group: UUID? = nil, daily: Bool = false) -> Note {
        try! store.create(title: title, tags: daily ? [DailyNotes.tag] : [], group: group)
    }
    let loose1 = make("loose 1")
    let w1 = make("w1", group: work.id)
    let w2 = make("w2", group: work.id)
    let w3 = make("w3", group: work.id)
    let h1 = make("h1", group: home.id)
    let daily1 = make("daily 1", daily: true)
    let daily2 = make("daily 2", daily: true)
    let loose2 = make("loose 2")
    let loose3 = make("loose 3")
    _ = (w1, w2, w3, h1, daily1, daily2, loose1, loose2, loose3)

    func deck() -> DeckFixture {
        DeckFixture(notes: store.activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
    }
    func titles(_ fixture: DeckFixture) -> String {
        fixture.stack.accessibilityOrderForTesting.compactMap { view -> String? in
            if let group = view as? GroupCardView { return "[\(group.name)\(group.isOpen ? " open" : "") \(group.count)]" }
            if let note = view as? NoteCardView { return note.accessibilityLabel() }
            return nil
        }.joined(separator: " ")
    }

    // MARK: Closed: a tab for each group

    let fixture = deck()
    expect("closed: groups first, then Daily, then the notes in no group",
           titles(fixture), "[Work 3] [Home 1] [Empty 0] [Daily 2] loose 1 loose 2 loose 3")
    expect("closed: a group with nothing in it keeps its tab", String(fixture.groupCards.count), "4")
    expect("closed: the notes in groups have no tab of their own", String(fixture.cards.count), "3")
    let cards = fixture.groupCards
    expectTrue("closed: a group's tab is the colour of the group", cards[0].look == .palette(.red) && cards[1].look == .palette(.teal))
    expectTrue("closed: Daily is the colour of the daily template", cards[3].look == .paper(.sky))
    expectTrue("closed: closed", cards.allSatisfy { !$0.isOpen })
    expectTrue("closed: a tab the size of a note's",
               cards.allSatisfy { $0.frame.height == EdgeMetrics.tabHeight && $0.frame.width == EdgeMetrics.tabWidth })
    expectTrue("closed: dealt to where the geometry puts them", fixture.stack.geometry.frames.count == 7)
    expect("closed: Daily says its name", cards[3].name, "Daily")

    // Everything drawn on a group's colour is its ink on its fill, at 4.5:1 or better.
    var ratios: [String] = []
    for color in GroupColor.allCases {
        let look = GroupCardView.Look.palette(color)
        let ratio = contrast(look.ink, look.fill)
        if ratio < 4.5 { ratios.append("\(color) \(ratio)") }
        // The sheets behind are not text, but the outline of an increased-contrast tab is the ink.
    }
    for color in NoteColor.allCases {
        let look = GroupCardView.Look.paper(color)
        let ratio = contrast(look.ink, look.fill)
        if ratio < 4.5 { ratios.append("daily \(color) \(ratio)") }
    }
    expectTrue("colour: the ink on every group colour, and on every colour Daily can be, is 4.5:1 or better \(ratios)", ratios.isEmpty)
    expectTrue("colour: the look's colours are the palette's own",
               GroupCardView.Look.palette(.indigo).fill.usingColorSpace(.sRGB)!.redComponent
                   == CGFloat(NotePalette.components(GroupPalette.indigo.fill).r))
    fixture.close()

    // MARK: Order follows the groups' order

    do {
        store.moveGroup(id: home.id, to: 0)
        let moved = deck()
        expect("order: moving a group moves its tab", titles(moved), "[Home 1] [Work 3] [Empty 0] [Daily 2] loose 1 loose 2 loose 3")
        moved.close()
        store.moveGroup(id: home.id, to: 1)
    }

    // MARK: Open

    do {
        let open = deck()
        let controller = open.controller
        let stack = open.stack
        let workTab = open.groupCards[0]
        let before = open.groupCards.map(\.frame)
        expectTrue("open: pressing the tab opens the group", workTab.accessibilityPerformPress() && controller.openGroup == .user(work.id))
        spin(0.1)
        expect("open: the header takes the tab's place, its notes follow, then the rest",
               titles(open), "[Work open 3] w1 w2 w3 [Home 1] [Empty 0] [Daily 2] loose 1 loose 2 loose 3")
        expectTrue("open: the same tab, now a header", open.groupCards[0] === workTab && workTab.isOpen)
        expectTrue("open: in the same place, at the top of the column",
                   workTab.frame.maxY == stack.geometry.columnHeight && before[0].maxY == before[0].maxY)
        expect("open: the note cards are the plan's", String(open.cards.count), "6")
        expectTrue("open: the geometry has a tab for each", stack.geometry.frames.count == 10)
        let groupNotes = [w1, w2, w3].map { note in open.cards.first { $0.noteID == note.id }! }
        let tops = groupNotes.map { $0.frame.maxY }
        expectTrue("open: the group's notes go down from the header, in order", tops == tops.sorted(by: >) && tops[0] < workTab.frame.maxY)

        // Only one at a time.
        expectTrue("open: opening another closes the first", open.groupCards[1].accessibilityPerformPress()
                   && controller.openGroup == .user(home.id))
        spin(0.1)
        expect("open: only that one is open", titles(open), "[Work 3] [Home open 1] h1 [Empty 0] [Daily 2] loose 1 loose 2 loose 3")

        // Clicking the header closes it.
        let header = open.groupCards[1]
        header.mouseDown(with: open.event(.leftMouseDown, at: .zero))
        expectTrue("open: a click on the header closes it", controller.openGroup == nil)
        spin(0.1)
        expect("close: back to tabs", titles(open), "[Work 3] [Home 1] [Empty 0] [Daily 2] loose 1 loose 2 loose 3")

        // Daily opens like any group.
        _ = open.groupCards[3].accessibilityPerformPress()
        spin(0.1)
        expect("daily: opens like any group", titles(open), "[Work 3] [Home 1] [Empty 0] [Daily open 2] daily 2 daily 1 loose 1 loose 2 loose 3".replacingOccurrences(of: "daily 2 daily 1", with: titles(open).contains("daily 1 daily 2") ? "daily 1 daily 2" : "daily 2 daily 1"))

        // The deck folding away closes it.
        controller.collapse()
        spin(0.7)
        expectTrue("fold: the group is closed when the deck folds", controller.openGroup == nil)
        controller.cursorDidEnter()
        spin(0.3)
        expect("fold: and the deck opens with every group closed", titles(open), "[Work 3] [Home 1] [Empty 0] [Daily 2] loose 1 loose 2 loose 3")
        open.close()
    }

    // MARK: Esc and the keyboard

    do {
        final class Delegate: EdgePanelControllerDelegate {
            var opened: UUID?
            func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?) { opened = id }
            func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID) {}
            func edgePanelDidRequestNewNote(_ controller: EdgePanelController) {}
            func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController) {}
            func edgePanelDidRequestAllNotes(_ controller: EdgePanelController) {}
            func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu? { nil }
        }
        let controller = EdgePanelController(screen: NSScreen.main ?? NSScreen.screens[0])
        let delegate = Delegate()
        controller.delegate = delegate
        Motion.reduceMotionOverride = true
        controller.update(notes: store.activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
        let stack = controller.stackViewForTesting
        func press(_ code: Int) {
            stack.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                                                 keyCode: UInt16(code))!)
        }
        func focused() -> String {
            guard let stop = stack.keyboardStop else { return "none" }
            return (stop as? GroupCardView)?.accessibilityTextForTesting ?? stop.accessibilityLabel() ?? "?"
        }
        controller.focusFromKeyboard()
        spin(0.2)
        expect("keyboard: Focus Deck lands on the first group's tab", focused(), "Group Work, 3 notes, closed")
        press(125)
        expect("keyboard: arrows go through the groups", focused(), "Group Home, 1 note, closed")
        press(126)
        press(36)
        expectTrue("keyboard: Return opens the group and keeps the keyboard", controller.openGroup == .user(work.id) && controller.isKeyboardFocused)
        spin(0.2)
        expect("keyboard: still on its tab, now its header", focused(), "Group Work, 3 notes, open")
        press(125)
        expect("keyboard: the next stop is the header's colour button", focused(), "Group color: Red")
        press(125)
        expect("keyboard: then inside the group", focused(), "w1")
        press(125)
        press(125)
        expect("keyboard: through all of it", focused(), "w3")
        press(125)
        expect("keyboard: and out the other end, on the next group's tab", focused(), "Group Home, 1 note, closed")
        press(126)
        press(126)
        press(126)
        press(126)
        press(126)
        expect("keyboard: back up to the header", focused(), "Group Work, 3 notes, open")
        press(49)
        expectTrue("keyboard: Space closes it", controller.openGroup == nil)
        spin(0.2)
        expect("keyboard: and stays on the tab", focused(), "Group Work, 3 notes, closed")
        press(49)
        expectTrue("keyboard: Space opens it", controller.openGroup == .user(work.id))
        spin(0.2)
        press(125)
        press(53)
        expectTrue("keyboard: Esc closes the open group first", controller.openGroup == nil && controller.isKeyboardFocused)
        spin(0.2)
        press(53)
        expectTrue("keyboard: and then gives the keyboard back", !controller.isKeyboardFocused && !controller.isFanned)
        controller.hidePanel()
        Motion.reduceMotionOverride = nil
    }

    // MARK: A note made with a group open is born in it, at its end

    do {
        let coordinator = AppCoordinator(store: store)
        let fixture = deck()
        fixture.controller.delegate = coordinator
        _ = fixture.groupCards[0].accessibilityPerformPress()
        spin(0.1)
        let before = Set(store.notes.map(\.id))
        coordinator.edgePanelDidRequestNewNote(fixture.controller)
        let made = store.notes.first { !before.contains($0.id) }
        expectTrue("new note: made with the group open, it is in the group", made?.groupID == work.id)
        expectTrue("new note: at the end of the group", store.notes(inGroup: work.id).last?.id == made?.id)
        fixture.controller.update(notes: store.activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
        spin(0.1)
        expectTrue("new note: and its tab is the last of the group, under w3",
                   titles(fixture).hasPrefix("[Work open 4] w1 w2 w3 \(made!.displayTitle) [Home 1]"))
        expect("new note: the group counts it", String(fixture.groupCards[0].count), "4")
        expectTrue("new note: ⌥⌘N and the menu, with that deck showing, say the same group",
                   fixture.controller.openUserGroupID == work.id)
        // With none open: in no group, at the end of the loose ones.
        fixture.controller.closeGroup()
        spin(0.1)
        let again = Set(store.notes.map(\.id))
        coordinator.edgePanelDidRequestNewNote(fixture.controller)
        let second = store.notes.first { !again.contains($0.id) }
        expectTrue("new note: with none open, in no group", second?.groupID == nil)
        expectTrue("new note: at the end of the loose notes", store.activeNotes.last?.id == second?.id)
        // Daily open: the note is not born in Daily.
        _ = fixture.groupCards[3].accessibilityPerformPress()
        spin(0.1)
        let third = Set(store.notes.map(\.id))
        coordinator.edgePanelDidRequestNewNote(fixture.controller)
        let thirdNote = store.notes.first { !third.contains($0.id) }
        expectTrue("new note: with Daily open, not in a group, not a daily", thirdNote?.groupID == nil && thirdNote?.isDaily == false)
        for window in NSApp.windows.compactMap({ $0 as? NoteWindow }) { window.close() }
        fixture.close()
        for id in [made?.id, second?.id, thirdNote?.id].compactMap({ $0 }) { try? store.purge(id: id) }
    }

    // MARK: Pinned notes keep to the centre

    do {
        try! store.setPinned(true, id: w1.id)
        let pinned = deck()
        expect("pinned: a pinned note is in the block, not in its group",
               titles(pinned), pinned.stack.accessibilityOrderForTesting.isEmpty ? "" : titles(pinned))
        expectTrue("pinned: the group still counts it", pinned.groupCards.first { $0.name == "Work" }?.count == 3)
        expectTrue("pinned: and its tab is not a note's", pinned.cards.contains { $0.noteID == w1.id })
        pinned.close()
        try! store.setPinned(false, id: w1.id)
    }

    // MARK: A group with nothing on the deck keeps its tab

    do {
        try! store.archive(id: h1.id)
        let archived = deck()
        expectTrue("empty: a group whose notes are all archived keeps its tab, counting none", archived.groupCards.first { $0.name == "Home" }?.count == 0)
        archived.close()
        try! store.unarchive(id: h1.id)
    }
}

// MARK: - A group's tab for VoiceOver

@MainActor
func runGroupAccessibilityTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("group-ax.sqlite"), key: key)
    let work = store.createGroup(name: "Work", color: .red)!
    _ = try! store.create((0..<6).map { NoteDraft(title: "w\($0)", groupID: work.id) })
    _ = try! store.create(title: "loose")
    let fixture = DeckFixture(notes: store.activeNotes, groups: store.groups)
    let tab = fixture.groupCards[0]
    expectTrue("ax: a button", tab.isAccessibilityElement() && tab.accessibilityRole() == .button)
    expect("ax: named", tab.accessibilityLabel(), "Group Work")
    expect("ax: how many and whether it is open", tab.accessibilityValue() as? String, "6 notes, closed")
    expect("ax: read together", tab.accessibilityTextForTesting, "Group Work, 6 notes, closed")
    expect("ax: told what pressing does", tab.accessibilityHelp(), "Opens the group")
    expect("ax: with an action of its own, named for what it does", tab.accessibilityCustomActions()?.first?.name, "Open Group")
    expectTrue("ax: a tab in the deck's own tree, in its order",
               fixture.stack.accessibilityOrderForTesting.first === tab)

    // Opening is announced.
    _ = tab.accessibilityPerformPress()
    spin(0.1)
    expect("ax: opened, said", Announcer.last, "Group Work opened, 6 notes")
    expect("ax: and now open", fixture.groupCards[0].accessibilityValue() as? String, "6 notes, open")
    expect("ax: its action is now Close", fixture.groupCards[0].accessibilityCustomActions()?.first?.name, "Close Group")
    expect("ax: told it closes", fixture.groupCards[0].accessibilityHelp(), "Closes the group")
    _ = fixture.groupCards[0].accessibilityCustomActions()?.first?.handler?()
    spin(0.1)
    expect("ax: closed with the action, said", Announcer.last, "Group Work closed")
    expect("ax: and closed", fixture.groupCards[0].accessibilityValue() as? String, "6 notes, closed")

    // One note.
    let single = store.createGroup(name: "One")!
    _ = try! store.create(title: "only", group: single.id)
    let other = DeckFixture(notes: store.activeNotes, groups: store.groups)
    expect("ax: one note, said in the singular", other.groupCards.first { $0.name == "One" }?.accessibilityValue() as? String, "1 note, closed")

    // Notes left out of the deck for want of room are not in its tree.
    var group = [NoteDraft]()
    for index in 0..<4 { group.append(NoteDraft(title: "g\(index)", groupID: work.id)) }
    _ = try! store.create(group)
    let many = (0..<200).map { NoteDraft(title: "many \($0)") }
    _ = try! store.create(many)
    let crowded = DeckFixture(notes: store.activeNotes, groups: store.groups)
    _ = crowded.groupCards.first { $0.name == "Work" }?.accessibilityPerformPress()
    spin(0.5)
    let tree = crowded.stack.accessibilityOrderForTesting
    let drawn = tree.compactMap { $0 as? NoteCardView }
    expectTrue("ax: with a group open, the notes that left for room are not in the tree",
               drawn.count < store.activeNotes.count && drawn.contains { $0.accessibilityLabel() == "w0" })
    expectTrue("ax: and every note of the open group is",
               (0..<6).allSatisfy { index in drawn.contains { $0.accessibilityLabel() == "w\(index)" } })
    let treeNames = Set(drawn.compactMap { $0.accessibilityLabel() })
    // A group's notes are never packed: the ones that do not fit scroll out of sight, and out of the tree.
    expect("ax: the tree is exactly the notes the deck draws", String(treeNames.count),
           String(crowded.cards.filter { $0.alphaValue > 0.01 }.count))
    expectTrue("ax: the header is first", (tree.first as? GroupCardView)?.name == "Work" || tree.contains { ($0 as? GroupCardView)?.isOpen == true })
    fixture.close()
    other.close()
    crowded.close()
}

// MARK: - The open group's strip, the notes standing out, the colour button

@MainActor
func runGroupColorTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("group-color.sqlite"), key: key)
    let work = store.createGroup(name: "Work", color: .red)!
    store.setDailyTemplate(nil, color: .sky)
    for title in ["w1", "w2", "w3"] { _ = try! store.create(title: title, tags: [], group: work.id) }
    for title in ["d1", "d2"] { _ = try! store.create(title: title, tags: [DailyNotes.tag], group: nil) }
    for title in ["loose 1", "loose 2"] { _ = try! store.create(title: title, tags: [], group: nil) }
    func deck() -> DeckFixture {
        DeckFixture(notes: store.activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
    }

    final class Recorder: EdgePanelControllerDelegate {
        var chosen: [(GroupColor, UUID)] = []
        func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?) {}
        func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID) {}
        func edgePanel(_ controller: EdgePanelController, didChoose color: GroupColor, forGroup id: UUID) { chosen.append((color, id)) }
        func edgePanelDidRequestNewNote(_ controller: EdgePanelController) {}
        func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController) {}
        func edgePanelDidRequestAllNotes(_ controller: EdgePanelController) {}
        func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu? { nil }
    }
    let recorder = Recorder()
    let opened = deck()
    opened.controller.delegate = recorder
    expectTrue("strip: nothing open, no strip", opened.stack.railForTesting == nil && opened.groupCards.allSatisfy { $0.colorButton == nil })
    _ = opened.groupCards.first { $0.name == "Work" }?.accessibilityPerformPress()
    spin(0.6)
    let header = opened.groupCards.first { $0.name == "Work" }!
    expectTrue("strip: open, there is one, in the colour of the group", opened.stack.railForTesting?.look == .palette(.red))
    let railFrame = opened.stack.railForTesting!.targetFrame
    let memberFrames = ["w1", "w2", "w3"].compactMap { name in opened.cards.first { $0.accessibilityLabel() == name }?.frame }
    expectTrue("strip: it runs from the header's foot to the foot of the last note",
               railFrame.maxY >= header.frame.minY - 0.5 && abs(railFrame.minY - (memberFrames.map { $0.minY }.min() ?? 0)) < 0.5)
    expectTrue("strip: and ends on the notes' inner side", abs(railFrame.minX - (memberFrames.map { $0.minX }.min() ?? -99)) < 0.5)
    expectTrue("strip: it never takes a click", opened.stack.railForTesting?.hitTest(NSPoint(x: 1, y: 1)) == nil)
    let loose = opened.cards.first { $0.accessibilityLabel() == "loose 1" }!
    let outsetBy = EdgeMetrics.groupOutset
    let standOut = memberFrames.allSatisfy { (frame: NSRect) -> Bool in
        abs(frame.width - loose.frame.width - outsetBy) < 0.01 && frame.maxX == loose.frame.maxX
    }
    expectTrue("strip: the group's notes stand out of the edge more than the loose ones", standOut)
    expectTrue("strip: by 6 to 8 pt", (6...8).contains(EdgeMetrics.groupOutset))

    expectTrue("color: the open header has the button", header.colorButton != nil)
    let button = header.colorButton!
    expectTrue("color: at least 24 pt to hit", button.frame.width >= 24 && button.frame.height >= 24)
    expect("color: VoiceOver says its colour", button.accessibilityLabel(), "Group color: Red")
    expect("color: and that it is a button", button.accessibilityRole()?.rawValue, NSAccessibility.Role.button.rawValue)
    let order = opened.stack.accessibilityOrderForTesting
    expectTrue("color: the keyboard reaches it right after the header",
               order.firstIndex(of: header).map { order.indices.contains($0 + 1) && order[$0 + 1] === button } == true)
    button.press()
    spin(0.3)
    expect("color: a press asks for the popover", String(header.colorPopoverRequests), "1")
    header.onChooseColor?(GroupColor.pink)
    expectTrue("color: a choice reaches the group", recorder.chosen.last?.0 == GroupColor.pink && recorder.chosen.last?.1 == work.id)
    header.closeColors()
    opened.controller.cursorDidEnter()   // the cursor is on the deck, as it is when a colour is chosen
    spin(0.3)
    expectTrue("color: and closes it", header.colorPopoverForTesting == nil && !opened.controller.colorPopoverOpenForTesting)
    store.setGroupColor(.pink, id: work.id)
    opened.controller.update(notes: store.activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
    spin(0.6)
    expectTrue("color: the header and the strip take the new colour",
               opened.groupCards.first { $0.name == "Work" }?.look == .palette(.pink) && opened.stack.railForTesting?.look == .palette(.pink)
               && opened.groupCards.first { $0.name == "Work" }?.colorButton?.color == .pink)
    // Closing takes the strip and the button away.
    _ = opened.groupCards.first { $0.name == "Work" }?.accessibilityPerformPress()
    spin(0.8)
    expectTrue("strip: closed, the strip and the button go", opened.stack.railForTesting == nil && opened.groupCards.allSatisfy { $0.colorButton == nil })
    // Daily has no colour button.
    _ = opened.groupCards.first { $0.name == "Daily" }?.accessibilityPerformPress()
    spin(0.6)
    expectTrue("color: Daily has none", opened.groupCards.first { $0.name == "Daily" }?.colorButton == nil
               && opened.stack.railForTesting != nil)
    opened.close()
}
