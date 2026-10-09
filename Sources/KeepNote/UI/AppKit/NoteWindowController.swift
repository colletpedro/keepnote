import AppKit
import SwiftUI

/// The window an open note lives in.
///
/// Borderless on purpose: a system title bar would put macOS chrome on top of a
/// card whose whole point is that it is a piece of paper from the deck. Unlike
/// the edge panel this window *does* take key — the user is about to type.
final class NoteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Clips the hosted SwiftUI to the card's shape. Anchored against the screen
/// edge only the left corners are round; lifted off, all four are.
final class NoteCardContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 14
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(presentation: NotePresentation) {
        layer?.maskedCorners = presentation == .anchored
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }
}

@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    let noteID: UUID

    private let store: NoteStore
    private let model: NoteEditorModel
    let window: NoteWindow
    private let container: NoteCardContainerView
    private let hosting: NSHostingView<NoteEditorView>
    private var keyMonitor: Any?
    /// Spring motion of the window's frame and opacity.
    private var motion: WindowMotion!
    /// A closing note outlives the coordinator's reference to it for the length
    /// of its fold-back; this keeps the window alive until it has finished.
    private var keepAlive: NoteWindowController?
    private var saveFrameTask: DispatchWorkItem?

    private(set) var presentation: NotePresentation = .anchored
    /// When the window was last put on screen. Losing key focus in the first
    /// moments is the app settling, not the user clicking away.
    private var shownAt = Date.distantPast
    private var isClosing = false
    var isClosingForChecks: Bool { isClosing }
    /// The tab this note came out of, so it can fold back into it.
    private let originFrame: NSRect?

    var onClose: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    /// Pin to Center on or off, from the header's pin or the Tools menu.
    var onSetPinned: ((UUID, Bool) -> Void)?
    /// Floated or returned to the deck — by the button, ⌥⌘P or a drag.
    var onPresentationChange: ((UUID, NotePresentation) -> Void)?
    /// Opens another note, from the `daily` chip's menu.
    var onOpenNote: ((UUID) -> Void)?
    /// "Show All Dailies" in that menu.
    var onShowAllDailies: (() -> Void)?

    /// `floating` opens the note off the deck from the start, where it was
    /// last left: how floating notes come back at launch.
    init(note: Note, store: NoteStore, originFrame: NSRect?, cascadeIndex: Int, floating: Bool = false) {
        self.noteID = note.id
        self.store = store
        self.originFrame = originFrame
        self.model = NoteEditorModel(note: note, store: store)

        window = NoteWindow(
            contentRect: NSRect(origin: .zero, size: EdgeMetrics.anchoredSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        container = NoteCardContainerView(frame: NSRect(origin: .zero, size: EdgeMetrics.anchoredSize))
        hosting = NSHostingView(rootView: NoteEditorView(
            model: model,
            presentation: .anchored,
            onClose: {},
            onDelete: {},
            onTogglePin: {}
        ))
        super.init()

        hosting.rootView = makeRootView()
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        container.apply(presentation: .anchored)

        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Moving goes through `drag`, never AppKit's background drag, so the
        // float and snap rules always apply.
        window.isMovableByWindowBackground = false
        // The paper is always light, so everything drawn on it resolves in
        // Aqua: placeholder and semantic colours must not go pale in Dark Mode.
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.minSize = EdgeMetrics.minimumNoteSize
        motion = WindowMotion(window: window)
        if floating {
            presentation = .detached
            container.apply(presentation: .detached)
            hosting.rootView = makeRootView()
        }
        applyBehavior()

        let target = floating ? detachedFrame() : anchoredFrame(cascadeIndex: cascadeIndex)
        if let originFrame, !floating {
            // "Slides clear of the deck": the note starts life as its own tab
            // and grows left out from under the stack.
            motion.place(frame: originFrame, alpha: 0)
            window.orderFrontRegardless()
            motion.move(to: target, alpha: 1, config: .note) { [weak self] in
                self?.window.invalidateShadow()
            }
        } else {
            window.setFrame(target, display: false)
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func makeRootView() -> NoteEditorView {
        NoteEditorView(
            model: model,
            presentation: presentation,
            onClose: { [weak self] in self?.close() },
            onDelete: { [weak self] in self?.requestDelete() },
            onTogglePin: { [weak self] in self?.togglePresentation() },
            onToggleCenterPin: { [weak self] in self?.toggleCenterPin() },
            onShowTools: { [weak self] in self?.showTools() },
            onDailyChip: { [weak self] in self?.showDailyMenu() },
            onDrag: { [weak self] phase in self?.drag(phase) }
        )
    }

    // MARK: - Tools menu

    /// While a menu is up the window may report losing key; that is the menu,
    /// not the user clicking away, so an anchored note must not close for it.
    /// The report can also arrive just after the menu is gone, hence the grace.
    private var menuDepth = 0
    private var menuClosedAt = Date.distantPast

    /// The Tools button: a native menu at the pointer whose items act on the
    /// note body directly (their target is the text view, not whatever has
    /// focus), so choosing one works whether or not the body was focused, and
    /// on the selection the body already had.
    private func showTools() {
        guard let textView = Self.findTextView(in: container) else { return }
        let menu = FormatCommand.makeToolsMenu(target: textView)
        menu.addItem(.separator())
        let pin = NSMenuItem(title: "Pin to Center", action: #selector(toggleCenterPin), keyEquivalent: "")
        pin.target = self
        pin.state = store.note(id: noteID)?.isPinned == true ? .on : .off
        menu.addItem(pin)
        let keep = NSMenuItem(title: "Keep on Deck", action: #selector(toggleKeepOnDeck), keyEquivalent: "")
        keep.target = self
        keep.state = store.note(id: noteID)?.keepOnDeck == true ? .on : .off
        menu.addItem(keep)
        let point = hosting.convert(window.mouseLocationOutsideOfEventStream, from: nil)

        menuDepth += 1
        menu.popUp(positioning: nil, at: point, in: hosting)
        menuDepth -= 1
        menuClosedAt = Date()
        if clickedAwayWhileMenuWasUp() { return }

        // Whatever was chosen, the caret goes back to the body, where the
        // action left its selection (or where it was, if nothing was chosen).
        let kept = textView.selectedRange()
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(kept)
    }

    @objc private func toggleCenterPin() {
        onSetPinned?(noteID, !(store.note(id: noteID)?.isPinned ?? false))
    }

    @objc private func toggleKeepOnDeck() {
        model.setKeepOnDeck(!model.keepOnDeck)
    }

    /// A click outside both the menu and the note dismisses the menu and lands
    /// elsewhere — another app, or another window of this one. The window's
    /// loss of key was ignored while the menu was up, so it is acted on now:
    /// an anchored note closes, as it would have without the menu.
    private func clickedAwayWhileMenuWasUp() -> Bool {
        guard presentation == .anchored, !isClosing else { return false }
        let elsewhere = !NSApp.isActive || (NSApp.keyWindow != nil && NSApp.keyWindow !== window)
        guard elsewhere else { return false }
        close()
        return true
    }

    // MARK: - The daily chip's menu

    /// The ten dailies before this note's day, by day, and Show All Dailies.
    /// Choosing one opens that note where it is — an archived daily stays in
    /// the archive.
    private func showDailyMenu() {
        let day = store.note(id: noteID)?.dailyDay ?? store.today
        let menu = NSMenu()
        let groups = DailyNotes.previous(before: day, in: store.notes, excluding: noteID)
        if groups.isEmpty {
            let none = NSMenuItem(title: "No earlier dailies", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for group in groups {
            let header = NSMenuItem(title: Self.dayFormatter.string(from: group.day.date() ?? Date()), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for note in group.items {
                let item = NSMenuItem(title: note.displayTitle, action: #selector(openDailyFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = note.id
                item.indentationLevel = 1
                if note.state == .archived { item.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archived") }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Show All Dailies", action: #selector(showAllDailiesFromMenu), keyEquivalent: "")
        all.target = self
        menu.addItem(all)

        let point = hosting.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        chosenFromDailyMenu = false
        menuDepth += 1
        menu.popUp(positioning: nil, at: point, in: hosting)
        menuDepth -= 1
        menuClosedAt = Date()
        if !chosenFromDailyMenu, clickedAwayWhileMenuWasUp() { return }
        if !chosenFromDailyMenu, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    }

    private var chosenFromDailyMenu = false

    @objc private func openDailyFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        chosenFromDailyMenu = true
        onOpenNote?(id)
    }

    @objc private func showAllDailiesFromMenu() {
        chosenFromDailyMenu = true
        onShowAllDailies?()
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // MARK: - Geometry

    private var screen: NSScreen? {
        if let originFrame, let match = NSScreen.screens.first(where: { $0.frame.intersects(originFrame) }) {
            return match
        }
        // No tab to come out of (the shortcut, a button, a list): the screen
        // the cursor is on, which is the one the user is looking at — not the
        // one the app's other windows, All Notes say, happen to be on.
        // Once it is on screen it stays where it is.
        if window.isVisible, let current = window.screen { return current }
        return Self.screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
            ?? window.screen ?? NSScreen.main
    }

    /// The screen whose frame holds `point` (Cocoa screen coordinates).
    static func screen(containing point: NSPoint, in screens: [NSScreen]) -> NSScreen? {
        screens.first { $0.frame.contains(point) }
    }

    /// Flush against the right edge, vertically centred on the tab it came
    /// from — "open one where it sits". Its right end runs under the deck,
    /// which is what makes the note look like it slid out of the stack.
    private func anchoredFrame(cascadeIndex: Int) -> NSRect {
        let area = screen?.visibleFrame ?? .zero
        let size = EdgeMetrics.anchoredSize
        let centerY = originFrame?.midY ?? area.midY
        let y = min(
            max(area.minY + 8, centerY - size.height / 2),
            area.maxY - size.height - 8
        )
        return NSRect(
            x: area.maxX - size.width + CGFloat(cascadeIndex % 3) * 0,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    /// Where a lifted-off note goes: where this note was last left, fitted to
    /// the screens as they are now, or the middle of the screen the first time.
    private func detachedFrame() -> NSRect {
        if let saved = AppSettings.shared.detachedFrame(for: noteID) {
            return FrameRestore.fit(
                saved,
                screens: NSScreen.screens.map(\.visibleFrame),
                minimum: EdgeMetrics.minimumNoteSize
            )
        }
        let area = screen?.visibleFrame ?? .zero
        let size = EdgeMetrics.detachedSize
        return NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Presentation

    /// Float Note / Return to Deck (the spine button, ⌥⌘P). Anchored, the note
    /// belongs to the deck; floating, it is a card on the desk that stays put
    /// and carries its own controls.
    func togglePresentation() {
        setPresentation(presentation == .anchored ? .detached : .anchored)
        let target = presentation == .detached ? detachedFrame() : anchoredFrame(cascadeIndex: 0)
        // Aimed from wherever the window is, so floating or returning in the
        // middle of the move (or of the opening) bends it instead of jumping.
        motion.move(to: target, alpha: 1, config: .pin) { [weak self] in
            self?.window.invalidateShadow()
        }
    }

    /// The card's look and the window's behaviour for `presentation`; where
    /// the window goes is up to the caller.
    private func setPresentation(_ new: NotePresentation) {
        guard new != presentation else { return }
        presentation = new
        onPresentationChange?(noteID, new)
        container.apply(presentation: presentation)
        hosting.rootView = makeRootView()
        applyBehavior()
        // Rebuilding the root view drops the first responder.
        focusBody()
    }

    // MARK: - Dragging

    private struct Drag {
        var startMouse: NSPoint
        var startFrame: NSRect
        /// Floating for this drag: from the start, or since it went past the
        /// float distance.
        var floating: Bool
    }

    private var currentDrag: Drag?
    private lazy var snapIndicator = SnapIndicator()
    /// Off in the off-screen checks, so nothing is drawn on the real screen.
    var showsSnapIndicator = true
    /// Whether the bar is up right now.
    private(set) var isShowingSnap = false

    /// A drag on the spine or header. Anchored, the note stays put until the
    /// cursor has gone `FloatDrag.floatDistance` away from the edge, then
    /// floats and follows it. Floating, it follows the cursor, and near the
    /// right edge a bar shows it will go back into the deck when let go.
    func drag(_ phase: NoteDragPhase, at mouse: NSPoint = NSEvent.mouseLocation) {
        switch phase {
        case .changed:
            if currentDrag == nil {
                motion.stop()
                currentDrag = Drag(startMouse: mouse, startFrame: window.frame, floating: presentation == .detached)
            }
            guard var drag = currentDrag else { return }
            if !drag.floating {
                guard FloatDrag.shouldFloat(start: drag.startMouse, current: mouse) else { return }
                let size = AppSettings.shared.detachedFrame(for: noteID)?.size ?? EdgeMetrics.detachedSize
                drag.startFrame = FloatDrag.floated(from: window.frame, size: size, cursor: mouse)
                drag.startMouse = mouse
                drag.floating = true
                currentDrag = drag
                setPresentation(.detached)
            }
            let frame = FloatDrag.followed(drag.startFrame, from: drag.startMouse, to: mouse)
            motion.place(frame: frame, alpha: 1)
            if let edge = screen(containing: mouse), FloatDrag.isInSnapZone(noteFrame: frame, screenMaxX: edge.maxX) {
                isShowingSnap = true
                if showsSnapIndicator {
                    snapIndicator.show(at: edge, height: frame.height, centerY: frame.midY, level: window.level)
                }
            } else {
                isShowingSnap = false
                snapIndicator.hide()
            }
        case .ended:
            guard let drag = currentDrag else { return }
            currentDrag = nil
            isShowingSnap = false
            snapIndicator.hide()
            guard drag.floating else { return }
            if let edge = screen(containing: mouse),
               FloatDrag.isInSnapZone(noteFrame: window.frame, screenMaxX: edge.maxX) {
                togglePresentation()   // Return to Deck
            } else {
                window.invalidateShadow()
                saveDetachedFrameNow()
            }
        }
    }

    private func screen(containing point: NSPoint) -> NSRect? {
        (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? window.screen)?.visibleFrame
    }

    /// A borderless window over a clear background keeps a cached shadow
    /// silhouette. Animating the frame leaves that cache describing the old
    /// shape, which is what shows up as a shadow that looks clipped or
    /// crescent-shaped around the card.
    func windowDidResize(_ notification: Notification) {
        window.invalidateShadow()
        rememberDetachedFrame()
    }

    func windowDidMove(_ notification: Notification) {
        rememberDetachedFrame()
    }

    /// The user moved or resized a lifted-off note: remember it, once they have
    /// let go. Not while a spring is moving it — that is the app, not them.
    private func rememberDetachedFrame() {
        guard presentation == .detached, !isClosing, !motion.isAnimating else { return }
        saveFrameTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveDetachedFrameNow() }
        saveFrameTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func saveDetachedFrameNow() {
        saveFrameTask?.cancel()
        saveFrameTask = nil
        guard presentation == .detached, !motion.isAnimating else { return }
        AppSettings.shared.setDetachedFrame(window.frame, for: noteID)
    }

    /// An anchored note belongs to the desktop or full-screen app it was
    /// opened over, and is closed when that changes — it must never be left
    /// stranded behind in a Space the user has walked away from. A pinned note
    /// is the opposite promise: it joins every Space and travels with them.
    ///
    /// Only a floating note can be resized: anchored, its size is the deck's.
    func applyBehavior() {
        if presentation == .detached {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.styleMask.insert(.resizable)
        } else {
            window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            window.styleMask.remove(.resizable)
        }
        window.level = AppSettings.shared.showOverFullScreen ? .popUpMenu : .floating
    }

    /// On screen without taking focus: a floating note restored at launch
    /// must not pull the user out of what they were doing.
    func showInBackground() {
        window.orderFrontRegardless()
        installKeyMonitorIfNeeded()
    }

    func show() {
        // On screen first, so it is already in the Space the user is looking
        // at — a full-screen app's, say — when the app is activated. Activating
        // first would take the user to the Space of the app's other window
        // (All Notes, on the desktop) and the note would open over there.
        // And key before then too: the app goes to the Space of its key
        // window, and while that is All Notes, it is the wrong one.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        // The app is an accessory (no Dock icon), so it has to ask for focus
        // explicitly before the caret will blink.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        shownAt = Date()
        installKeyMonitorIfNeeded()
        focusOnOpen()
    }

    func close() {
        guard !isClosing else { return }
        // A pending save would find a closing window; write it now.
        if saveFrameTask != nil { saveDetachedFrameNow() }
        isClosing = true
        model.flush()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        // Fold back toward the tab it came from, rather than blinking out.
        if let originFrame, presentation == .anchored {
            // Invisible and unclickable the moment it starts folding away, even
            // though the spring takes a beat to settle.
            window.ignoresMouseEvents = true
            keepAlive = self
            motion.move(to: originFrame, alpha: 0, config: .note) { [weak self] in
                guard let self else { return }
                self.window.orderOut(nil)
                self.window.alphaValue = 1
                self.keepAlive = nil
            }
        } else {
            motion.stop()
            window.orderOut(nil)
        }
        onClose?(noteID)
    }

    func refresh() {
        model.refreshFromStore()
    }

    /// Where the caret goes when a note opens: the title field when there is
    /// nothing written yet (title and body both empty), the end of the body in
    /// every other case.
    ///
    /// Left alone, the first focusable view wins — and that is the title field,
    /// with its text selected, so the first keystroke after opening a note
    /// would replace the title instead of adding to the note. Typing straight
    /// after opening should append to what is written, which is what the body's
    /// caret-at-end does.
    private func focusOnOpen() {
        let startsBlank = model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if startsBlank && !model.isLocked {
            focusTitle()
        } else {
            focusBody()
        }
    }

    /// Same deferral and same re-check as `focusBody`, aimed at the title.
    private func focusTitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = Self.findTitleField(in: self.container) else { return }
            self.window.makeFirstResponder(field)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, !self.isTitleEditing else { return }
                self.window.makeFirstResponder(field)
            }
        }
    }

    /// Puts the caret at the end of the body, not in the title, with nothing
    /// selected.
    ///
    /// Deferred by one turn of the run loop: SwiftUI has not built the hosted
    /// hierarchy yet at the moment the window is ordered in, so there is no
    /// text view to focus.
    private func focusBody() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = Self.findTextView(in: self.container) else { return }
            self.placeCaretAtEnd(of: textView)

            // SwiftUI can assign its own initial focus to the title field after
            // this, so the claim is checked once more and taken back if lost.
            // Identity, not type: a focused SwiftUI TextField is itself backed
            // by an NSTextView field editor, so `is NSTextView` would pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.window.firstResponder !== textView else { return }
                self.placeCaretAtEnd(of: textView)
            }
        }
    }

    private func placeCaretAtEnd(of textView: NSTextView) {
        window.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    /// Finds the note body specifically.
    ///
    /// Matching on `NSTextView` alone is wrong: when the title field has focus,
    /// the window's field editor — also an `NSTextView` — is installed in the
    /// header, ahead of the body in the subview order. Focusing that one puts
    /// the caret at the end of the *title*, so typing renames the note instead
    /// of adding to it.
    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView,
           textView.identifier == NoteTextView.bodyIdentifier,
           !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    /// The title is a SwiftUI `TextField`, which AppKit sees as an
    /// `NSTextField` carrying the field's prompt as its placeholder.
    private static let titlePlaceholder = "Title"

    private static func findTitleField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == titlePlaceholder {
            return field
        }
        for subview in view.subviews {
            if let found = findTitleField(in: subview) { return found }
        }
        return nil
    }

    /// True while the title field is being edited — its field editor is the
    /// first responder and reports the field as its delegate.
    private var isTitleEditing: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField
        else { return false }
        return field.placeholderString == Self.titlePlaceholder
    }

    func flush() {
        model.flush()
    }

    private func requestDelete() {
        model.flush()
        onDelete?(noteID)
        close()
    }

    // MARK: - In-note shortcuts

    /// A *local* monitor: it only ever sees events already routed to this app,
    /// so it needs no Accessibility or Input Monitoring permission. The global
    /// shortcuts go through Carbon instead — see `HotkeyService`.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        // Esc closes. NSTextView would otherwise swallow it for autocomplete.
        // With the tag suggestions open, Esc closes only those.
        if event.keyCode == 53, flags.isEmpty {
            if model.isTagListVisible {
                model.dismissTagList()
            } else {
                close()
            }
            return true
        }

        // Return or Tab in the title moves on to the body. Not while an input
        // method is composing: there Return confirms the candidate.
        if flags.isEmpty, [36, 76, 48].contains(event.keyCode), isTitleEditing,
           let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText() {
            focusBody()
            return true
        }

        guard command else { return false }

        // ⇧⌘⌫ arrives as a key code rather than a character. Plain ⌘⌫ is left
        // alone so the text field gets its "delete to start of line".
        if event.keyCode == 51 {
            guard shift, !option else { return false }
            requestDelete()
            return true
        }

        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "f" where !option:
            model.toggleFindBar()
            return true
        case "g":
            model.advanceFind(by: shift ? -1 : 1)
            return true
        case "c" where option:
            model.cycleColor(backwards: shift)
            return true
        case "e" where shift:
            model.toggleComplete()
            return true
        case "p" where option:
            togglePresentation()
            return true
        case "w":
            close()
            return true
        default:
            return false
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.flush()
        onClose?(noteID)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.windowBecameKey()
    }

    /// Clicking anywhere else puts the note away.
    ///
    /// An anchored note is a glance at the deck, not a document: it should not
    /// need dismissing. A pinned note is the opposite promise and stays.
    ///
    /// The deck itself is a non-activating panel that never takes key, so
    /// scrolling it or hovering it does not count as clicking away — only real
    /// focus changes reach here.
    func windowDidResignKey(_ notification: Notification) {
        // Never leave typed text sitting in a timer when focus moves away.
        model.flush()
        model.windowResignedKey()
        guard presentation == .anchored, !isClosing, menuDepth == 0,
              Date().timeIntervalSince(menuClosedAt) > 0.3 else { return }
        guard Date().timeIntervalSince(shownAt) > 0.4 else { return }
        close()
    }
}

/// The bar at the right edge that says "let go and this note goes back into
/// the deck": the note's height, in the accent colour, flush to the edge.
@MainActor
final class SnapIndicator {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        bar.layer?.cornerRadius = 3
        panel.contentView = bar
        return panel
    }()

    static let width: CGFloat = 6

    func show(at area: NSRect, height: CGFloat, centerY: CGFloat, level: NSWindow.Level) {
        let height = min(height, area.height)
        let y = min(max(area.minY, centerY - height / 2), area.maxY - height)
        panel.setFrame(NSRect(x: area.maxX - Self.width - 2, y: y, width: Self.width, height: height), display: true)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}
