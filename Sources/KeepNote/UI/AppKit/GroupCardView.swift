import AppKit

/// A group's tab in the fanned deck: closed, one tab for all of its notes, in
/// the group's colour with its name and how many notes it holds, and two
/// sheets behind it — a bundle, which is what tells it from a note; open, the
/// same tab as the header of the notes that follow it, without the sheets.
///
/// Every piece of text on it is the group's `ink` on its `fill`, which is a
/// pair that reads at 4.5:1 or better (`GroupPalette`). Daily is a group too,
/// in the colour of the daily template; its paper and ink are a note's.
final class GroupCardView: DeckTabView {
    /// How a group is coloured: one of the twelve, or — for Daily — a paper.
    enum Look: Equatable {
        case palette(GroupColor)
        case paper(NoteColor)

        var fill: NSColor {
            switch self {
            case .palette(let color): return color.fill
            case .paper(let color): return color.surface
            }
        }

        var ink: NSColor {
            switch self {
            case .palette(let color): return color.ink
            case .paper(let color): return color.ink
            }
        }

        /// The sheets behind a closed group and the outline: the fill shifted
        /// toward the dark ink.
        func sheet(_ depth: Int) -> NSColor {
            let amount: CGFloat = depth <= 1 ? 0.22 : 0.38
            return fill.blended(withFraction: amount, of: NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)) ?? fill
        }

        /// What VoiceOver says the colour is.
        var name: String {
            switch self {
            case .palette(let color): return color.displayName
            case .paper(let color): return color.displayName
            }
        }
    }

    let ref: DeckGroupRef
    private(set) var name: String
    private(set) var count: Int
    private(set) var look: Look
    private(set) var isOpen: Bool

    /// The tab was pressed (a click, Return, VoiceOver's press): the group
    /// opens or closes.
    var onToggle: ((DeckGroupRef) -> Void)?
    /// Notes dragged onto it. Only a group the user made takes them.
    var onDropNotes: (([UUID]) -> Void)?
    var acceptsDrops: Bool { if case .user = ref { return true } else { return false } }

    /// A drag with notes in it is over the tab.
    private(set) var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    /// What the context menu and VoiceOver's action say, in the words of the
    /// group's state; set by the deck.
    var announce: ((String) -> Void)?

    init(ref: DeckGroupRef, name: String, count: Int, look: Look, isOpen: Bool, height: CGFloat, edge: ScreenEdge) {
        self.ref = ref
        self.name = name
        self.count = count
        self.look = look
        self.isOpen = isOpen
        super.init(frame: NSRect(x: 0, y: 0, width: EdgeMetrics.tabWidth, height: height), edge: edge)
        place(frame: frame)
        NoteCardShape.applyShadow(to: self, edge: edge)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription(L("group tab"))
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The same group, changed: a new name, colour or count is drawn on the
    /// tab already in the deck.
    func show(name: String, count: Int, look: Look, isOpen: Bool) {
        let changed = self.name != name || self.count != count || self.look != look || self.isOpen != isOpen
        self.name = name
        self.count = count
        self.look = look
        self.isOpen = isOpen
        if changed { needsDisplay = true }
    }

    override func hoverDidChange() {
        NoteCardShape.applyShadow(to: self, strength: isHovered ? 1.7 : 1, edge: edge)
    }

    override func layout() {
        super.layout()
        NoteCardShape.updateShadowPath(on: self)
    }

    // MARK: - VoiceOver

    /// "Group Work", then as its value "6 notes, closed".
    override func accessibilityLabel() -> String? { AccessibilityText.groupLabel(name: name) }
    override func accessibilityValue() -> Any? { AccessibilityText.groupValue(count: count, isOpen: isOpen) }
    override func accessibilityHelp() -> String? { isOpen ? L("Closes the group") : L("Opens the group") }

    override func accessibilityPerformPress() -> Bool {
        onToggle?(ref)
        return true
    }

    /// The same as the press, named for what it does now.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: isOpen ? L("Close Group") : L("Open Group")) { [weak self] in
            guard let self else { return false }
            self.onToggle?(self.ref)
            return true
        }]
    }

    /// Everything VoiceOver reads for the tab, for the tests.
    var accessibilityTextForTesting: String { "\(accessibilityLabel() ?? ""), \(accessibilityValue() as? String ?? "")" }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { onToggle?(ref) }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: isOpen ? L("Close Group") : L("Open Group"), action: #selector(menuToggle), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuToggle() { onToggle?(ref) }

    // MARK: - Notes dropped on it

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, !droppedNotes(sender).isEmpty else { return [] }
        isDropTarget = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isDropTarget = false }
        let ids = droppedNotes(sender)
        guard acceptsDrops, !ids.isEmpty else { return false }
        onDropNotes?(ids)
        return true
    }

    private func droppedNotes(_ sender: NSDraggingInfo) -> [UUID] {
        sender.draggingPasteboard.string(forType: .string).map(NoteDragPayload.decode) ?? []
    }

    // MARK: - Drawing

    /// How far the face stands in from the inner side while there are sheets
    /// behind it.
    private static let sheetDepth: CGFloat = 3.5

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset = isOpen ? 0 : 2 * Self.sheetDepth
        let face = NSRect(x: inset, y: 0, width: bounds.width - inset, height: bounds.height)

        if !isOpen {
            // Two sheets behind, each peeking out a little further, shorter and
            // darker the deeper it is.
            for depth in [2, 1] {
                let offset = CGFloat(depth - 1) * Self.sheetDepth
                let sheet = NSRect(x: offset, y: CGFloat(3 - depth) * 3.5,
                                   width: bounds.width - offset, height: bounds.height - CGFloat(3 - depth) * 7)
                let path = NoteCardShape.path(in: mirrored(sheet), edge: edge)
                look.sheet(depth).setFill()
                path.fill()
                look.sheet(depth == 1 ? 2 : 2).withAlphaComponent(0.55).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            }
        }

        let body = NoteCardShape.path(in: mirrored(face), edge: edge)
        look.fill.setFill()
        body.fill()
        if DisplayOptions.increaseContrast {
            look.ink.withAlphaComponent(0.7).setStroke()
            body.lineWidth = 1
            body.stroke()
        } else {
            look.sheet(1).withAlphaComponent(0.5).setStroke()
            body.lineWidth = 0.75
            body.stroke()
        }

        // The count at the top, the name up the tab under it, the open mark at
        // the foot of a header. All of it in the ink of the colour.
        let textWidth = face.width - 12
        let countZone: CGFloat = 20
        // An open header has its mark at the foot: the name stops above it.
        let foot: CGFloat = isOpen ? 14 : 0
        if visibleSlice >= 20 {
            drawCount(in: NSRect(x: face.minX, y: bounds.maxY - 6 - 15, width: textWidth, height: 15))
        }
        NoteCardShape.drawTabLabel(
            name,
            in: mirrored(NSRect(x: face.minX, y: foot, width: textWidth, height: bounds.height - foot)),
            slice: visibleSlice,
            markerZone: countZone,
            color: look.ink,
            context: context
        )
        if isOpen { drawOpenMark(in: face, width: textWidth) }

        if isHovered {
            look.ink.withAlphaComponent(0.85).setStroke()
            body.lineWidth = 1.5
            body.stroke()
        }
        if isDropTarget {
            NSColor.controlAccentColor.setStroke()
            let ring = NoteCardShape.path(in: mirrored(face.insetBy(dx: 1.5, dy: 1.5)), edge: edge)
            ring.lineWidth = 3
            ring.stroke()
        }
        if showsKeyboardFocus {
            KeyboardFocusRing.draw(in: bounds, path: NoteCardShape.path(in: mirrored(face.insetBy(dx: 1.5, dy: 1.5)), edge: edge))
        }
    }

    /// The number of notes, centred over the face.
    private func drawCount(in rect: NSRect) {
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: look.ink,
        ])
        let size = text.size()
        let placed = mirrored(rect)
        text.draw(at: NSPoint(x: placed.midX - size.width / 2, y: placed.midY - size.height / 2))
    }

    /// A small chevron at the foot of an open group's header: the notes below
    /// belong to it.
    private func drawOpenMark(in face: NSRect, width: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [look.ink]))
        guard let glyph = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Open"))?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        let placed = mirrored(NSRect(x: face.minX + (width - size.width) / 2, y: 7, width: size.width, height: size.height))
        glyph.draw(in: placed)
    }
}
