import Foundation

/// The kinds of window KeepNote puts on screen.
enum AppWindowKind: Hashable, CaseIterable, Sendable {
    // Standard windows: titled, in the window list, worth a Dock icon.
    case allNotes, archive, settings, about, welcome, dailyTemplate
    // Part of the edge, not windows the user manages.
    case deck, peek, anchoredNote, detachedNote

    var isStandard: Bool {
        switch self {
        case .allNotes, .archive, .settings, .about, .welcome, .dailyTemplate: return true
        case .deck, .peek, .anchoredNote, .detachedNote: return false
        }
    }
}

/// Whether KeepNote is in the Dock. It is while a standard window is open —
/// with the full menu bar — and out of it otherwise, when the deck, the notes
/// and the menu bar icon are the whole app.
enum DockPolicy: Equatable, Sendable {
    case regular
    case accessory

    static func policy(for open: Set<AppWindowKind>) -> DockPolicy {
        open.contains(where: \.isStandard) ? .regular : .accessory
    }

    /// The policy to switch to, or `nil` when `current` is already right.
    static func change(from current: DockPolicy, open: Set<AppWindowKind>) -> DockPolicy? {
        let wanted = policy(for: open)
        return wanted == current ? nil : wanted
    }
}
