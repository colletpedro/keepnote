import AppKit

/// Tells VoiceOver about a change that happened away from where its cursor
/// is: a note made, archived, deleted, pinned, back on the deck, tasks
/// brought, notes archived by the time rule. Nothing is said without VoiceOver.
@MainActor
enum Announcer {
    /// What was last said, for the tests.
    private(set) static var last: String?

    static func say(_ text: String) {
        last = text
        NSAccessibility.post(
            element: NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    static var isVoiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }
}
