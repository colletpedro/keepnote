import AppKit

/// What a group's tab says.
struct GroupTabInfo: Equatable {
    var name: String
    var count: Int
    var look: GroupCardView.Look
}

/// What the deck's cards draw, apart from where they go: the notes and the
/// groups its plan names, and the groups a note's menu offers.
struct DeckContent {
    var notes: [UUID: Note] = [:]
    var groups: [DeckGroupRef: GroupTabInfo] = [:]
    var choices: [GroupMenu.Choice] = []

    /// A group the plan names always has its info; a stand-in keeps a bug
    /// from becoming a crash.
    func group(_ ref: DeckGroupRef) -> GroupTabInfo {
        groups[ref] ?? GroupTabInfo(name: "", count: 0, look: .palette(.default))
    }

    /// Everything the deck draws, worked out from the notes on it, the groups
    /// and the plan made from them.
    @MainActor
    static func make(notes: [Note], groups: [NoteGroup], dailyColor: NoteColor, plan: DeckPlan) -> DeckContent {
        var content = DeckContent()
        content.notes = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        content.choices = GroupMenu.choices(groups)
        for (ref, count) in plan.counts {
            switch ref {
            case .daily:
                content.groups[ref] = GroupTabInfo(name: L("Daily"), count: count, look: .paper(dailyColor))
            case .user(let id):
                guard let group = groups.first(where: { $0.id == id }) else { continue }
                content.groups[ref] = GroupTabInfo(name: group.name, count: count, look: .palette(group.color))
            }
        }
        return content
    }
}
