import Foundation

/// The status line in a note's header: "Saving…" while a write is under way,
/// otherwise when the note was last edited. Pure, so it can be tested.
enum SaveStatus {
    static func label(
        isSaving: Bool,
        editedAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isSaving { return "Saving\u{2026}" }
        return "Edited " + age(of: editedAt, now: now, calendar: calendar, locale: locale)
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago", then a
    /// short date. Clock skew (an edit "in the future") reads as "just now".
    static func age(of date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? hours / 24
        if days <= 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
