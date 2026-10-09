import AppKit

/// The window the whole interaction lives in.
///
/// `.nonactivatingPanel` is the important part: the cursor can open the stack
/// and the user can click a note without KeepNote stealing focus from whatever
/// they were doing. Focus only moves when a note window opens for editing.
final class EdgePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: EdgeMetrics.pillWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyBehavior()
    }

    /// The panel never takes key or main: it is an affordance, not a document
    /// window. That is also what keeps it out of ⌘` cycling and out of Stage
    /// Manager's grouping, since an unmanaged floating panel is not a window
    /// Stage Manager considers part of an app's set.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyBehavior() {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,     // one stack, every desktop
            .stationary,           // does not slide around in Mission Control
            .ignoresCycle,         // stays out of ⌘`
        ]
        if AppSettings.shared.showOverFullScreen {
            // The setting the spec describes: reachable from a full-screen app.
            behavior.insert(.fullScreenAuxiliary)
            level = .popUpMenu
        } else {
            level = .floating
        }
        collectionBehavior = behavior
    }
}
