import AppKit

/// One note's tab in the fanned deck: the left edge of its card, flush against
/// the screen edge, carrying the colour and the rotated label.
final class NoteCardView: SpringView {
    let noteID: UUID
    private var label: String
    private var color: NoteColor
    private var isArchivedHint: Bool
    /// Keep on Deck is on: the context menu shows it ticked.
    private var keepOnDeck: Bool
    /// Pinned to the center: the context menu shows it ticked.
    /// In the last two days before the time rule archives it: a small clock.
    private(set) var isExpiring: Bool {
        didSet { if isExpiring != oldValue { needsDisplay = true } }
    }
    private(set) var isPinned: Bool {
        didSet { if isPinned != oldValue { needsDisplay = true } }
    }

    var onActivate: ((UUID) -> Void)?
    /// The note is floating on the desk. Its tab carries a small Float Note
    /// glyph at the top, and clicking the tab brings that note forward.
    var isFloating = false {
        didSet { if isFloating != oldValue { needsDisplay = true } }
    }
    /// A daily note: a small calendar sits by its label.
    private(set) var isDaily: Bool {
        didSet { if isDaily != oldValue { needsDisplay = true } }
    }
    var onContextAction: ((UUID, ContextAction) -> Void)?
    /// How much of the tab shows, from its top: the rest is under the tab
    /// below. The label only draws when it fits in this whole.
    var visibleSlice: CGFloat = EdgeMetrics.tabHeight {
        didSet { if visibleSlice != oldValue { needsDisplay = true } }
    }

    enum ContextAction {
        case open
        case markComplete
        case cycleColor
        case togglePin
        case toggleKeep
        case delete
    }

    /// Moves the tab to `frame` — on a spring, which an aim taken mid-flight
    /// bends rather than restarts, or at once.
    func setTarget(
        _ frame: NSRect,
        alpha: CGFloat? = nil,
        animated: Bool,
        config: SpringConfig = .scroll,
        delay: TimeInterval = 0
    ) {
        if animated {
            move(to: frame, alpha: alpha, config: config, delay: delay)
        } else {
            place(frame: frame, alpha: alpha)
        }
    }

    /// Lifted, the card casts a deeper shadow — that is most of what makes it
    /// read as having come forward out of the stack.
    private func applyShadow() {
        NoteCardShape.applyShadow(to: self, strength: isHovered ? 1.7 : 1)
    }

    /// Set by the deck. Once tabs overlap, a tab's own bounds are mostly under
    /// its neighbours, so only the deck — which knows what is drawn where —
    /// can say which tab the cursor is on.
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            applyShadow()
        }
    }

    init(note: Note, height: CGFloat) {
        self.noteID = note.id
        self.label = note.spineLabel
        self.color = note.color
        self.isArchivedHint = note.state == .archived
        self.keepOnDeck = note.keepOnDeck
        self.isPinned = note.isPinned
        self.isExpiring = DeckStatus.isExpiring(note)
        self.isDaily = note.isDaily
        super.init(frame: NSRect(x: 0, y: 0, width: EdgeMetrics.tabWidth, height: height))
        place(frame: frame)
        NoteCardShape.applyShadow(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The same note, changed: a new title or colour is drawn on the card
    /// already in the deck instead of on a replacement.
    func show(_ note: Note) {
        guard note.id == noteID else { return }
        let changed = label != note.spineLabel || color != note.color || isArchivedHint != (note.state == .archived)
        label = note.spineLabel
        color = note.color
        isArchivedHint = note.state == .archived
        isDaily = note.isDaily
        keepOnDeck = note.keepOnDeck
        isPinned = note.isPinned
        isExpiring = DeckStatus.isExpiring(note)
        if changed { needsDisplay = true }
    }

    /// The card's frame changes on hover and on every scroll, so the shadow
    /// silhouette has to be re-cut to match.
    override func layout() {
        super.layout()
        NoteCardShape.updateShadowPath(on: self)
    }

    override func mouseDown(with event: NSEvent) { onActivate?(noteID) }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Next Color", action: #selector(menuColor), keyEquivalent: "").target = self
        let pin = menu.addItem(withTitle: "Pin to Center", action: #selector(menuPin), keyEquivalent: "")
        pin.target = self
        pin.state = isPinned ? .on : .off
        let keep = menu.addItem(withTitle: "Keep on Deck", action: #selector(menuKeep), keyEquivalent: "")
        keep.target = self
        keep.state = keepOnDeck ? .on : .off
        menu.addItem(withTitle: "Mark Complete", action: #selector(menuComplete), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(menuDelete), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuOpen() { onContextAction?(noteID, .open) }
    @objc private func menuComplete() { onContextAction?(noteID, .markComplete) }
    @objc private func menuColor() { onContextAction?(noteID, .cycleColor) }
    @objc private func menuPin() { onContextAction?(noteID, .togglePin) }
    @objc private func menuKeep() { onContextAction?(noteID, .toggleKeep) }
    @objc private func menuDelete() { onContextAction?(noteID, .delete) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let body = NoteCardShape.path(in: bounds)
        // The tab is the note's paper; the spine colour belongs to the open note.
        color.surface.setFill()
        body.fill()

        NoteCardShape.drawPerforation(
            at: bounds.maxX - 9,
            in: bounds,
            color: color.ink.withAlphaComponent(0.20)
        )

        // Floating and daily: the label gives up the top of the tab to the
        // markers, the floating one first, the calendar under it.
        let markerZone: CGFloat = (isFloating ? 16 : 0) + (isDaily ? 14 : 0) + (isPinned ? 14 : 0)
        NoteCardShape.drawTabLabel(
            label,
            in: NSRect(x: 0, y: 0, width: bounds.width - 12, height: bounds.height),
            slice: visibleSlice,
            markerZone: markerZone,
            color: isArchivedHint ? color.secondaryInk.withAlphaComponent(0.6) : color.secondaryInk,
            context: context
        )
        if isFloating { drawFloatingMarker() }
        if isDaily { drawDailyMarker(below: isFloating ? 16 : 0) }
        if isExpiring { drawExpiringMarker() }
        if isPinned { drawPinMarker(below: (isFloating ? 16 : 0) + (isDaily ? 14 : 0)) }

        if isHovered {
            color.spine.withAlphaComponent(0.95).setStroke()
            body.lineWidth = 1.5
            body.stroke()
        }
    }
}

extension NoteCardView {
    /// The Float Note glyph, small and in the quiet ink, at the top of the tab.
    fileprivate func drawFloatingMarker() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.secondaryInk.withAlphaComponent(0.8)]))
        guard let glyph = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Floating")?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        let tabWidth = bounds.width - 12
        glyph.draw(in: NSRect(x: (tabWidth - size.width) / 2, y: bounds.maxY - 8 - size.height,
                              width: size.width, height: size.height))
    }
}

extension NoteCardView {
    /// A small clock in the quiet ink at the top right of the tab, beside the
    /// label rather than over it, so it shows even where tabs overlap and a
    /// slice has no room for another marker.
    fileprivate func drawExpiringMarker() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.secondaryInk.withAlphaComponent(0.75)]))
        guard let glyph = NSImage(systemSymbolName: "clock", accessibilityDescription: "Archives soon")?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        let tabWidth = bounds.width - 12
        glyph.draw(in: NSRect(x: tabWidth - size.width - 2, y: bounds.maxY - 6 - size.height,
                              width: size.width, height: size.height))
    }
}

extension NoteCardView {
    /// A small pin in the quiet ink, over the label, under the other markers.
    fileprivate func drawPinMarker(below offset: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.secondaryInk.withAlphaComponent(0.8)]))
        guard let glyph = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        let tabWidth = bounds.width - 12
        glyph.draw(in: NSRect(x: (tabWidth - size.width) / 2, y: bounds.maxY - 8 - offset - size.height,
                              width: size.width, height: size.height))
    }
}

extension NoteCardView {
    /// A small calendar in the quiet ink, at the top of the tab (under the
    /// floating marker, when there is one), centred over the label.
    fileprivate func drawDailyMarker(below offset: CGFloat) {
        let size: CGFloat = 9
        let tabWidth = bounds.width - 12
        color.secondaryInk.withAlphaComponent(0.8).setStroke()
        CalendarGlyph.draw(
            in: NSRect(x: (tabWidth - size) / 2, y: bounds.maxY - 8 - offset - size, width: size, height: size),
            lineWidth: 1
        )
    }
}

/// The "+N" chip below the deck, counting the tabs scrolled out of sight once
/// the screen cannot hold them all. Clicking it opens All Notes.
final class OverflowCardView: SpringView {
    private var remaining: Int
    var onActivate: (() -> Void)?
    var baseOrigin: NSPoint = .zero

    init(remaining: Int) {
        self.remaining = remaining
        super.init(frame: NSRect(x: 0, y: 0, width: EdgeMetrics.tabWidth, height: EdgeMetrics.overflowHeight))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(remaining: Int) {
        self.remaining = remaining
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    override func draw(_ dirtyRect: NSRect) {
        let body = NoteCardShape.path(in: bounds, radius: 8)
        let fill = effectiveAppearance.isDark
            ? NSColor(white: 0.24, alpha: 0.92)
            : NSColor(white: 0.90, alpha: 0.95)
        fill.setFill()
        body.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: "+\(remaining)", attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2 - 3, y: (bounds.height - size.height) / 2))
    }
}

/// The round "+" under the deck: the one thing in the whole interface that
/// exists purely to be clicked.
final class PlusButtonView: SpringView {
    /// What the round button shows: the "+" of New Note, or the calendar of
    /// Today's Daily.
    enum Glyph { case plus, calendar }

    let glyph: Glyph
    var onActivate: (() -> Void)?
    var baseOrigin: NSPoint = .zero

    private var isHovered = false {
        didSet {
            needsDisplay = true
            if isHovered != oldValue { onHoverChanged?(isHovered) }
        }
    }

    /// The cursor came onto or left the button.
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    init(glyph: Glyph = .plus) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: EdgeMetrics.plusDiameter, height: EdgeMetrics.plusDiameter))
        NoteCardShape.applyShadow(to: self, strength: 0.7)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        onHoverChanged?(false)
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        let base = effectiveAppearance.isDark
            ? NSColor(white: 0.26, alpha: 0.96)
            : NSColor(white: 1.0, alpha: 0.97)
        (isHovered ? base.blended(withFraction: 0.08, of: .systemBlue) ?? base : base).setFill()
        circle.fill()

        NSColor(white: 0, alpha: 0.10).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        NSColor.secondaryLabelColor.setStroke()
        switch glyph {
        case .plus: drawPlus()
        case .calendar: CalendarGlyph.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14), lineWidth: 1.4)
        }
    }

    private func drawPlus() {
        let arm: CGFloat = 4.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.midY - arm))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.midY + arm))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.stroke()
    }
}

/// A small calendar, drawn in the current stroke colour: the mark of a daily
/// note on the deck and of the Today's Daily button. A page with a header bar
/// and two binding rings, square-ish so it reads at 8 pt.
enum CalendarGlyph {
    static func draw(in rect: NSRect, lineWidth: CGFloat) {
        let inset = lineWidth / 2
        let page = NSRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - lineWidth, height: rect.height * 0.86 - lineWidth)
        let body = NSBezierPath(roundedRect: page, xRadius: rect.width * 0.16, yRadius: rect.width * 0.16)
        body.lineWidth = lineWidth
        body.stroke()

        let header = NSBezierPath()
        let y = page.maxY - page.height * 0.30
        header.move(to: NSPoint(x: page.minX, y: y))
        header.line(to: NSPoint(x: page.maxX, y: y))
        for fraction in [0.3, 0.7] as [CGFloat] {
            let x = page.minX + page.width * fraction
            header.move(to: NSPoint(x: x, y: page.maxY - rect.height * 0.02))
            header.line(to: NSPoint(x: x, y: rect.maxY - inset))
        }
        header.lineWidth = lineWidth
        header.lineCapStyle = .round
        header.stroke()
    }
}
