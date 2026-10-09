import Foundation

func runSaveStatusTests() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_US")
    let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

    func label(_ secondsAgo: TimeInterval, saving: Bool = false) -> String {
        SaveStatus.label(isSaving: saving, editedAt: now.addingTimeInterval(-secondsAgo), now: now,
                         calendar: calendar, locale: locale)
    }

    expect("saving wins over the age", label(300, saving: true), "Saving\u{2026}")
    expect("saving, even when just edited", label(0, saving: true), "Saving\u{2026}")
    expect("not saving never says Saving", label(0), "Edited just now")
    expect("under a minute", label(59), "Edited just now")
    expect("one minute", label(60), "Edited 1 min ago")
    expect("five minutes", label(5 * 60 + 10), "Edited 5 min ago")
    expect("59 minutes", label(59 * 60), "Edited 59 min ago")
    expect("one hour", label(3600), "Edited 1 h ago")
    expect("seven hours", label(7 * 3600), "Edited 7 h ago")
    expect("future edit reads as now", label(-30), "Edited just now")
    expectTrue("no Saved word anywhere", !label(300).contains("Saved") && !label(0).contains("Saved"))
    // 08:00 now: 26 h ago is yesterday at 06:00; 3 days is the 12th.
    expect("yesterday", label(26 * 3600), "Edited yesterday")
    expect("three days", label(3 * 86400), "Edited 3 days ago")
    expect("six days", label(6 * 86400), "Edited 6 days ago")
    expect("a week or more is a date", label(10 * 86400), "Edited Jan 5, 2027")
}
