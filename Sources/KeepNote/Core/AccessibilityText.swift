import Foundation

/// What VoiceOver says about the deck, composed here so it can be tested:
/// every state a tab shows with a colour or a glyph is also said in words.
enum AccessibilityText {
    /// The states of a tab, in the order they are read.
    struct TabState: Equatable {
        var colorName: String
        var isPinned = false
        var isKept = false
        var isFloating = false
        var isDaily = false
        /// Days before the time rule archives it, when that is one or two.
        var daysLeft: Int?
    }

    /// "Butter note, pinned to center, kept on deck, floating, daily, archives tomorrow".
    static func tabDescription(_ state: TabState) -> String {
        var parts = [L("%@ note", state.colorName)]
        if state.isPinned { parts.append(L("pinned to center")) }
        if state.isKept { parts.append(L("kept on deck")) }
        if state.isFloating { parts.append(L("floating")) }
        if state.isDaily { parts.append(L("daily")) }
        if let days = state.daysLeft {
            parts.append(Lplural(days, L("archives tomorrow"), L("archives in %d days")))
        }
        return parts.joined(separator: ", ")
    }

    /// The resting stripe: "8 notes".
    static func deckValue(count: Int) -> String {
        Lplural(count, L("1 note"), L("%d notes"))
    }

    /// The "+N" chip: "12 more notes".
    static func overflowLabel(count: Int) -> String {
        Lplural(count, L("1 more note"), L("%d more notes"))
    }
}
