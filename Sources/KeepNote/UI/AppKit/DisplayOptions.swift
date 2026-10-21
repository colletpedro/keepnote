import AppKit

/// System Settings > Accessibility > Display, as the app draws with it:
/// Increase contrast makes borders, the perforation and quiet text stronger;
/// Reduce transparency puts solid fills where the deck and the notices are
/// see-through. (Reduce motion is `Motion.reduceMotion`.) A change is
/// applied at once, to the deck and to open notes.
@MainActor
enum DisplayOptions {
    static var increaseContrastOverride: Bool?
    static var reduceTransparencyOverride: Bool?

    static var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var reduceTransparency: Bool {
        reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// The alpha of a see-through fill, or 1 when transparency is reduced.
    static func alpha(_ value: CGFloat) -> CGFloat { reduceTransparency ? 1 : value }

    /// Redraws everything when the settings change.
    static func observe() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .keepNoteWindowBehaviorChanged, object: nil)
        }
    }
}
