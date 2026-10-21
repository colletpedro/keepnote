import AppKit

@MainActor
protocol EdgePanelControllerDelegate: AnyObject {
    func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?)
    func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID)
    func edgePanelDidRequestNewNote(_ controller: EdgePanelController)
    func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController)
    func edgePanelDidRequestAllNotes(_ controller: EdgePanelController)
    func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu?
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

    private var notes: [Note] = []
    /// The pinned block the deck is laid out around, if any pinned notes.
    private var pinnedBlock: DeckGeometry.PinnedBlock?
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
        PillView.height(forNoteCount: max(1, notes.count))
    }

    private func pillFrame() -> NSRect {
        DeckPlacement.pillFrame(height: pillHeight, in: anchor, edge: edge)
    }

    /// The panel is wider than a tab: the extra strip on the inner side is
    /// where a hovered card grows into, so lifting one never clips it.
    private func deckFrame() -> NSRect {
        let width = EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter
        let geometry = DeckGeometry.layout(
            count: notes.count, usableHeight: usableHeight, columnWidth: width, pinned: pinnedBlock, edge: edge)
        return DeckPlacement.deckFrame(deckHeight: geometry.deckHeight, in: anchor, edge: edge)
    }

    // MARK: - State

    /// Notes floating on the desk; their tabs are marked.
    private(set) var floatingNoteIDs: Set<UUID> = []

    func setFloating(_ ids: Set<UUID>) {
        guard ids != floatingNoteIDs else { return }
        floatingNoteIDs = ids
        stackView.setFloating(ids)
    }

    func update(notes incoming: [Note]) {
        // The pinned notes leave the list and form a block in the middle; the
        // rest keep their order around it. See `PinnedDeck`.
        let arrangement = PinnedDeck.arrange(incoming)
        let notes = arrangement.items
        let signature = notes.map { "\($0.id)|\($0.color.rawValue)|\($0.spineLabel)|\($0.isDaily)|\($0.isPinned)|\(DeckStatus.isExpiring($0))" }
            + ["above \(arrangement.above)", "pinned \(arrangement.pinned)"]
        let unchanged = signature == deckSignature
        self.notes = notes
        pinnedBlock = arrangement.pinned > 0 ? .init(above: arrangement.above, count: arrangement.pinned) : nil
        deckSignature = signature
        stackView.updatePill(colors: notes.map(\.color), highlighted: isFanned)
        if isFanned {
            guard !unchanged else { return }
            // Added, removed or changed notes: the tabs slide to the new step.
            let snapshot = stackView.snapshot()
            let frame = deckFrame()
            panel.setFrame(frame, display: false, animate: false)
            stackView.frame = NSRect(origin: .zero, size: frame.size)
            stackView.update(notes: notes, usableHeight: usableHeight, pinned: pinnedBlock, from: snapshot)
        } else {
            layoutForResting(animated: true)
        }
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
                stackView.updatePill(colors: notes.map(\.color), highlighted: false)
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
        guard isFanned, openNoteCount == 0, !isKeyboardFocused else { return }
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
            guard !self.preview.isHovered else { return }
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
        guard !notes.isEmpty else { return }
        isFanned = true
        // The window jumps to its full size in one step while the tabs animate
        // inside it. Animating the window frame itself would fight the card
        // animation and stutter on a busy compositor.
        let frame = deckFrame()
        panel.setFrame(frame, display: true, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.layoutPill(height: pillHeight)
        stackView.setPillVisible(false, animated: true)
        stackView.updatePill(colors: notes.map(\.color), highlighted: true)
        stackView.fanOut(
            notes: notes,
            usableHeight: usableHeight,
            pinned: pinnedBlock,
            stagger: AppSettings.shared.fanStagger,
            preserveScroll: false
        )
    }

    func collapse() {
        guard isFanned else { return }
        isFanned = false
        preview.hide()
        stackView.fanIn { [weak self] in
            guard let self else { return }
            self.stackView.updatePill(colors: self.notes.map(\.color), highlighted: false)
            self.layoutForResting(animated: true)
        }
    }

    private func rebuildDeck(stagger: Double) {
        let frame = deckFrame()
        panel.setFrame(frame, display: true, animate: false)
        stackView.frame = NSRect(origin: .zero, size: frame.size)
        stackView.fanOut(
            notes: notes,
            usableHeight: usableHeight,
            pinned: pinnedBlock,
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
