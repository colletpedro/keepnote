import Foundation

/// The text new daily notes start from. It is not a note: it has no tags, no
/// place on the deck and no row among the notes, so no list, search or tag
/// count ever sees it. The app keeps one, encrypted like a note body, and
/// carries it to the sync folder and the archive.
///
/// Empty by default — a new daily is then just as blank as any other note.
struct DailyTemplate: Equatable, Sendable {
    /// Markdown, as typed. May hold the variables `{date}` and `{weekday}`.
    var body: String
    /// When the text last changed, for last-writer-wins between Macs.
    /// `distantPast` while the template has never been set.
    var updatedAt: Date

    static let empty = DailyTemplate(body: "", updatedAt: .distantPast)

    /// Whether it was ever written — an emptied template counts, so that
    /// clearing it reaches the other Macs too.
    var isSet: Bool { updatedAt != .distantPast }

    /// Whether `incoming` should replace this one: strictly newer, which also
    /// makes a replayed file harmless.
    func accepts(_ incoming: DailyTemplate) -> Bool {
        incoming.updatedAt > updatedAt
    }
}

// MARK: - Applying it to a new daily

extension DailyTemplate {
    /// The variables a template may hold.
    static let dateVariable = "{date}"
    static let weekdayVariable = "{weekday}"

    /// A new daily's body, and where the caret goes in it.
    struct Applied: Equatable {
        var text: String
        /// UTF-16 offset into `text`, which is what a text view's selection uses.
        var caret: Int
    }

    /// The template made into the body of a daily born on `date`: the variables
    /// replaced, and the caret placed. Pure — the clock, the locale and the
    /// calendar are arguments, so the same inputs always give the same body.
    static func apply(
        _ template: String, on date: Date, locale: Locale = .current, calendar: Calendar = .current
    ) -> Applied {
        let text = substituting(template, on: date, locale: locale, calendar: calendar)
        return Applied(text: text, caret: caret(in: text))
    }

    /// `{date}` (the short date in the system's format and order) and
    /// `{weekday}` (the day's name in full, in the system's language), each
    /// replaced wherever it appears. Anything else in braces is left as typed.
    /// A single pass over the template, so what a variable becomes is never
    /// read as a variable itself.
    static func substituting(
        _ template: String, on date: Date, locale: Locale = .current, calendar: Calendar = .current
    ) -> String {
        guard template.contains("{") else { return template }
        let values = [
            dateVariable: formatted(date, locale: locale, calendar: calendar) { $0.dateStyle = .short; $0.timeStyle = .none },
            weekdayVariable: formatted(date, locale: locale, calendar: calendar) { $0.setLocalizedDateFormatFromTemplate("EEEE") },
        ]
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let tail = rest[open...]
            if let variable = values.keys.first(where: { tail.hasPrefix($0) }), let value = values[variable] {
                result += value
                rest = tail.dropFirst(variable.count)
            } else {
                result += "{"
                rest = tail.dropFirst()
            }
        }
        return result + rest
    }

    private static func formatted(
        _ date: Date, locale: Locale, calendar: Calendar, _ configure: (DateFormatter) -> Void
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        configure(formatter)
        return formatter.string(from: date)
    }

    /// Where the caret starts in a new daily: at the end of the first empty
    /// list or checklist item (a marker with nothing after it, as the editor
    /// itself reads one — and not inside a code block), so typing fills it in;
    /// without one, at the end of the text.
    static func caret(in text: String) -> Int {
        let ns = text as NSString
        let ranges = TextLines.ranges(in: ns)
        let lines = ranges.map { ns.substring(with: $0) }
        let fenced = TextLines.fenced(lines)
        for (index, line) in lines.enumerated() where !fenced[index] {
            if let item = ListEditing.item(in: line), item.prefixLength == (line as NSString).length {
                return ranges[index].location + item.prefixLength
            }
        }
        return ns.length
    }
}
