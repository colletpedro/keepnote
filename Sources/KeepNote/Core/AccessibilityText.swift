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

    /// An attachment in a note: "Image, a red barn at dusk" (or "Image, no
    /// description"); "File, Invoice.pdf, 1.2 MB".
    static func attachment(isImage: Bool, label: String, name: String?, size: String?) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if isImage {
            return label.isEmpty ? L("Image, no description") : L("Image, %@", label)
        }
        let shown = label.isEmpty ? (name ?? L("Attachment")) : label
        guard let size else { return L("File, %@, not on this Mac yet", shown) }
        return L("File, %@, %@", shown, size)
    }

    /// The "+N" chip: "12 more notes".
    static func overflowLabel(count: Int) -> String {
        Lplural(count, L("1 more note"), L("%d more notes"))
    }
}

/// Settings > General > Text size: how large the text of notes, the peek
/// and All Notes is drawn.
enum TextSize: String, CaseIterable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var scale: Double {
        switch self {
        case .small: return 0.88
        case .standard: return 1
        case .large: return 1.18
        case .extraLarge: return 1.36
        }
    }

    var title: String {
        switch self {
        case .small: return L("Small")
        case .standard: return L("Default")
        case .large: return L("Large")
        case .extraLarge: return L("Extra Large")
        }
    }
}
