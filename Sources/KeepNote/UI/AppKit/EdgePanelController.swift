import AppKit

@MainActor
protocol EdgePanelControllerDelegate: AnyObject {
    func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?)
    func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID)
    /// Notes dragged onto a group's tab.
    func edgePanel(_ controller: EdgePanelController, didDropNotes ids: [UUID], onGroup id: UUID)
    /// A colour chosen in the open group's header.
    func edgePanel(_ controller: EdgePanelController, didChoose color: GroupColor, forGroup id: UUID)
    /// A note is about to be made from this deck: the group it is born in,
    /// the one that is open here.
    func edgePanelOpenGroup(_ controller: EdgePanelController) -> UUID?
    func edgePanelDidRequestNewNote(_ controller: EdgePanelController)
    func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController)
    func edgePanelDidRequestAllNotes(_ controller: EdgePanelController)
    func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu?
}

extension EdgePanelControllerDelegate {
    func edgePanel(_ controller: EdgePanelController, didDropNotes ids: [UUID], onGroup id: UUID) {}
    func edgePanel(_ controller: EdgePanelController, didChoose color: GroupColor, forGroup id: UUID) {}
    func edgePanelOpenGroup(_ controller: EdgePanelController) -> UUID? { nil }
}

/// Drives one screen's deck through its three states.
///
/// One controller per `NSScreen`, so every display gets its own stripe on its
/// own right edge, and the deck opens on whichever screen the cursor entered —
/// there is no shared "current" panel to fight over.
@MainActor
final class EdgePanelController: NSObject {
    weak var delegate: EdgePanelControllerDelegate?

    /// Screens are recreated by the window server on configuration changes, so
    /// the display ID is the stable handle, not the `NSScreen` object.
    let displayID: CGDirectDisplayID

    private let panel = EdgePanel()
    private let stackView = EdgeStackView(frame: .zero)
    /// For Tests/Integration, which drives the deck with mouse events.
    var stackViewForTesting: EdgeStackView { stackView }
    var peekForTesting: (noteID: UUID?, frame: NSRect) { (preview.visibleNoteID, preview.frameForTesting) }

    /// The notes on the deck, as the store has them, and what groups them.
    private var notes: [Note] = []
    private var groups: [NoteGroup] = []
    private var dailyColor = NoteColor.default
    /// The group open in this deck, if one is: only one at a time, and none
    /// once the deck has folded away.
    private(set) var openGroup: DeckGroupRef?
    /// What the deck shows now, and what its cards draw.
    private var plan = DeckPlan.empty
    private var content = DeckContent()
    private var collapseTask: Task<Void, Never>?
    /// The cursor on the resting stripe, and whether it means to open the deck.
    private var intent = DeckIntent(delay: DeckIntent.defaultDelay)
    private var intentTask: Task<Void, Never>?

    /// The middle state: hovering a tab peeks at the note without opening it.
    private let preview = NotePreviewController()
    private var previewHideTask: Task<Void, Never>?
    /// What the deck is currently drawing. Autosave fires a store change on
    /// every pause in typing, and none of those change the tabs.
    private var deckSignature: [String] = []

    private(set) var isFanned = false

    var noteCount: Int { notes.count }

    /// The user's own group that is open here, which a note made now is born in.
    var openUserGroupID: UUID? {
        if case .user(let id) = openGroup { return id }
        return nil
    }

    // MARK: - Keyboard (Focus Deck)

    /// The deck has the keyboard: arrows move between its stops, Return opens,
    /// Space peeks, Esc gives the keyboard back.
    private(set) var isKeyboardFocused = false
    /// The app that had the keyboard before, which gets it back on Esc.
    private var returnApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

    func focusFromKeyboard() {
        if NSWorkspace.shared.frontmostApplication != NSRunningApplication.current {
            returnApp = NSWorkspace.shared.frontmostApplication
        }
        openFromKeyboardOrVoiceOver()
        guard isFanned else { return }
        isKeyboardFocused = true
        panel.allowsKey = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(stackView)
        stackView.beginKeyboardFocus()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endKeyboardFocus(giveBack: false) }
        }
    }

    /// Esc, a click elsewhere, or a stop that opens something: the keyboard
    /// focus ends. `giveBack` returns the keyboard to the app that had it.
    func endKeyboardFocus(giveBack: Bool) {
        guard isKeyboardFocused else { return }
        isKeyboardFocused = false
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        stackView.endKeyboardFocus()
        preview.hide()
        panel.allowsKey = false
        if giveBack {
            collapse()
            returnApp?.activate()
        } else if openNoteCount == 0 {
            scheduleCollapse()
        }
        returnApp = nil
    }

    /// Space on a tab: its peek, as hovering would show it.
    func peekFromKeyboard(noteID: UUID) {
        if preview.visibleNoteID == noteID {
            preview.hide()
        } else {
            showPreview(for: noteID)
        }
    }

    /// Return on a stop.
    func pressFromKeyboard(_ stop: NSView) {
        // A group opens or closes with the keyboard still in the deck, which
        // goes on into it; anything else ends the focus.
        if let group = stop as? GroupCardView {
            toggleGroup(group.ref)
            return
        }
        // The colour button opens its popover with the keyboard still in the deck.
        if let button = stop as? GroupColorButtonView {
            button.press()
            return
        }
        endKeyboardFocus(giveBack: false)
        _ = stop.accessibilityPerformPress()
    }

    /// VoiceOver's press on the stripe (and the keyboard): the deck opens at
    /// once, with no wait for the cursor.
    func openFromKeyboardOrVoiceOver() {
        collapseTask?.cancel()
        collapseTask = nil
        guard !isFanned else { return }
        expand()
        NSAccessibility.post(element: stackView, notification: .layoutChanged)
    }

    /// Notes opened from this deck. While any is on screen the deck stays
    /// fanned, because the open note sits right beside it and collapsing out
    /// from under the cursor would be nonsense.
    private var openNoteCount = 0

    init(screen: NSScreen) {
        self.displayID = screen.displayID
        super.init()
        stackView.controller = self
        stackView.edge = laidOutEdge
        panel.contentView = stackView
        panel.orderFrontRegardless()
        layoutForResting(animated: false)

        preview.onHoverChanged = { [weak self] entered in
            guard let self else { return }
            if entered {
                self.previewHideTask?.cancel()
                self.previewHideTask = nil
                self.collapseTask?.cancel()
                self.collapseTask = nil
            } else {
                self.schedulePreviewHide()
                self.scheduleCollapse()
            }
        }
        preview.onClick = { [weak self] id in
            self?.activate(noteID: id)
        }
    }

    // MARK: - Screen geometry

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// `visibleFrame` rather than `frame`: it already excludes the menu bar and
    /// the Dock, left or right, so the deck never lands underneath either.
    /// See `DeckPlacement`.
    private var anchor: NSRect {
        screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// The height this screen leaves for the deck, a margin above and below.
    /// Everything about the deck's shape follows from it — see `DeckGeometry`.
    private var usableHeight: CGFloat {
        DeckPlacement.usableHeight(in: anchor)
    }

    /// The side the deck is on, from Settings > Deck > Screen edge.
    private var edge: ScreenEdge { AppSettings.shared.screenEdge }
    /// The edge the deck was last laid out for; a change is applied at once.
    private var laidOutEdge: ScreenEdge = AppSettings.shared.screenEdge

    private var pillHeight: CGFloat {
        PillView.height(forNoteCount: max(1, pillColors.count))
    }

    /// One dash per tab of the deck closed: a group's in its colour, a note's
    /// in its own.
    private var pillColors: [NSColor] {
        let closed = DeckPlan.make(notes: notes, groups: groups, open: nil, usableHeight: usableHeight)
        let made = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: closed)
        return closed.entries.compactMap { entry -> NSColor? in
            switch entry {
            case .note(let id): return made.notes[id]?.color.spine
            case .group(let ref), .header(let ref): return made.group(ref).look.fill
            }
        }
    }

    private func pillFrame() -> NSRect {
        DeckPlacement.pillFrame(height: pillHeight, in: anchor, edge: edge)
    }

    /// The panel is wider than a tab: the extra strip on the inner side is
    /// where a hovered card grows into, so lifting one never clips it.
    private func deckFrame() -> NSRect {
        let lift = AppSettings.shared.hoverLift
        let width = EdgeMetrics.tabWidth + EdgeMetrics.gutter(forLift: lift)
        let geometry = plan.geometry(usableHeight: usableHeight, columnWidth: width, edge: edge,
                                     metrics: DeckGeometry.Metrics(hoverLift: lift))
        return DeckPlacement.deckFrame(deckHeight: geometry.deckHeight, in: anchor, edge: edge, lift: lift)
    }

    // MARK: - State

    /// Notes floating on the desk; their tabs are marked.
    private(set) var floatingNoteIDs: Set<UUID> = []

    func setFloating(_ ids: Set<UUID>) {
        guard ids != floatingNoteIDs else { return }
        floatingNoteIDs = ids
        stackView.setFloating(ids)
    }

    /// The notes on the deck, the groups and the colour of Daily, as the store
    /// has them now.
    func update(notes incoming: [Note], groups: [NoteGroup] = [], dailyColor: NoteColor = .default) {
        notes = incoming
        self.groups = groups
        self.dailyColor = dailyColor
        guard isFanned else {
            // Folded away: no group is open, and the stripe follows the notes.
            openGroup = nil
            plan = DeckPlan.make(notes: notes, groups: groups, open: nil, usableHeight: usableHeight)
            content = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: plan)
            deckSignature = signature()
            stackView.updatePill(colors: pillColors, highlighted: false)
            layoutForResting(animated: true)
            return
        }
        remake(animated: true)
    }

    /// The header of the open group is as tall as its name needs.
    private func openHeaderHeight(_ ref: DeckGroupRef?) -> CGFloat {
        switch ref {
        case .user(let id)?:
            guard let group = groups.first(where: { $0.id == id }) else { return EdgeMetrics.tabHeight }
            return GroupCardView.openHeight(name: group.name, hasColorButton: true)
        case .daily?:
            return GroupCardView.openHeight(name: L("Daily"), hasColorButton: false)
        case nil:
            return EdgeMetrics.tabHeight
        }
    }

    /// Works the plan out again from what the deck has and applies it: the
    /// tabs slide to their new places. A group that has run out of notes, or
    /// of room, is no longer open.
    private func remake(animated: Bool) {
        let made = DeckPlan.make(notes: notes, groups: groups, open: openGroup, usableHeight: usableHeight,
                                 headerHeight: openHeaderHeight(openGroup))
        openGroup = made.open
        let madeContent = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: made)
        let before = deckSignature
        plan = made
        content = madeContent
        deckSignature = signature()
        stackView.updatePill(colors: pillColors, highlighted: isFanned)
        guard isFanned, deckSignature != before else { return }
        // Added, removed or changed notes, a group opened or closed: the tabs
        // slide to the new step.
        let snapshot = stackView.snapshot()
        let frame = deckFrame()
        panel.setFrame(frame, display: false, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.update(plan: made, content: madeContent, usableHeight: usableHeight, from: snapshot)
    }

    /// Everything the tabs draw, so an autosave — which changes nothing the
    /// tabs show — does not rebuild the deck.
    private func signature() -> [String] {
        var lines: [String] = []
        for entry in plan.entries {
            switch entry {
            case .note(let id):
                guard let note = content.notes[id] else { continue }
                lines.append("\(note.id)|\(note.color.rawValue)|\(note.spineLabel)|\(note.isDaily)|\(note.isPinned)|\(DeckStatus.isExpiring(note))|\(note.groupID?.uuidString ?? "-")")
            case .group(let ref):
                lines.append("group \(ref)|\(content.group(ref).name)|\(content.group(ref).count)|\(content.group(ref).look)")
            case .header(let ref):
                lines.append("header \(ref)|\(content.group(ref).name)|\(content.group(ref).count)|\(content.group(ref).look)")
            }
        }
        lines += ["pinned \(plan.pinned.map { "\($0.above)/\($0.count)" } ?? "-")", "sticky \(plan.stickyHeader)"]
        lines += content.choices.map { "choice \($0.id)|\($0.name)|\($0.color.rawValue)" }
        return lines
    }

    // MARK: - Groups

    /// A group's tab was pressed: it opens in place, any other that was open
    /// closing; or, if it is the open one, it closes.
    func toggleGroup(_ ref: DeckGroupRef) {
        let opening = openGroup != ref
        openGroup = opening ? ref : nil
        remake(animated: true)
        announceGroup(ref, opened: opening && openGroup == ref)
    }

    /// Esc, or a click on the open group's header.
    func closeGroup() {
        guard let ref = openGroup else { return }
        toggleGroup(ref)
    }

    private func announceGroup(_ ref: DeckGroupRef, opened: Bool) {
        let info = content.groups[ref] ?? DeckContent().group(ref)
        let name = info.name.isEmpty ? L("Daily") : info.name
        Announcer.say(AccessibilityText.groupAnnouncement(name: name, count: plan.counts[ref] ?? info.count, isOpen: opened))
    }

    /// A colour chosen in the header of the open group.
    func setColor(_ color: GroupColor, ofGroup ref: DeckGroupRef) {
        guard case .user(let id) = ref else { return }
        delegate?.edgePanel(self, didChoose: color, forGroup: id)
    }

    /// While the colour popover is up the deck stays open, whatever the cursor does.
    private var colorPopoverOpen = false
    var colorPopoverOpenForTesting: Bool { colorPopoverOpen }

    func colorPopoverChanged(open: Bool) {
        colorPopoverOpen = open
        if open {
            collapseTask?.cancel()
            collapseTask = nil
        } else if isFanned, openNoteCount == 0, !isKeyboardFocused {
            scheduleCollapse()
        }
    }

    /// Notes dragged onto a group's tab.
    func dropNotes(_ ids: [UUID], onGroup ref: DeckGroupRef) {
        guard case .user(let id) = ref else { return }
        delegate?.edgePanel(self, didDropNotes: ids, onGroup: id)
    }

    func applySettings() {
        panel.applyBehavior()
        preview.applyBehavior()
        if edge != laidOutEdge {
            // The other side of the screen: the deck folds away at once and
            // the stripe reappears on the new edge, on every display.
            laidOutEdge = edge
            stackView.edge = edge
            preview.hide(animated: false)
            if isFanned {
                isFanned = false
                stackView.clearDeck()
                openGroup = nil
                stackView.updatePill(colors: pillColors, highlighted: false)
            }
            layoutForResting(animated: false)
            return
        }
        if isFanned {
            rebuildDeck(stagger: AppSettings.shared.fanStagger)
        } else {
            layoutForResting(animated: false)
        }
    }

    func showPanel() { panel.orderFrontRegardless() }
    func hidePanel() {
        preview.hide(animated: false)
        panel.orderOut(nil)
    }

    // MARK: - Hover preview

    /// A tab under the cursor peeks open after a beat. The delay is what keeps
    /// a sweep down the deck from flashing one card per tab.
    func tabHoverChanged(_ entry: DeckEntry, entered: Bool) {
        if let id = entry.noteID {
            cardHoverChanged(noteID: id, entered: entered)
        } else if entered {
            // A group has no peek; the one on show goes.
            previewHideTask?.cancel()
            previewHideTask = nil
            preview.hide()
        } else {
            schedulePreviewHide()
        }
    }

    func cardHoverChanged(noteID: UUID, entered: Bool) {
        // While the editor is open it already occupies that spot; a peek
        // underneath it would just be two cards in the same place.
        guard openNoteCount == 0 else { return }
        // With the keyboard, the peek waits for Space.
        if isKeyboardFocused {
            if entered { preview.hide() }
            return
        }

        if entered {
            previewHideTask?.cancel()
            previewHideTask = nil
            showPreview(for: noteID)
        } else {
            schedulePreviewHide()
        }
    }

    private func showPreview(for noteID: UUID) {
        guard isFanned, let note = notes.first(where: { $0.id == noteID }) else { return }
        preview.show(
            note: note,
            tabFrame: stackView.screenFrame(forNoteID: noteID) ?? .zero,
            deckWidth: deckFrame().width,
            on: screen
        )
        // The rest of the stack belongs over the card being read, the way it
        // would if this one were physically drawn part of the way out.
        panel.orderFrontRegardless()
    }

    private func schedulePreviewHide() {
        previewHideTask?.cancel()
        previewHideTask = Task { @MainActor [weak self] in
            let delay = UInt64(EdgeMetrics.previewGrace * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, !self.preview.isHovered else { return }
            guard self.stackView.hoveredNoteID == nil else { return }
            self.preview.hide()
        }
    }

    func deckDidScroll() {
        preview.hide()
    }

    private func layoutForResting(animated: Bool) {
        let frame = pillFrame()
        panel.setFrame(frame, display: true, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.layoutPill(height: frame.height)
        stackView.setPillVisible(true, animated: animated)
    }

    // MARK: - Cursor

    /// `mouseEntered` on our own window — no global monitor, no permission.
    func cursorDidEnter() {
        collapseTask?.cancel()
        collapseTask = nil
        guard !isFanned else { return }
        expand()
    }

    /// The cursor reached the resting stripe. The deck opens once `DeckIntent`
    /// says it is meant to — after the open delay, or at once on a slow arrival.
    func cursorDidArrive(at point: CGPoint, time: Double) {
        collapseTask?.cancel()
        collapseTask = nil
        guard !isFanned else { return }
        intent = DeckIntent(delay: AppSettings.shared.openDelay)
        intent.enter(at: point, time: time)
        evaluateIntent(now: time)
    }

    func cursorDidMoveOnStripe(to point: CGPoint, time: Double) {
        guard !isFanned else { return }
        intent.move(to: point, time: time)
        evaluateIntent(now: time)
    }

    private func evaluateIntent(now: Double) {
        intentTask?.cancel()
        intentTask = nil
        switch intent.decision(now: now) {
        case .open:
            intent.exit()
            cursorDidEnter()
        case .wait(let until):
            // `NSEvent.timestamp` counts from the same origin as the uptime.
            intentTask = Task { @MainActor [weak self] in
                let wait = max(0, until - ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.evaluateIntent(now: max(until, ProcessInfo.processInfo.systemUptime))
            }
        case .idle:
            break
        }
    }

    func cursorDidExit() {
        intentTask?.cancel()
        intentTask = nil
        intent.exit()
        guard isFanned, openNoteCount == 0, !isKeyboardFocused, !colorPopoverOpen else { return }
        // Moving from a tab onto its own peek leaves the deck's tracking area,
        // but is not leaving the deck. `scheduleCollapse` re-checks that when
        // it fires, by which time the preview's own enter event has arrived.
        scheduleCollapse()
    }

    /// A short grace period, cancelled the moment the cursor comes back, so
    /// crossing the gap between two tabs does not slam the deck shut.
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            let grace = UInt64(EdgeMetrics.collapseGrace * 1_000_000_000)
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled, let self else { return }
            guard !self.preview.isHovered, !self.colorPopoverOpen else { return }
            self.collapse()
        }
    }

    func noteDidOpen() {
        openNoteCount += 1
        preview.hide(animated: false)
        collapseTask?.cancel()
        collapseTask = nil
    }

    func noteDidClose() {
        openNoteCount = max(0, openNoteCount - 1)
        guard openNoteCount == 0, isFanned else { return }
        // The cursor is usually on the note that just closed, which is outside
        // the deck, so fold back up unless it comes straight back.
        scheduleCollapse()
    }

    func expand() {
        guard !notes.isEmpty || !groups.isEmpty else { return }
        // A deck opens with every group closed.
        openGroup = nil
        plan = DeckPlan.make(notes: notes, groups: groups, open: nil, usableHeight: usableHeight)
        content = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: plan)
        deckSignature = signature()
        isFanned = true
        // The window jumps to its full size in one step while the tabs animate
        // inside it. Animating the window frame itself would fight the card
        // animation and stutter on a busy compositor.
        let frame = deckFrame()
        panel.setFrame(frame, display: true, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.layoutPill(height: pillHeight)
        stackView.setPillVisible(false, animated: true)
        stackView.updatePill(colors: pillColors, highlighted: true)
        stackView.fanOut(
            plan: plan,
            content: content,
            usableHeight: usableHeight,
            stagger: AppSettings.shared.fanStagger,
            preserveScroll: false
        )
    }

    func collapse() {
        guard isFanned else { return }
        isFanned = false
        colorPopoverOpen = false
        preview.hide()
        openGroup = nil
        stackView.fanIn { [weak self] in
            guard let self else { return }
            self.stackView.updatePill(colors: self.pillColors, highlighted: false)
            self.layoutForResting(animated: true)
        }
    }

    private func rebuildDeck(stagger: Double) {
        plan = DeckPlan.make(notes: notes, groups: groups, open: openGroup, usableHeight: usableHeight,
                             headerHeight: openHeaderHeight(openGroup))
        openGroup = plan.open
        content = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: plan)
        deckSignature = signature()
        let frame = deckFrame()
        panel.setFrame(frame, display: true, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.fanOut(
            plan: plan,
            content: content,
            usableHeight: usableHeight,
            stagger: stagger,
            preserveScroll: true
        )
    }

    // MARK: - Actions

    /// The deck stays open behind the note: the note slides clear of it, it
    /// does not replace it.
    func activate(noteID: UUID) {
        preview.hide(animated: false)
        let tabFrame = stackView.screenFrame(forNoteID: noteID)
        delegate?.edgePanel(self, didActivateNote: noteID, from: tabFrame)
    }

    func performContextAction(_ action: NoteCardView.ContextAction, on noteID: UUID) {
        delegate?.edgePanel(self, didRequest: action, on: noteID)
    }

    func showAllNotes() {
        delegate?.edgePanelDidRequestAllNotes(self)
        collapse()
    }

    func pillClicked() {
        delegate?.edgePanelDidRequestNewNote(self)
    }

    func dailyClicked() {
        delegate?.edgePanelDidRequestTodaysDaily(self)
    }

    /// Right-clicking the resting stripe is the app's only menu: there is no
    /// Dock icon and an accessory app gets no menu bar.
    func contextMenu() -> NSMenu? {
        delegate?.edgePanelMenu(self)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
