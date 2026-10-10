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
    /// When the text or the colour last changed, for last-writer-wins between
    /// Macs. `distantPast` while the template has never been set.
    var updatedAt: Date
    /// The colour of the card, and of every daily born from the template.
    /// Butter, the colour a note has always started with, until it is chosen.
    var color: NoteColor = .default

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
