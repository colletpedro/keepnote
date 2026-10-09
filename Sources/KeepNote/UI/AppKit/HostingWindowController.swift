import AppKit
import SwiftUI

/// Hosts a SwiftUI view in an ordinary window.
///
/// The auxiliary windows (All Notes, Archive, Settings) are plain AppKit
/// windows with a `NSHostingView` inside: SwiftUI gets to describe the list and
/// the reading pane, while window level, restoration and closing behaviour stay
/// where the rest of the app keeps them.
@MainActor
final class HostingWindowController<Content: View>: NSObject, NSWindowDelegate {
    let window: NSWindow

    var onClose: (() -> Void)?

    init(
        title: String,
        size: NSSize,
        autosaveName: String,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        minSize: NSSize = NSSize(width: 520, height: 360),
        rootView: Content
    ) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.contentView = NSHostingView(rootView: rootView)
        _ = window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        if window.frame.origin == .zero {
            window.center()
        }
    }

    /// Activates the app and brings the window to the front, out of the Dock
    /// if it was minimised. An open window is only brought forward.
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    var isVisible: Bool { window.isVisible }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
