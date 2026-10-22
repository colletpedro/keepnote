import AppKit

/// Content view of `EdgePanel`. Holds the resting stripe and, once open, the
/// deck of tabs, and owns the tracking area that drives the whole interaction.
///
/// There is no global mouse monitor anywhere in the app. The cursor simply
/// enters a window that belongs to KeepNote, and AppKit delivers
/// `mouseEntered`. That is the difference between needing Accessibility
/// permission and needing none.
final class EdgeStackView: NSView {
    enum State {
        case resting
        case fanned
    }

    weak var controller: EdgePanelController?
    /// The side of the screen the deck is on. Everything below is laid out for
    /// the right edge and mirrored through `edge` for the left.
    var edge: ScreenEdge = .right

    private(set) var state: State = .resting

    private let pill = PillView()
    private let clip = DeckClipView(frame: .zero)
    /// The tabs live in three parts of the column: the unpinned ones above a
    /// pinned block, the block, and the unpinned ones below it. Each clips
    /// its own tabs, so a side that scrolls never draws over the block. They
    /// share the column's coordinates — a part's `bounds` start where its
    /// frame does — so a tab's frame is the same wherever it sits.
    private let upperSide = DeckClipView(frame: .zero)
    private let blockSide = DeckClipView(frame: .zero)
    private let lowerSide = DeckClipView(frame: .zero)
    /// The pinned block the deck is laid out around, if any.
    private var pinnedBlock: DeckGeometry.PinnedBlock?
    private var cards: [NoteCardView] = []
    private var overflowCard: OverflowCardView?
    private var plusButton: PlusButtonView?
    /// Today's Daily, the round calendar button beside the "+".
    private var dailyButton: PlusButtonView?
    private let hoverLabel = HoverLabel()
    var hoverLabelForTesting: HoverLabel { hoverLabel }
    private var roundButtons: [PlusButtonView] { [plusButton, dailyButton].compactMap { $0 } }
    private var trackingArea: NSTrackingArea?

    /// How far the tab under the cursor reaches out of the edge: Settings >
    /// Deck > Hover magnification.
    private var lift: CGFloat { AppSettings.shared.hoverLift }
    private var metrics: DeckGeometry.Metrics { DeckGeometry.Metrics(hoverLift: lift) }

    /// The cursor over the column, while it is over a tab.
    private var hover: DeckGeometry.Hover?
    /// The height the screen leaves for the deck, and where everything in it
    /// goes for that height — see `DeckGeometry`.
    private var usableHeight: CGFloat = 0
    private(set) var geometry = DeckGeometry.layout(count: 0, usableHeight: 0, columnWidth: 0)
    /// How far the column has scrolled, in points. Kept across rebuilds so
    /// editing a note does not jump the deck back to the top.
    var scrollOffset: CGFloat { geometry.scrollOffset }
    var lowerScrollOffset: CGFloat { geometry.lowerScrollOffset }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(clip)
        for side in [upperSide, lowerSide, blockSide] { clip.addSubview(side) }
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    // MARK: - VoiceOver

    /// Resting, the stripe is one button ("KeepNote deck, 8 notes") that opens
    /// the deck. Open, the tabs top to bottom — as they are drawn, not as
    /// they are layered — then "+N", the "+" and Today's Daily.
    override func isAccessibilityElement() -> Bool { state == .resting }
    override func accessibilityRole() -> NSAccessibility.Role? { state == .resting ? .button : .group }
    override func accessibilityLabel() -> String? { L("KeepNote deck") }
    override func accessibilityValue() -> Any? { AccessibilityText.deckValue(count: controller?.noteCount ?? 0) }
    override func accessibilityHelp() -> String? { state == .resting ? L("Opens the deck") : nil }

    override func accessibilityPerformPress() -> Bool {
        guard state == .resting else { return false }
        controller?.openFromKeyboardOrVoiceOver()
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        guard state == .fanned else { return [] }
        var children: [Any] = cards.enumerated()
            .filter { geometry.alphas.indices.contains($0.offset) && geometry.alphas[$0.offset] > 0.01 }
            .map(\.element)
        if let overflowCard, !overflowCard.isHidden { children.append(overflowCard) }
        children += [plusButton as Any?, dailyButton as Any?].compactMap { $0 }
        return children
    }

    // MARK: - Keyboard (Focus Deck)

    /// The stop the keyboard is on: a tab, "+N", "+" or Today's Daily, in the
    /// order VoiceOver reads them.
    private(set) var keyboardIndex: Int?
    private var keyboardStops: [NSView] { accessibilityOrderForTesting }
    var keyboardStop: NSView? { keyboardIndex.flatMap { keyboardStops.indices.contains($0) ? keyboardStops[$0] : nil } }

    override var acceptsFirstResponder: Bool { keyboardIndex != nil }

    func beginKeyboardFocus() {
        keyboardIndex = keyboardStops.isEmpty ? nil : 0
        showKeyboardFocus()
    }

    func endKeyboardFocus() {
        keyboardIndex = nil
        showKeyboardFocus()
        if hover != nil { setHover(nil) }
    }

    /// One step down (or up), stopping at either end.
    func moveKeyboardFocus(by step: Int) {
        guard let index = keyboardIndex, !keyboardStops.isEmpty else { return }
        keyboardIndex = min(max(index + step, 0), keyboardStops.count - 1)
        showKeyboardFocus()
    }

    override func keyDown(with event: NSEvent) {
        guard keyboardIndex != nil else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 125, 124: moveKeyboardFocus(by: 1)                  // down, right
        case 126, 123: moveKeyboardFocus(by: -1)                 // up, left
        case 48: moveKeyboardFocus(by: shift ? -1 : 1)           // Tab
        case 115: keyboardIndex = 0; showKeyboardFocus()         // Home
        case 119: keyboardIndex = max(0, keyboardStops.count - 1); showKeyboardFocus()   // End
        case 36, 76:                                             // Return
            if let stop = keyboardStop { controller?.pressFromKeyboard(stop) }
        case 49:                                                 // Space
            if let card = keyboardStop as? NoteCardView { controller?.peekFromKeyboard(noteID: card.noteID) }
        case 53: controller?.endKeyboardFocus(giveBack: true)    // Esc
        default: super.keyDown(with: event)
        }
    }

    /// The focused stop drawn with the keyboard ring, a focused tab opened as
    /// hovering opens it and scrolled into view, and VoiceOver told.
    private func showKeyboardFocus() {
        let stop = keyboardStop
        for view in [cards as [NSView], [overflowCard, plusButton, dailyButton].compactMap { $0 }].joined() {
            (view as? KeyboardFocusable)?.showsKeyboardFocus = view === stop
        }
        if let card = stop as? NoteCardView, let index = cards.firstIndex(of: card) {
            revealTab(index)
            setHover(DeckGeometry.Hover(index: index, cursorY: geometry.frames[index].midY))
        } else if stop != nil, hover != nil {
            setHover(nil)
        }
        if let stop { NSAccessibility.post(element: stop, notification: .focusedUIElementChanged) }
    }

    /// Scrolls the part of the deck tab `index` is in until it is whole.
    private func revealTab(_ index: Int) {
        guard geometry.frames.indices.contains(index) else { return }
        let frame = geometry.frames[index]
        let clipRect = geometry.clip(of: index)
        var delta: CGFloat = 0
        if frame.minY < clipRect.minY { delta = clipRect.minY - frame.minY }
        if frame.maxY > clipRect.maxY { delta = clipRect.maxY - frame.maxY }
        guard delta != 0 else { return }
        if let pinned = geometry.pinned, index >= pinned.above + pinned.count {
            setScrollOffset(lowerScrollOffset: lowerScrollOffset + delta, animated: true)
        } else {
            setScrollOffset(scrollOffset + delta, animated: true)
        }
    }

    /// The tabs in the order VoiceOver reads them, for the tests.
    var accessibilityOrderForTesting: [NSView] { (accessibilityChildren() ?? []).compactMap { $0 as? NSView } }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if state == .resting {
            controller?.cursorDidArrive(at: screenPoint(of: event), time: event.timestamp)
        } else {
            controller?.cursorDidEnter()
        }
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if state == .resting {
            controller?.cursorDidMoveOnStripe(to: screenPoint(of: event), time: event.timestamp)
        }
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
        controller?.cursorDidExit()
    }

    private func screenPoint(of event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    var hoveredNoteID: UUID? {
        geometry.hovered.flatMap { cards.indices.contains($0) ? cards[$0].noteID : nil }
    }

    /// The tab under the cursor is the one drawn there now — lower tabs over
    /// upper ones, the open one uncovered — not the one its own bounds
    /// contain, which overlap. Moving within the open tab changes nothing:
    /// it stays put under the cursor.
    private func updateHover(with event: NSEvent) {
        guard state == .fanned, !isFanningIn else { return }
        let point = clip.convert(event.locationInWindow, from: nil)
        guard let index = geometry.tab(at: point) else {
            setHover(nil)
            return
        }
        guard index != geometry.hovered else { return }
        setHover(DeckGeometry.Hover(index: index, cursorY: point.y))
    }

    private func setHover(_ newHover: DeckGeometry.Hover?) {
        let previous = geometry.hovered.map { cards[$0].noteID }
        let before = geometry.hovered
        hover = newHover
        guard !cards.isEmpty else { return }
        relayout()
        // The tab under the cursor is drawn over its neighbours; the others
        // stay where they are.
        if geometry.hovered != before { arrangeSides() }
        layoutCards(animated: true, config: .hover)
        let current = geometry.hovered.map { cards[$0].noteID }
        guard previous != current else { return }
        if let previous { controller?.cardHoverChanged(noteID: previous, entered: false) }
        if let current { controller?.cardHoverChanged(noteID: current, entered: true) }
    }

    /// A click on the resting stripe starts a note. The deck is hover-driven,
    /// but an empty deck has nothing to fan out, so the stripe stays useful.
    override func mouseDown(with event: NSEvent) {
        guard state == .resting else { return }
        controller?.pillClicked()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard state == .resting, let menu = controller?.contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Scrolling

    /// Real scrolling, not paging.
    ///
    /// A trackpad reports precise deltas, so its gesture is applied 1:1 with no
    /// animation — the column tracks the fingers. A wheel click reports one
    /// coarse notch, which would read as a jump, so that one is eased.
    override func scrollWheel(with event: NSEvent) {
        guard state == .fanned, !cards.isEmpty else { return }
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 14
        guard delta != 0 else { return }
        // The peek points at a tab that is about to move; it goes.
        controller?.deckDidScroll()
        // The deck lies flat while it scrolls; the next move of the cursor
        // opens whatever tab is under it then.
        if let hovered = geometry.hovered {
            hover = nil
            controller?.cardHoverChanged(noteID: cards[hovered].noteID, entered: false)
        }
        // Around a pinned block each side scrolls on its own: the wheel moves
        // the side the cursor is on.
        let part = geometry.scrollPart(atY: clip.convert(event.locationInWindow, from: nil).y)
        switch part {
        case .upper: setScrollOffset(scrollOffset - delta, animated: !precise)
        case .lower: setScrollOffset(lowerScrollOffset: lowerScrollOffset - delta, animated: !precise)
        }
    }

    func setScrollOffset(_ value: CGFloat? = nil, lowerScrollOffset: CGFloat? = nil, animated: Bool) {
        relayout(scrollOffset: value, lowerScrollOffset: lowerScrollOffset)
        layoutCards(animated: animated)
    }

    /// Works the geometry out again for the cards on hand.
    private func relayout(scrollOffset: CGFloat? = nil, lowerScrollOffset: CGFloat? = nil) {
        geometry = DeckGeometry.layout(
            count: cards.count,
            usableHeight: usableHeight,
            columnWidth: clip.bounds.width,
            scrollOffset: scrollOffset ?? self.scrollOffset,
            lowerScrollOffset: lowerScrollOffset ?? self.lowerScrollOffset,
            pinned: pinnedBlock,
            hover: hover,
            edge: edge,
            metrics: metrics
        )
    }

    /// The part of the column each group of tabs shows in.
    private func layoutSides() {
        let column = clip.bounds
        let upper = geometry.pinned == nil ? column : geometry.upperClip
        let lower = geometry.pinned == nil ? column : geometry.lowerClip
        for (side, rect) in [(upperSide, upper), (blockSide, column), (lowerSide, lower)] {
            if side.frame != rect { side.frame = rect }
            if side.bounds != rect { side.bounds = rect }
        }
    }

    /// The part of the column card `index` is drawn in.
    private func side(forIndex index: Int) -> NSView {
        guard let pinned = geometry.pinned else { return upperSide }
        if index < pinned.above { return upperSide }
        return index < pinned.above + pinned.count ? blockSide : lowerSide
    }

    /// Puts every card in the part its place calls for, lower tabs over
    /// upper ones — but for the hovered one, which is over all of them — and
    /// `leaving` cards underneath their part's tabs.
    private func arrangeSides(leaving: [NoteCardView] = []) {
        for (index, card) in cards.enumerated() where card.superview !== side(forIndex: index) {
            side(forIndex: index).addSubview(card)
        }
        let raised = geometry.hovered.flatMap { cards.indices.contains($0) ? cards[$0] : nil }
        for side in [upperSide, blockSide, lowerSide] {
            var mine = cards.enumerated().filter { self.side(forIndex: $0.offset) === side }.map(\.element)
            // The hovered tab goes over the rest of its part of the column.
            if let raised, let at = mine.firstIndex(of: raised) { mine.append(mine.remove(at: at)) }
            let going = leaving.filter { $0.superview === side }
            side.subviews = going + mine
        }
    }

    /// Column position of card `index`, in clip-view coordinates. Tabs are
    /// flush with the screen edge; the gutter to their left is what a hovered
    /// card grows into.
    private func origin(forIndex index: Int) -> NSPoint {
        geometry.frames[index].origin
    }

    /// Tabs at the clip boundary fade over the last few points rather than
    /// vanish — that hard cut is what made paging feel like a re-render.
    private func layoutCards(animated: Bool, config: SpringConfig = .scroll) {
        for (index, card) in cards.enumerated() {
            // A hovered tab is over its neighbours: it shows whole.
            card.visibleSlice = index == geometry.hovered ? EdgeMetrics.tabHeight : geometry.slices[index]
            card.isHovered = index == geometry.hovered
            card.setTarget(geometry.frames[index], alpha: geometry.alphas[index], animated: animated, config: config)
        }
        updateOverflowCount()
    }

    /// The chip counts what is out of sight, so it doubles as a scroll
    /// indicator rather than being a fixed "everything past eight".
    private func updateOverflowCount() {
        guard let overflowCard else { return }
        overflowCard.update(remaining: geometry.hiddenCount)
        overflowCard.isHidden = geometry.hiddenCount == 0
    }

    // MARK: - Resting stripe

    /// Marks the tabs of floating notes, live, without re-dealing the deck.
    func setFloating(_ ids: Set<UUID>) {
        cards.forEach { $0.isFloating = ids.contains($0.noteID) }
    }

    func updatePill(colors: [NoteColor], highlighted: Bool) {
        pill.colors = colors
        pill.isHighlighted = highlighted
    }

    func layoutPill(height: CGFloat) {
        pill.edge = edge
        pill.needsDisplay = true
        pill.frame = NSRect(
            x: edge.mirroredX(bounds.width - EdgeMetrics.pillWidth, itemWidth: EdgeMetrics.pillWidth, in: bounds.width),
            y: (bounds.height - height) / 2,
            width: EdgeMetrics.pillWidth,
            height: height
        )
    }

    func setPillVisible(_ visible: Bool, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                pill.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            pill.alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Deck

    /// Builds the deck and shingles it down the edge.
    ///
    /// Every note gets a card, however many there are; the clip view decides
    /// what is on screen. Card *i* slides in at `i * stagger` — the spec's
    /// 45 ms — which is what makes the deck read as dealing itself out.
    func fanOut(
        notes: [Note],
        usableHeight: CGFloat,
        pinned: DeckGeometry.PinnedBlock? = nil,
        stagger: Double,
        preserveScroll: Bool
    ) {
        // The cursor came back while the deck was still folding away: the same
        // cards turn around where they are, instead of vanishing and being
        // dealt out again from the edge.
        if isFanningIn, !preserveScroll, cards.map(\.noteID) == notes.map(\.id), self.usableHeight == usableHeight {
            reviveDeck(stagger: stagger)
            return
        }

        let previousOffset = preserveScroll ? scrollOffset : 0
        let previousLowerOffset = preserveScroll ? lowerScrollOffset : 0
        clearDeck()
        state = .fanned
        self.usableHeight = usableHeight
        pinnedBlock = pinned
        let tabHeight = EdgeMetrics.tabHeight
        geometry = DeckGeometry.layout(count: notes.count, usableHeight: usableHeight, columnWidth: bounds.width,
                                       pinned: pinned, edge: edge, metrics: metrics)

        layoutChrome(showsOverflow: geometry.showsOverflow)

        let offscreenX = edge.offscreenX(itemWidth: EdgeMetrics.tabWidth + lift, in: bounds.width)
        for (index, note) in notes.enumerated() {
            let card = makeCard(for: note)
            side(forIndex: index).addSubview(card)
            cards.append(card)

            let target = origin(forIndex: index)
            card.visibleSlice = geometry.slices[index]
            card.setTarget(geometry.frames[index], alpha: geometry.alphas[index], animated: false)
            let isOnScreen = target.y + tabHeight > 0 && target.y < clip.bounds.height

            // Preserving the scroll means the deck is already on screen and
            // only its contents changed. Re-dealing it would be a flicker.
            if isOnScreen, !preserveScroll {
                card.place(frame: NSRect(origin: NSPoint(x: offscreenX, y: target.y), size: card.frame.size), alpha: 0)
                slideIn(card, to: target, after: Double(index) * stagger)
            }
        }

        if previousOffset != 0 || previousLowerOffset != 0 {
            relayout(scrollOffset: previousOffset, lowerScrollOffset: previousLowerOffset)
            layoutCards(animated: false)
        } else {
            updateOverflowCount()
        }

        if !preserveScroll {
            for button in roundButtons {
                let target = button.baseOrigin
                button.place(frame: NSRect(origin: NSPoint(x: offscreenX, y: target.y), size: button.frame.size), alpha: 0)
                slideIn(button, to: target, after: Double(min(notes.count, 8)) * stagger)
            }
        }
        if let overflowCard, !overflowCard.isHidden, !preserveScroll {
            let target = overflowCard.baseOrigin
            overflowCard.place(frame: NSRect(origin: NSPoint(x: offscreenX, y: target.y), size: overflowCard.frame.size), alpha: 0)
            slideIn(overflowCard, to: target, after: Double(min(notes.count, 8)) * stagger)
        }
    }

    private func makeCard(for note: Note) -> NoteCardView {
        let card = NoteCardView(note: note, height: EdgeMetrics.tabHeight, edge: edge)
        card.isFloating = controller?.floatingNoteIDs.contains(note.id) ?? false
        card.onActivate = { [weak self] id in self?.controller?.activate(noteID: id) }
        card.onContextAction = { [weak self] id, action in
            self?.controller?.performContextAction(action, on: id)
        }
        return card
    }

    // MARK: - Notes added and removed

    /// Where every piece of the open deck is on screen. Taken before the
    /// panel is resized, so the pieces can be carried over to where they
    /// were and spring on from there instead of jumping with the panel.
    struct Snapshot {
        var cards: [UUID: NSRect] = [:]
        var plus: NSRect?
        var daily: NSRect?
        var chip: NSRect?
    }

    func snapshot() -> Snapshot {
        guard state == .fanned, let window else { return Snapshot() }
        func onScreen(_ view: NSView) -> NSRect { window.convertToScreen(view.convert(view.bounds, to: nil)) }
        var snapshot = Snapshot()
        for card in cards { snapshot.cards[card.noteID] = onScreen(card) }
        snapshot.plus = plusButton.map(onScreen)
        snapshot.daily = dailyButton.map(onScreen)
        snapshot.chip = overflowCard.map(onScreen)
        return snapshot
    }

    /// The open deck after notes were added, removed or changed. Cards that
    /// stay spring from where they are to the new step, new ones slide in
    /// from the edge, removed ones slide out.
    func update(notes: [Note], usableHeight: CGFloat, pinned: DeckGeometry.PinnedBlock? = nil, from snapshot: Snapshot) {
        guard state == .fanned, !isFanningIn, let window else {
            fanOut(notes: notes, usableHeight: usableHeight, pinned: pinned, stagger: 0, preserveScroll: true)
            return
        }
        self.usableHeight = usableHeight
        pinnedBlock = pinned
        let hoveredID = hoveredNoteID

        var remaining = Dictionary(uniqueKeysWithValues: cards.map { ($0.noteID, $0) })
        cards = notes.map { note in
            if let card = remaining.removeValue(forKey: note.id) {
                card.show(note)
                return card
            }
            return makeCard(for: note)
        }
        let leaving = Array(remaining.values)

        if let hoveredID, let hover, let index = cards.firstIndex(where: { $0.noteID == hoveredID }) {
            self.hover = DeckGeometry.Hover(index: index, cursorY: hover.cursorY)
        } else {
            hover = nil
        }
        relayout()
        updateChrome()
        // Lower tabs over upper ones; leaving cards underneath everything.
        arrangeSides(leaving: leaving)

        func local(_ rect: NSRect, in view: NSView) -> NSRect {
            view.convert(window.convertFromScreen(rect), from: nil)
        }
        let offscreenX = edge.offscreenX(itemWidth: EdgeMetrics.tabWidth + lift, in: clip.bounds.width)
        for (index, card) in cards.enumerated() {
            let target = geometry.frames[index]
            if let was = snapshot.cards[card.noteID] {
                card.place(frame: local(was, in: clip))
            } else {
                card.place(frame: NSRect(x: offscreenX, y: target.minY, width: target.width, height: target.height), alpha: 0)
            }
        }
        layoutCards(animated: true, config: .deck)

        for (view, was) in [(plusButton as SpringView?, snapshot.plus), (dailyButton, snapshot.daily), (overflowCard, snapshot.chip)] {
            guard let view else { continue }
            let origin = (view as? PlusButtonView)?.baseOrigin ?? (view as? OverflowCardView)?.baseOrigin ?? view.frame.origin
            if let was {
                view.place(frame: local(was, in: self))
            } else {
                view.place(frame: NSRect(origin: NSPoint(x: edge.offscreenX(itemWidth: view.frame.width, in: bounds.width), y: origin.y),
                                         size: view.frame.size), alpha: 0)
            }
            view.move(to: NSRect(origin: origin, size: view.frame.size), alpha: 1, config: .deck)
        }

        for card in leaving {
            if let was = snapshot.cards[card.noteID] { card.place(frame: local(was, in: clip)) }
            card.move(to: NSRect(origin: NSPoint(x: offscreenX, y: card.frame.minY), size: card.frame.size),
                      alpha: 0, config: .deck)
        }
        leavingCards.append(contentsOf: leaving)
        let settle = Motion.reduceMotion ? 0.25 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            for card in leaving {
                card.stopMotion()
                card.removeFromSuperview()
            }
            self?.leavingCards.removeAll { leaving.contains($0) }
        }
        updateOverflowCount()
    }

    /// Cards on their way out after their note was removed.
    private var leavingCards: [NoteCardView] = []

    /// The "+" stays; the "+N" chip comes and goes with scrolling; the column
    /// takes the height the geometry gives it.
    private func updateChrome() {
        placeRoundButtons()
        if geometry.showsOverflow, overflowCard == nil {
            makeChip()
        } else if geometry.showsOverflow, let chip = overflowCard {
            chip.baseOrigin = chipOrigin
        } else if !geometry.showsOverflow, let chip = overflowCard {
            chip.stopMotion()
            chip.removeFromSuperview()
            overflowCard = nil
        }
        clip.frame = NSRect(x: 0, y: geometry.columnBottom, width: bounds.width, height: geometry.columnHeight)
        layoutSides()
    }

    /// The "+" in the corner by the edge, Today's Daily just inside it.
    private func placeRoundButtons() {
        let diameter = EdgeMetrics.plusDiameter
        let plusX = bounds.width - diameter - 6
        let y = geometry.chromeBottom + 2
        plusButton?.baseOrigin = NSPoint(x: edge.mirroredX(plusX, itemWidth: diameter, in: bounds.width), y: y)
        let dailyX = plusX - diameter - EdgeMetrics.dailyButtonGap
        dailyButton?.baseOrigin = NSPoint(x: edge.mirroredX(dailyX, itemWidth: diameter, in: bounds.width), y: y)
    }

    private var chipOrigin: NSPoint {
        NSPoint(x: edge.mirroredX(bounds.width - EdgeMetrics.tabWidth, itemWidth: EdgeMetrics.tabWidth, in: bounds.width),
                y: geometry.chromeBottom + EdgeMetrics.plusDiameter + EdgeMetrics.plusTopMargin)
    }

    private func makeChip() {
        let chip = OverflowCardView(remaining: 0)
        chip.edge = edge
        chip.baseOrigin = chipOrigin
        chip.frame = NSRect(origin: chip.baseOrigin, size: chip.frame.size)
        chip.onActivate = { [weak self] in self?.controller?.showAllNotes() }
        addSubview(chip)
        overflowCard = chip
    }

    /// The "+" and the "+N" chip are pinned below the scrolling column, so they
    /// stay reachable however far the deck is scrolled.
    private func layoutChrome(showsOverflow: Bool) {
        let plus = PlusButtonView()
        plus.onActivate = { [weak self] in self?.controller?.pillClicked() }
        addSubview(plus)
        plusButton = plus

        let daily = PlusButtonView(glyph: .calendar)
        daily.onHoverChanged = { [weak self, weak daily] hovered in
            guard let self, let daily, let window = self.window else { return }
            if hovered {
                let frame = window.convertToScreen(daily.convert(daily.bounds, to: nil))
                self.hoverLabel.show(L("add daily"), besides: frame, towards: self.edge.inward, above: window.level)
            } else {
                self.hoverLabel.hide()
            }
        }
        daily.onActivate = { [weak self] in self?.controller?.dailyClicked() }
        addSubview(daily)
        dailyButton = daily

        placeRoundButtons()
        for button in roundButtons { button.frame = NSRect(origin: button.baseOrigin, size: button.frame.size) }

        if showsOverflow { makeChip() }

        clip.frame = NSRect(
            x: 0,
            y: geometry.columnBottom,
            width: bounds.width,
            height: geometry.columnHeight
        )
        layoutSides()
    }

    /// A card deals out on a spring, `delay` after the one before it. Without
    /// Reduce Motion the travel is the spring's; with it, the card just fades.
    private func slideIn(_ view: SpringView, to origin: NSPoint, after delay: Double) {
        view.move(
            to: NSRect(origin: origin, size: view.frame.size),
            alpha: 1,
            config: .deck,
            delay: delay
        )
    }

    private var isFanningIn = false
    private var fanInToken = 0

    /// Turns a deck that is mid-fold-away back around: every card springs from
    /// wherever it has got to, back onto the screen, with the same stagger.
    private func reviveDeck(stagger: Double) {
        isFanningIn = false
        fanInToken &+= 1
        state = .fanned
        for (index, card) in cards.enumerated() {
            card.setTarget(
                geometry.frames[index],
                alpha: geometry.alphas[index],
                animated: true,
                config: .deck,
                delay: Double(index) * stagger
            )
        }
        let chromeDelay = Double(min(cards.count, 8)) * stagger
        for button in roundButtons {
            slideIn(button, to: button.baseOrigin, after: chromeDelay)
        }
        if let overflowCard, !overflowCard.isHidden {
            slideIn(overflowCard, to: overflowCard.baseOrigin, after: chromeDelay)
        }
        updateOverflowCount()
    }

    /// Reverses the deal: the bottom of the deck leaves first, so it gathers
    /// back up toward the stripe.
    func fanIn(completion: @escaping () -> Void) {
        guard state == .fanned else {
            completion()
            return
        }
        state = .resting
        isFanningIn = true
        fanInToken &+= 1
        let token = fanInToken

        let offscreen = { (view: NSView) in self.edge.offscreenX(itemWidth: view.frame.width, in: self.bounds.width) }
        var leaving: [SpringView] = []
        leaving.append(contentsOf: roundButtons)
        hoverLabel.hide()
        if let overflowCard, !overflowCard.isHidden { leaving.append(overflowCard) }
        leaving.append(contentsOf: cards.filter { $0.alphaValue > 0.05 }.reversed())

        guard !leaving.isEmpty else {
            isFanningIn = false
            clearDeck()
            completion()
            return
        }

        let step = 0.018
        for (index, view) in leaving.enumerated() {
            view.move(
                to: NSRect(origin: NSPoint(x: offscreen(view), y: view.frame.origin.y), size: view.frame.size),
                alpha: 0,
                config: .deck,
                delay: Double(index) * step
            )
        }

        // The springs need a beat to settle off screen; a fold interrupted by
        // the cursor coming back bumps the token and this does nothing.
        let settle = Motion.reduceMotion ? 0.25 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(leaving.count) * step + settle) { [weak self] in
            guard let self, token == self.fanInToken else { return }
            self.isFanningIn = false
            self.clearDeck()
            completion()
        }
    }

    func clearDeck() {
        hover = nil
        leavingCards.forEach { $0.stopMotion(); $0.removeFromSuperview() }
        leavingCards.removeAll()
        geometry = DeckGeometry.layout(count: 0, usableHeight: usableHeight, columnWidth: bounds.width, edge: edge)
        pinnedBlock = nil
        cards.forEach { $0.stopMotion(); $0.removeFromSuperview() }
        cards.removeAll()
        overflowCard?.stopMotion()
        overflowCard?.removeFromSuperview()
        overflowCard = nil
        hoverLabel.hide()
        for button in roundButtons {
            button.stopMotion()
            button.removeFromSuperview()
        }
        plusButton = nil
        dailyButton = nil
    }

    /// Frame the tab for `noteID` occupies, in screen coordinates. The note
    /// window uses it as the starting point of its slide.
    ///
    /// Where the tab is going rather than where its spring has got to, so a
    /// peek or a note opened while the deck is still opening a tab lines up
    /// with where that tab comes to rest.
    func screenFrame(forNoteID noteID: UUID) -> NSRect? {
        guard let index = cards.firstIndex(where: { $0.noteID == noteID }), let window,
              geometry.frames.indices.contains(index) else { return nil }
        return window.convertToScreen(clip.convert(geometry.frames[index], to: nil))
    }

    /// Clicks go to the tab whose visible part is under the cursor — the same
    /// rule as hovering — not to whichever card's bounds happen to be there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard state == .fanned, hit === self || hit is NoteCardView, let superview else { return hit }
        let inClip = clip.convert(point, from: superview)
        guard clip.bounds.contains(inClip) else { return hit }
        guard let index = geometry.tab(at: inClip), cards.indices.contains(index) else { return self }
        return cards[index]
    }
}
