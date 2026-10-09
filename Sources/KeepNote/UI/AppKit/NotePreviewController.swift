import AppKit
import SwiftUI

/// The middle state: hovering a tab slides the note out far enough to read,
/// without opening anything.
///
/// The window never takes key. It is a peek, not a document — the caret only
/// appears once the user actually clicks, and until then whatever they were
/// typing in another app keeps the focus.
final class NotePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Content view of the preview. Owns the tracking area, so moving the cursor
/// from the tab onto the preview keeps both alive instead of reading as
/// "the cursor left the deck".
final class NotePreviewContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

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

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
final class NotePreviewController {
    /// Whether the cursor is on the preview itself.
    private(set) var isHovered = false
    private(set) var visibleNoteID: UUID?
    private var motion: WindowMotion!

    var onHoverChanged: ((Bool) -> Void)?
    var onClick: ((UUID) -> Void)?

    private let panel: NotePreviewPanel
    private let container: NSView
    private var hosting: NSHostingView<NotePreviewView>?

    init() {
        panel = NotePreviewPanel(
            contentRect: NSRect(origin: .zero, size: EdgeMetrics.previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        // The paper is always light, so everything drawn on it resolves in
        // Aqua: placeholder and semantic colours must not go pale in Dark Mode.
        panel.appearance = NSAppearance(named: .aqua)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating

        let content = NotePreviewContentView(frame: NSRect(origin: .zero, size: EdgeMetrics.previewSize))
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        content.layer?.cornerRadius = EdgeMetrics.cardCornerRadius
        // Square against the screen edge, like every other card here.
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        container = content
        panel.contentView = content
        motion = WindowMotion(window: panel)

        content.onHoverChanged = { [weak self] entered in
            guard let self else { return }
            self.isHovered = entered
            self.onHoverChanged?(entered)
        }
        content.onClick = { [weak self] in
            guard let self, let id = self.visibleNoteID else { return }
            self.onClick?(id)
        }
    }

    var frameForTesting: NSRect { panel.frame }

    func applyBehavior() {
        if AppSettings.shared.showOverFullScreen {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.level = .popUpMenu
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.level = .floating
        }
    }

    /// Slides out from under the deck, vertically centred on the tab it belongs
    /// to — the same motion the editor makes, just shorter.
    func show(note: Note, tabFrame: NSRect, deckWidth: CGFloat, on screen: NSScreen?) {
        // Visible includes a peek that is still fading out: it is picked up
        // where it is rather than restarted.
        let isOnScreen = panel.isVisible
        visibleNoteID = note.id
        applyBehavior()

        let view = NotePreviewView(note: note)
        if let hosting {
            hosting.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = container.bounds
            hostingView.autoresizingMask = [.width, .height]
            container.addSubview(hostingView)
            hosting = hostingView
        }

        let target = frame(for: tabFrame, deckWidth: deckWidth, screen: screen)
        // Already up (or on its way out), same note or another: spring to the
        // new place from wherever it is. This is what lets the peek be instant
        // without a sweep down the deck turning into a strobe, and what makes
        // coming back to a peek that is closing smooth.
        if isOnScreen {
            panel.ignoresMouseEvents = false
            motion.move(to: target, alpha: 1, config: .peek) { [weak panel] in
                panel?.invalidateShadow()
            }
            return
        }

        motion.place(frame: Self.start(for: target), alpha: 0)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        motion.move(to: target, alpha: 1, config: .peek) { [weak panel] in
            panel?.invalidateShadow()
        }
    }

    /// Where a peek begins and ends: just the tab's width, tucked under the deck.
    private static func start(for target: NSRect) -> NSRect {
        NSRect(
            x: target.maxX - EdgeMetrics.tabWidth,
            y: target.origin.y,
            width: EdgeMetrics.tabWidth,
            height: target.height
        )
    }

    private func frame(for tabFrame: NSRect, deckWidth: CGFloat, screen: NSScreen?) -> NSRect {
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = EdgeMetrics.previewSize
        let centerY = tabFrame.isEmpty ? area.midY : tabFrame.midY
        let y = min(
            max(area.minY + 8, centerY - size.height / 2),
            area.maxY - size.height - 8
        )
        // The right end stays tucked under the deck, so the preview reads as
        // the same card pulled part of the way out.
        let tuck = min(deckWidth, EdgeMetrics.previewTuck)
        return NSRect(
            x: area.maxX - size.width - max(0, deckWidth - tuck),
            y: y,
            width: size.width,
            height: size.height
        )
    }

    func hide(animated: Bool = true) {
        guard visibleNoteID != nil else { return }
        visibleNoteID = nil
        isHovered = false
        guard animated else {
            motion.stop()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        // Folds back under the deck while fading; showing again before it has
        // finished takes over from here.
        panel.ignoresMouseEvents = true
        motion.move(to: Self.start(for: panel.frame), alpha: 0, config: .peek) { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }
}
