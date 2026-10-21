import Foundation

/// All Notes' three orders.
func runNoteSortTests() {
    struct Item: SortableNote {
        let id: UUID
        let displayTitle: String
        let createdAt: Date
        let editedAt: Date
    }
    func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + n * 86_400) }
    let a = Item(id: UUID(), displayTitle: "banana", createdAt: day(1), editedAt: day(9))
    let b = Item(id: UUID(), displayTitle: "Apple", createdAt: day(3), editedAt: day(4))
    let c = Item(id: UUID(), displayTitle: "item 10", createdAt: day(2), editedAt: day(6))
    let d = Item(id: UUID(), displayTitle: "item 9", createdAt: day(5), editedAt: day(2))
    let items = [a, b, c, d]
    func order(_ sort: NoteSort) -> String { sort.sorted(items).map(\.displayTitle).joined(separator: ", ") }

    expect("sort: Edited is the default", NoteSort.default.rawValue, "edited")
    expect("sort: Edited, the last edit first", order(.edited), "banana, item 10, Apple, item 9")
    expect("sort: Created, the newest first", order(.created), "item 9, Apple, item 10, banana")
    expect("sort: Title, as the Finder orders names", order(.title), "Apple, banana, item 9, item 10")

    // Same title: the later edit first.
    let older = Item(id: UUID(), displayTitle: "Same", createdAt: day(1), editedAt: day(1))
    let newer = Item(id: UUID(), displayTitle: "same", createdAt: day(1), editedAt: day(2))
    expectTrue("sort: a tie in title goes to the later edit", NoteSort.title.sorted([older, newer]).first?.editedAt == day(2))
    expect("sort: the menu names them", NoteSort.allCases.map(\.title).joined(separator: ", "), "Edited, Created, Title")
}
