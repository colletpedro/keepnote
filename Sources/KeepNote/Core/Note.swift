import Foundation

/// Where a note sits in its life cycle. Persisted as TEXT, so the raw values
/// are part of the on-disk format.
enum NoteState: String, Codable, CaseIterable, Sendable {
    case active
    case archived
}

/// A note as the rest of the app sees it: body already in the clear.
/// Encryption happens at the persistence boundary, never above it.
struct Note: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String {
        didSet { if title != oldValue { text = DerivedText(title: title, body: body) } }
    }
    var body: String {
        didSet { if body != oldValue { text = DerivedText(title: title, body: body) } }
    }
    var color: NoteColor
    var state: NoteState
    var sortIndex: Int
    var tags: [String]
    var createdAt: Date
    /// When the note last changed in any way — text, tags, colour, pin, state.
    /// This is what sync compares (last writer wins); it is not shown.
    var updatedAt: Date
    /// When the title or the body last changed: the "Edited" date that is
    /// shown and that lists sort by. Pinning, keeping, archiving (by hand or by
    /// the rules), tags and colour move `updatedAt` but never this.
    var editedAt: Date
    var deletedAt: Date?
    /// The "day of the daily": the local day the note received the `daily` tag,
    /// or was created with it. Set when the tag arrives, fixed afterwards, and
    /// cleared with the tag. `nil` on a note that is not a daily.
    var dailyDay: DailyDay?
    /// A daily that was brought back to the deck by hand when the archive rule
    /// would have archived it. The rule leaves it there. Goes with the tag.
    var dailyKept: Bool
    /// "Keep on Deck": the archive-by-time rule never archives this note.
    var keepOnDeck: Bool
    /// "Pin to Center": when the note was pinned, or `nil` if it is not. The
    /// order notes were pinned in is the order the pinned block is laid out in.
    var pinnedAt: Date?
    /// The local day the note was last opened (or created, or brought back
    /// from the archive): where the archive-by-time rule counts from. Kept
    /// to a day, and written at most once a day, so opening a note does not
    /// make a change to sync. A note that has none is given the day it is
    /// first loaded on, so nothing is archived by an update.
    var lastOpenedDay: DailyDay?
    /// The day the time rule archived the note, which the Archive says; `nil`
    /// for a note archived by hand, or not archived. Cleared when it comes back.
    var autoArchivedDay: DailyDay?
    /// The body could not be decrypted with this Mac's key, so `body` holds a
    /// placeholder rather than the user's text. Never persisted: it is derived
    /// at load time, and a locked note is read-only and never leaves the Mac.
    var isLocked: Bool

    /// What the deck, the peek and the lists show, worked out from the title
    /// and the body at most once per change to either. Copies of the note
    /// share it; changing the title or the body starts a fresh one.
    private var text: DerivedText

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        color: NoteColor = .default,
        state: NoteState = .active,
        sortIndex: Int = 0,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        editedAt: Date? = nil,
        deletedAt: Date? = nil,
        dailyDay: DailyDay? = nil,
        dailyKept: Bool = false,
        keepOnDeck: Bool = false,
        pinnedAt: Date? = nil,
        lastOpenedDay: DailyDay? = nil,
        autoArchivedDay: DailyDay? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.color = color
        self.state = state
        self.sortIndex = sortIndex
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editedAt = editedAt ?? updatedAt
        self.deletedAt = deletedAt
        self.dailyDay = dailyDay
        self.dailyKept = dailyKept
        self.keepOnDeck = keepOnDeck
        self.pinnedAt = pinnedAt
        self.lastOpenedDay = lastOpenedDay
        self.autoArchivedDay = autoArchivedDay
        self.isLocked = isLocked
        self.text = DerivedText(title: title, body: body)
    }

    /// The body as it reads, without markdown syntax. Display only.
    var plainBody: String { text.plainBody }

    /// What the stack label, the list row and the window title show. An empty
    /// note has no title of its own, so the first non-blank body line stands in.
    var displayTitle: String { text.displayTitle }

    /// One-line summary for list rows and the peek: the body without the line
    /// that only repeats the title.
    var preview: String { text.preview }

    /// The label drawn vertically on a fanned card. Kept short on purpose:
    /// the spine is 12 pt wide and the card only a little more.
    var spineLabel: String { text.spineLabel }

    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.body == rhs.body && lhs.color == rhs.color
            && lhs.state == rhs.state && lhs.sortIndex == rhs.sortIndex && lhs.tags == rhs.tags
            && lhs.createdAt == rhs.createdAt && lhs.updatedAt == rhs.updatedAt && lhs.editedAt == rhs.editedAt
            && lhs.deletedAt == rhs.deletedAt && lhs.isLocked == rhs.isLocked
            && lhs.dailyDay == rhs.dailyDay && lhs.dailyKept == rhs.dailyKept
            && lhs.keepOnDeck == rhs.keepOnDeck && lhs.pinnedAt == rhs.pinnedAt
            && lhs.lastOpenedDay == rhs.lastOpenedDay && lhs.autoArchivedDay == rhs.autoArchivedDay
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(body)
        hasher.combine(color)
        hasher.combine(state)
        hasher.combine(sortIndex)
        hasher.combine(tags)
        hasher.combine(createdAt)
        hasher.combine(updatedAt)
        hasher.combine(editedAt)
        hasher.combine(deletedAt)
        hasher.combine(dailyDay)
        hasher.combine(dailyKept)
        hasher.combine(keepOnDeck)
        hasher.combine(pinnedAt)
        hasher.combine(lastOpenedDay)
        hasher.combine(autoArchivedDay)
        hasher.combine(isLocked)
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tags round-trip through a single TEXT column and through `.hmnote`
    /// headers, so they are normalised the same way everywhere.
    static func normalizeTags(_ raw: [String]) -> [String] {
        TagText.normalize(raw)
    }

    static func parseTags(_ csv: String) -> [String] {
        normalizeTags(csv.split(separator: ",").map(String.init))
    }

    var tagsCSV: String { tags.joined(separator: ",") }

    var isPinned: Bool { pinnedAt != nil }

    /// Kept on the deck by hand: no rule archives it.
    var staysOnDeck: Bool { keepOnDeck || isPinned }

    /// Carries the reserved `daily` tag.
    var isDaily: Bool { DailyNotes.hasTag(tags) }

    /// Free-text match used by All Notes and by the archive window. Body search
    /// runs here, in memory, because the body index would leak plaintext.
    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if title.lowercased().contains(needle) { return true }
        if body.lowercased().contains(needle) { return true }
        return tags.contains { $0.contains(needle) }
    }
}

extension Note: DailyItem {}
extension Note: PinItem {}
extension Note: AutoArchiveItem {}

extension Note: TaggedItem {
    var isArchived: Bool { state == .archived }
    var isDeleted: Bool { deletedAt != nil }
}

/// A note's display text, each piece worked out the first time it is asked
/// for. The markdown is stripped with a dozen regular expressions per line, so
/// doing it on every hover or redraw — for every tab in the deck — is what
/// used to stall the main thread. Locked because a note can be read from more
/// than one thread.
private final class DerivedText: @unchecked Sendable {
    private let title: String
    private let body: String
    private let lock = NSLock()
    private var cachedPlainBody: String?
    private var cachedDisplayTitle: String?
    private var cachedPreview: String?

    init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    var plainBody: String {
        cached(\.cachedPlainBody) { MarkdownText.plain(body) }
    }

    var displayTitle: String {
        cached(\.cachedDisplayTitle) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let firstLine = MarkdownText.firstPlainLine(body)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstLine, !firstLine.isEmpty { return firstLine }
            return "Untitled"
        }
    }

    var preview: String {
        let plain = plainBody
        return cached(\.cachedPreview) { PreviewText.make(title: title, plainBody: plain) }
    }

    var spineLabel: String {
        let title = displayTitle
        return title.count <= 24 ? title : String(title.prefix(23)) + "\u{2026}"
    }

    private func cached(_ slot: ReferenceWritableKeyPath<DerivedText, String?>, _ make: () -> String) -> String {
        lock.lock()
        if let value = self[keyPath: slot] {
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = make()
        lock.lock()
        self[keyPath: slot] = value
        lock.unlock()
        return value
    }
}

/// What a note looks like on disk once the body is sealed. Only the
/// persistence and sync layers deal in this type.
struct EncryptedNoteRecord: Sendable {
    var id: UUID
    var title: String
    var bodyCiphertext: Data
    var nonce: Data
    var color: NoteColor
    var state: NoteState
    var sortIndex: Int
    var tagsCSV: String
    var createdAt: Date
    var updatedAt: Date
    var editedAt: Date
    var deletedAt: Date?
    var dailyDay: String?
    var dailyKept: Bool
    var keepOnDeck: Bool
}
