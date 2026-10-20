import Foundation

/// Settings > Daily > "Unfinished tasks from your last daily": what a new
/// daily does with the checklist items left unticked on the last day before.
enum CarryOverMode: String, CaseIterable, Sendable {
    case never
    case ask
    case automatic

    static let `default` = CarryOverMode.ask

    var title: String {
        switch self {
        case .never: return L("Don\u{2019}t bring")
        case .ask: return L("Ask each time")
        case .automatic: return L("Bring automatically")
        }
    }
}

/// The unticked checklist items a new daily is offered from the last day
/// before it that has a daily. Pure: the notes, their days and the new
/// daily's own text are all arguments, so every rule here is tested directly.
enum DailyCarryOver {
    /// A daily the tasks may come from.
    struct Source: Equatable {
        var day: DailyDay
        /// Earlier dailies of the day give their tasks first.
        var createdAt: Date
        var body: String
    }

    /// What the new daily is offered: the items, as checklist lines with
    /// their subitems' indentation, and the day they came from.
    struct Offer: Equatable {
        var day: DailyDay
        var lines: [String]
        var count: Int { lines.count }
    }

    /// The offer for a new daily on `today`, or `nil` when there is nothing
    /// to bring or it is not the day's first daily.
    ///
    /// - `sources`: every daily (archived ones too), whatever its day.
    /// - `newBody`: the new daily's text, from the template; an item it
    ///   already has is not brought again.
    /// - `othersToday`: how many other dailies today already has. Only the
    ///   first daily of a day is offered anything.
    static func offer(for today: DailyDay, sources: [Source], newBody: String, othersToday: Int) -> Offer? {
        guard othersToday == 0,
              let day = sources.map(\.day).filter({ $0 < today }).max() else { return nil }
        var seen = Set(items(in: newBody, uncheckedOnly: false).map { key($0.text) })
        var lines: [String] = []
        for source in sources.filter({ $0.day == day }).sorted(by: { $0.createdAt < $1.createdAt }) {
            // Each item's depth counts only the items brought above it, so a
            // subitem under a ticked (or repeated) parent moves up with it.
            var kept: [Int] = []   // levels of the items brought so far, as a stack
            for item in items(in: source.body, uncheckedOnly: false) {
                while let last = kept.last, last >= item.level { kept.removeLast() }
                guard !item.isChecked, let text = item.uncheckedText else { continue }
                let folded = key(text)
                guard !folded.isEmpty, !seen.contains(folded) else { continue }
                seen.insert(folded)
                lines.append(String(repeating: ListEditing.indentUnit, count: kept.count) + "- [ ] " + text)
                kept.append(item.level)
            }
        }
        return lines.isEmpty ? nil : Offer(day: day, lines: lines)
    }

    /// One list item of a body, outside code blocks.
    struct Line {
        var level: Int
        var isChecklist: Bool
        var isChecked: Bool
        var text: String
        /// The text of an unticked checklist item, trimmed.
        var uncheckedText: String? { isChecklist && !isChecked ? text : nil }
    }

    /// The list items in `body`, in order, with their depth (a tab, or four
    /// spaces, a level). Plain text, and anything inside a fenced code block,
    /// is not an item.
    static func items(in body: String, uncheckedOnly: Bool) -> [Line] {
        let lines = body.components(separatedBy: "\n")
        let fenced = TextLines.fenced(lines)
        var result: [Line] = []
        for (index, line) in lines.enumerated() where !fenced[index] {
            guard let item = ListEditing.item(in: line) else { continue }
            let text = String((line as NSString).substring(from: item.prefixLength))
                .trimmingCharacters(in: .whitespaces)
            let isChecklist = item.box != nil
            let isChecked = item.box.map { $0.lowercased().contains("x") } ?? false
            guard !uncheckedOnly || (isChecklist && !isChecked) else { continue }
            result.append(Line(level: level(of: item.leading), isChecklist: isChecklist, isChecked: isChecked, text: text))
        }
        return result
    }

    private static func level(of leading: String) -> Int {
        let width = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return width / 4
    }

    /// How two items are told apart: not by case, accents or extra spaces.
    static func key(_ text: String) -> String {
        TagText.fold(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension DailyCarryOver {
    /// "From Thursday, 16/10": the day the tasks came from, as the heading
    /// above them. The day and month in the locale's order.
    /// `language` asks for another interface language than the running one
    /// (the tests read both).
    static func heading(for day: DailyDay, locale: Locale = Localization.locale, calendar: Calendar = .current,
                        language: String? = nil) -> String {
        let format = language.map { L("From %@", in: $0) } ?? L("From %@")
        return String(format: format, locale: locale, formatted(day, template: "EEEEdM", locale: locale, calendar: calendar))
    }

    /// "Thursday": the day's name alone, for the banner and the notice.
    static func weekday(of day: DailyDay, locale: Locale = Localization.locale, calendar: Calendar = .current) -> String {
        formatted(day, template: "EEEE", locale: locale, calendar: calendar)
    }

    private static func formatted(_ day: DailyDay, template: String, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatter.formattingContext = .middleOfSentence
        return day.date(calendar: calendar).map(formatter.string(from:)) ?? day.string
    }

    /// The block the tasks go in: the heading, then the items.
    static func block(_ offer: Offer, heading: String) -> String {
        (["### " + heading] + offer.lines).joined(separator: "\n")
    }

    /// `body` with the tasks at its end, under their heading, a blank line
    /// before. Only the new daily changes; the one they came from does not.
    static func inserting(_ offer: Offer, into body: String, heading: String) -> String {
        // Only the trailing blank lines go: a template's empty "- [ ] " keeps
        // its space, which is what makes it an item the caret can fill in.
        var trimmed = body
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + block(offer, heading: heading) + "\n"
    }

    /// Undo: `body` without the block `inserting` added, if it is still there
    /// as it was written; otherwise `body` unchanged.
    static func removing(_ offer: Offer, from body: String, heading: String) -> String {
        let block = block(offer, heading: heading)
        guard let range = body.range(of: block, options: .backwards) else { return body }
        var before = String(body[..<range.lowerBound])
        let after = String(body[range.upperBound...])
        while before.hasSuffix("\n") { before.removeLast() }
        let rest = after.drop { $0 == "\n" }
        return before.isEmpty ? String(rest) : before + (rest.isEmpty ? "\n" : "\n\n" + rest)
    }
}
