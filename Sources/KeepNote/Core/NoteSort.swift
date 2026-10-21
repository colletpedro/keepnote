import Foundation

/// What All Notes' list can be ordered by. Pure, so the tests can sort plain
/// values with it.
protocol SortableNote {
    var id: UUID { get }
    var displayTitle: String { get }
    var createdAt: Date { get }
    var editedAt: Date { get }
}

/// All Notes' order, from the toolbar's menu: the last edit first (the
/// default), the newest first, or by title as the Finder orders names.
enum NoteSort: String, CaseIterable, Sendable {
    case edited
    case created
    case title

    static let `default` = NoteSort.edited

    var title: String {
        switch self {
        case .edited: return L("Edited")
        case .created: return L("Created")
        case .title: return L("Title")
        }
    }

    /// Ties go to the later edit, then to the id, so the order never jumps.
    func sorted<T: SortableNote>(_ notes: [T]) -> [T] {
        notes.sorted { a, b in
            switch self {
            case .edited:
                if a.editedAt != b.editedAt { return a.editedAt > b.editedAt }
            case .created:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .title:
                let order = a.displayTitle.localizedStandardCompare(b.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
                if a.editedAt != b.editedAt { return a.editedAt > b.editedAt }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
