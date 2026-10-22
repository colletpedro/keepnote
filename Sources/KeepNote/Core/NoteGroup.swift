import Foundation

/// A group of notes: a name, a colour and a place among the groups. A note
/// belongs to at most one, and does not have to belong to any.
///
/// Groups are kept apart from the notes — their own table, their own file in
/// the sync folder, their own list in an archive — and a note only says which
/// one it is in. Foundation only, so the rules can be tested without AppKit.
struct NoteGroup: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var color: GroupColor
    /// Where the group stands among the others, first at 0. Groups sort by
    /// this, then by when they were made, then by id, so every Mac that has
    /// the same groups puts them in the same order.
    var order: Int
    var createdAt: Date
    /// When the name, the colour or the place last changed: what sync compares
    /// (last writer wins).
    var updatedAt: Date

    init(
        id: UUID = UUID(), name: String, color: GroupColor = .default, order: Int = 0,
        createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The longest name a group keeps; the tab and the lists cut it short
    /// themselves, this only stops a paste of a page.
    static let nameLimit = 60

    /// What a typed name becomes: trimmed, on one line, cut to `nameLimit`.
    /// Nothing at all is not a name.
    static func cleaned(_ raw: String) -> String? {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
    }

    /// The groups in the order they stand.
    static func sorted(_ groups: [NoteGroup]) -> [NoteGroup] {
        groups.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Whether `incoming` should replace this copy: strictly newer, which also
    /// makes a replayed file harmless.
    func accepts(_ incoming: NoteGroup) -> Bool {
        incoming.updatedAt > updatedAt
    }

    /// `ids` as a new order for `groups`: the groups named first, in that
    /// order, then any not named, in the order they were in.
    static func reordered(_ groups: [NoteGroup], ids: [UUID]) -> [NoteGroup] {
        let sortedGroups = sorted(groups)
        let byID = Dictionary(sortedGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let named = ids.compactMap { id -> NoteGroup? in
            guard let group = byID[id], seen.insert(id).inserted else { return nil }
            return group
        }
        return named + sortedGroups.filter { !seen.contains($0.id) }
    }
}

/// What the group rules need to know about a note. `Note` conforms; the tests
/// use a plain struct.
protocol GroupedItem {
    var id: UUID { get }
    var groupID: UUID? { get }
    var isArchived: Bool { get }
    var isDeleted: Bool { get }
}

/// Which group a note is in, and what each group holds.
enum GroupLibrary {
    /// The group a note is in: the one it names, if that group exists. A note
    /// that names a group this Mac has not heard of yet (its file arrived before
    /// the group's) or no longer has is in none.
    static func effectiveGroup<T: GroupedItem>(of item: T, among groups: [NoteGroup]) -> UUID? {
        guard let id = item.groupID, groups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The notes of each group, counted over the notes that are not deleted —
    /// archived ones included, since they come back to their group — and the
    /// notes in none.
    struct Counts: Equatable {
        var byGroup: [UUID: Int]
        var ungrouped: Int

        func count(of group: UUID) -> Int { byGroup[group] ?? 0 }
    }

    static func counts<T: GroupedItem>(_ items: [T], groups: [NoteGroup]) -> Counts {
        let known = Set(groups.map(\.id))
        var counts = Counts(byGroup: [:], ungrouped: 0)
        for item in items where !item.isDeleted {
            if let id = item.groupID, known.contains(id) {
                counts.byGroup[id, default: 0] += 1
            } else {
                counts.ungrouped += 1
            }
        }
        return counts
    }

    /// The notes in `group` and not deleted, in the order given.
    static func members<T: GroupedItem>(of group: UUID, in items: [T], groups: [NoteGroup]) -> [T] {
        guard groups.contains(where: { $0.id == group }) else { return [] }
        return items.filter { !$0.isDeleted && $0.groupID == group }
    }

    /// The notes in no group, in the order given.
    static func ungrouped<T: GroupedItem>(_ items: [T], groups: [NoteGroup]) -> [T] {
        items.filter { !$0.isDeleted && effectiveGroup(of: $0, among: groups) == nil }
    }
}
