import Foundation

/// The colour of a group: one of twelve, picked from the group's menu.
///
/// Raw values are part of the on-disk format (the database, the sync folder
/// and the archive) and must never change; new colours take the next number.
enum GroupColor: Int, CaseIterable, Codable, Sendable {
    case red = 1
    case orange = 2
    case amber = 3
    case lime = 4
    case green = 5
    case teal = 6
    case cyan = 7
    case blue = 8
    case indigo = 9
    case purple = 10
    case pink = 11
    case slate = 12

    /// What a group gets when nothing else decides.
    static let `default` = GroupColor.blue

    /// The only way colours should be read back from disk: one this build does
    /// not know (a newer file) falls back to the default.
    static func resolve(rawValue: Int) -> GroupColor {
        GroupColor(rawValue: rawValue) ?? .default
    }

    var displayName: String {
        switch self {
        case .red: return L("Red")
        case .orange: return L("Orange")
        case .amber: return L("Amber")
        case .lime: return L("Lime")
        case .green: return L("Green")
        case .teal: return L("Teal")
        case .cyan: return L("Cyan")
        case .blue: return L("Blue")
        case .indigo: return L("Indigo")
        case .purple: return L("Purple")
        case .pink: return L("Pink")
        case .slate: return L("Slate")
        }
    }

    var swatch: GroupPalette.Swatch {
        switch self {
        case .red: return GroupPalette.red
        case .orange: return GroupPalette.orange
        case .amber: return GroupPalette.amber
        case .lime: return GroupPalette.lime
        case .green: return GroupPalette.green
        case .teal: return GroupPalette.teal
        case .cyan: return GroupPalette.cyan
        case .blue: return GroupPalette.blue
        case .indigo: return GroupPalette.indigo
        case .purple: return GroupPalette.purple
        case .pink: return GroupPalette.pink
        case .slate: return GroupPalette.slate
        }
    }

    /// The colour after this one, for a new group: they walk the palette.
    var next: GroupColor {
        let all = GroupColor.allCases
        guard let index = all.firstIndex(of: self) else { return .default }
        return all[(index + 1) % all.count]
    }
}
