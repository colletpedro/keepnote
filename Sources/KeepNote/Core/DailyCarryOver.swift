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
