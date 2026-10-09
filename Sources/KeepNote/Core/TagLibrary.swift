import Foundation

/// What the tag functions need to know about a note. `Note` conforms; the
/// tests use a plain struct, so none of this needs AppKit.
protocol TaggedItem {
    var id: UUID { get }
    var tags: [String] { get }
    var isArchived: Bool { get }
    var isDeleted: Bool { get }
    /// Read-only: tag edits skip it and count it.
    var isLocked: Bool { get }
}

/// The shelves of All Notes' sidebar.
enum NoteLibrary: String, CaseIterable, Sendable {
    case all
    case deck
    case archived
    /// Every daily note, on the deck or archived, grouped by day.
    case daily

    var title: String {
        switch self {
        case .all: return "All Notes"
        case .deck: return "On the Deck"
        case .archived: return "Archived"
        case .daily: return "Daily"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .deck: return "rectangle.portrait.on.rectangle.portrait"
        case .archived: return "archivebox"
        case .daily: return "calendar"
        }
    }
}

/// What the sidebar has selected: a library, a tag, or the untagged notes.
enum NoteSelection: Hashable, Sendable {
    case library(NoteLibrary)
    case tag(String)
    case untagged

    static let `default` = NoteSelection.library(.all)

    var title: String {
        switch self {
        case .library(let library): return library.title
        case .tag(let name): return "#" + name
        case .untagged: return "Untagged"
        }
    }

    /// How the selection is kept between openings: `library:all`, `tag:work`,
    /// `untagged`.
    var storageValue: String {
        switch self {
        case .library(let library): return "library:" + library.rawValue
        case .tag(let name): return "tag:" + name
        case .untagged: return "untagged"
        }
    }

    /// The selection a stored value stands for; anything unreadable is `nil`.
    init?(storageValue: String) {
        if storageValue == "untagged" {
            self = .untagged
        } else if storageValue.hasPrefix("library:"),
                  let library = NoteLibrary(rawValue: String(storageValue.dropFirst("library:".count))) {
            self = .library(library)
        } else if storageValue.hasPrefix("tag:"),
                  let name = TagText.normalize([String(storageValue.dropFirst("tag:".count))]).first {
            // The reserved tag has a shelf of its own.
            self = DailyNotes.isReserved(name) ? .library(.daily) : .tag(name)
        } else {
            return nil
        }
    }
}

/// Tags across all notes: the sidebar's index, the filter behind it, and the
/// rename, delete, add and remove edits. Every comparison goes through
/// `TagText.fold`, so case and accents never make two tags of one.
enum TagLibrary {
    struct Entry: Equatable {
        var name: String
        var count: Int
    }

    struct Index: Equatable {
        /// Most used first, then alphabetical.
        var tags: [Entry]
        var untagged: Int
        var all: Int
        var deck: Int
        /// Archived notes, not counting the archived dailies: those are kept
        /// under Daily.
        var archived: Int
        var daily: Int

        func count(of library: NoteLibrary) -> Int {
            switch library {
            case .all: return all
            case .deck: return deck
            case .archived: return archived
            case .daily: return daily
            }
        }

        /// The tags some note carries: the index without the reserved tag when
        /// no note has it.
        var used: [Entry] { tags.filter { $0.count > 0 } }

        /// The tag's own spelling in the index, found ignoring case and accents.
        func entry(named name: String) -> Entry? {
            let wanted = TagText.fold(TagText.name(ofToken: name))
            return tags.first { TagText.fold($0.name) == wanted }
        }
    }

    /// Counts over the notes that are not deleted. A note counts once per tag
    /// however many spellings of it it carries; a tag spelled several ways is
    /// shown with the spelling most notes use. The reserved `daily` tag is
    /// always there, with a count of zero when no note has it.
    static func index<T: TaggedItem>(_ notes: [T]) -> Index {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        var index = Index(tags: [], untagged: 0, all: 0, deck: 0, archived: 0, daily: 0)
        for note in notes where !note.isDeleted {
            index.all += 1
            let isDaily = DailyNotes.hasTag(note.tags)
            if isDaily { index.daily += 1 }
            if !note.isArchived { index.deck += 1 } else if !isDaily { index.archived += 1 }
            let tags = TagText.normalize(note.tags)
            if tags.isEmpty { index.untagged += 1 }
            var seen = Set<String>()
            for tag in tags {
                let key = TagText.fold(tag)
                spellings[key, default: [:]][tag, default: 0] += 1
                if seen.insert(key).inserted { counts[key, default: 0] += 1 }
            }
        }
        counts[DailyNotes.tag, default: 0] += 0
        index.tags = counts.map { key, count in
            if key == DailyNotes.tag { return Entry(name: DailyNotes.tag, count: count) }
            let name = spellings[key]!.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!.key
            return Entry(name: name, count: count)
        }
        index.tags.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            let (fa, fb) = (TagText.fold(a.name), TagText.fold(b.name))
            return fa != fb ? fa < fb : a.name < b.name
        }
        return index
    }

    /// The notes a selection shows, deleted ones never. A tag shows its notes
    /// on the deck and in the archive alike. Archived dailies are shown by
    /// Daily alone, not by Archived.
    static func filter<T: TaggedItem>(_ notes: [T], by selection: NoteSelection) -> [T] {
        notes.filter { note in
            guard !note.isDeleted else { return false }
            switch selection {
            case .library(.all): return true
            case .library(.deck): return !note.isArchived
            case .library(.archived): return note.isArchived && !DailyNotes.hasTag(note.tags)
            case .library(.daily): return DailyNotes.hasTag(note.tags)
            case .tag(let name): return TagText.matches(tags: note.tags, filter: name)
            case .untagged: return TagText.normalize(note.tags).isEmpty
            }
        }
    }

    // MARK: - Editing one note's tags

    private static func dedupeFolded(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return TagText.normalize(tags).filter { seen.insert(TagText.fold($0)).inserted }
    }

    private static func has(_ tags: [String], _ name: String) -> Bool {
        let wanted = TagText.fold(TagText.name(ofToken: name))
        return tags.contains { TagText.fold($0) == wanted }
    }

    /// `old` replaced by `new`, in place. A note that already has `new` keeps
    /// one copy, where the first of the two was. `nil` when the note does not
    /// have `old`, or nothing would change.
    static func renaming(_ old: String, to new: String, in tags: [String]) -> [String]? {
        guard has(tags, old), let target = TagText.normalize([new]).first else { return nil }
        let wanted = TagText.fold(TagText.name(ofToken: old))
        let result = dedupeFolded(tags.map { TagText.fold($0) == wanted ? target : $0 })
        return result == tags ? nil : result
    }

    /// `name` taken off; `nil` when the note does not have it.
    static func removing(_ name: String, from tags: [String]) -> [String]? {
        guard has(tags, name) else { return nil }
        let wanted = TagText.fold(TagText.name(ofToken: name))
        return tags.filter { TagText.fold($0) != wanted }
    }

    /// `name` added at the end; `nil` when the note already has it or the name
    /// is not a tag.
    static func adding(_ name: String, to tags: [String]) -> [String]? {
        guard let tag = TagText.normalize([name]).first, !has(tags, tag) else { return nil }
        return tags + [tag]
    }

    // MARK: - Editing many notes

    /// The notes an edit touches, with their new tags, and how many it had to
    /// leave alone because they are locked.
    struct Plan: Equatable {
        var changes: [UUID: [String]]
        var skippedLocked: Int
    }

    private static func plan<T: TaggedItem>(_ notes: [T], _ edit: ([String]) -> [String]?) -> Plan {
        var result = Plan(changes: [:], skippedLocked: 0)
        for note in notes where !note.isDeleted {
            guard let tags = edit(note.tags) else { continue }
            if note.isLocked {
                result.skippedLocked += 1
            } else {
                result.changes[note.id] = tags
            }
        }
        return result
    }

    /// What a rename is going to be: the name it lands on and whether that name
    /// already exists as another tag, in which case the two are merged.
    struct Rename: Equatable {
        var target: String
        var merges: Bool
    }

    /// `nil` when `new` is not a tag name or is exactly `old`. Renaming onto an
    /// existing tag takes that tag's spelling; a rename that only changes the
    /// accents of the same tag takes the new spelling. Names are lower-cased,
    /// so a change of case alone is no rename.
    static func rename<T: TaggedItem>(_ old: String, to new: String, in notes: [T]) -> Rename? {
        guard DailyNotes.renameBlock(old, to: new) == nil else { return nil }
        guard let typed = TagText.normalize([new]).first else { return nil }
        let oldKey = TagText.fold(TagText.name(ofToken: old))
        if TagText.fold(typed) == oldKey {
            return typed == TagText.name(ofToken: old) ? nil : Rename(target: typed, merges: false)
        }
        if let existing = index(notes).entry(named: typed) {
            return Rename(target: existing.name, merges: true)
        }
        return Rename(target: typed, merges: false)
    }

    static func renamePlan<T: TaggedItem>(_ old: String, to new: String, in notes: [T]) -> Plan {
        guard let rename = rename(old, to: new, in: notes) else { return Plan(changes: [:], skippedLocked: 0) }
        return plan(notes) { renaming(old, to: rename.target, in: $0) }
    }

    /// Takes the tag off every note; no note is deleted.
    static func deletePlan<T: TaggedItem>(_ name: String, in notes: [T]) -> Plan {
        guard !DailyNotes.isReserved(name) else { return Plan(changes: [:], skippedLocked: 0) }
        return plan(notes) { removing(name, from: $0) }
    }

    static func addPlan<T: TaggedItem>(_ name: String, to notes: [T]) -> Plan {
        plan(notes) { adding(name, to: $0) }
    }

    static func removePlan<T: TaggedItem>(_ name: String, from notes: [T]) -> Plan {
        plan(notes) { removing(name, from: $0) }
    }

    // MARK: - What the confirmations say

    static func notesPhrase(_ count: Int) -> String {
        "\(count) note\(count == 1 ? "" : "s")"
    }

    /// Delete Tag…: how many notes lose it, and that they stay.
    static func deleteMessage(_ name: String, count: Int) -> (title: String, detail: String) {
        ("Delete the tag \u{201C}#\(name)\u{201D}?",
         "\(notesPhrase(count)) will lose this tag. The notes themselves are kept.")
    }

    /// Rename Tag… onto a name that already exists.
    static func mergeMessage(_ old: String, into target: String, count: Int) -> (title: String, detail: String) {
        ("Merge \u{201C}#\(old)\u{201D} into \u{201C}#\(target)\u{201D}?",
         "\u{201C}#\(target)\u{201D} already exists. \(notesPhrase(count)) tagged #\(old) will be tagged #\(target) instead, and #\(old) will be gone.")
    }
}

/// Notes dragged out of All Notes' list, as plain text: `keepnote-notes:` and
/// the ids, comma-separated. Anything else dropped on a tag is ignored.
enum NoteDragPayload {
    static let prefix = "keepnote-notes:"

    static func encode(_ ids: [UUID]) -> String {
        prefix + ids.map(\.uuidString).joined(separator: ",")
    }

    static func decode(_ text: String) -> [UUID] {
        guard text.hasPrefix(prefix) else { return [] }
        var seen = Set<UUID>()
        return text.dropFirst(prefix.count).split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
            .filter { seen.insert($0).inserted }
    }
}
