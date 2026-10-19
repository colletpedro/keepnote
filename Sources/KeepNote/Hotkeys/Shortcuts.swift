import AppKit
import Carbon.HIToolbox

/// The commands inside an open note that have a shortcut of their own. The
/// formatting ones (⌘B, ⌘I, ⌘K, ⇧⌘7…) are not here: they stay fixed, like
/// Close (esc and ⌘W).
enum NoteCommand: String, CaseIterable, Identifiable, Sendable {
    case find
    case findNext
    case findPrevious
    case nextColor
    case previousColor
    case float
    case archive
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .find: return L("Find in note")
        case .findNext: return L("Next match")
        case .findPrevious: return L("Previous match")
        case .nextColor: return L("Next color")
        case .previousColor: return L("Previous color")
        case .float: return L("Float Note \u{00B7} Return to Deck")
        case .archive: return L("Archive")
        case .delete: return L("Delete (undoable)")
        }
    }

    var defaultCombo: KeyCombo {
        let command = UInt32(cmdKey), option = UInt32(optionKey), shift = UInt32(shiftKey)
        switch self {
        case .find: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: command)
        case .findNext: return KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: command)
        case .findPrevious: return KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: command | shift)
        case .nextColor: return KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: command | option)
        case .previousColor: return KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: command | option | shift)
        case .float: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: command | option)
        case .archive: return KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: command | shift)
        case .delete: return KeyCombo(keyCode: UInt32(kVK_Delete), carbonModifiers: command | shift)
        }
    }
}

/// Anything with a shortcut the user can change: a global command, which
/// works from any app, or a command inside a note.
enum ShortcutAction: Hashable, Identifiable, Sendable {
    case global(GlobalCommand)
    case note(NoteCommand)

    static var all: [ShortcutAction] {
        GlobalCommand.allCases.map(ShortcutAction.global) + NoteCommand.allCases.map(ShortcutAction.note)
    }

    var id: String {
        switch self {
        case .global(let command): return "global.\(command.rawValue)"
        case .note(let command): return "note.\(command.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .global(let command): return command.title
        case .note(let command): return command.title
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .global(let command): return command.defaultCombo
        case .note(let command): return command.defaultCombo
        }
    }
}

/// Every changeable shortcut, kept in this Mac's preferences: the default
/// until one is recorded, a recorded combination, or none at all.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    private let defaults: UserDefaults
    /// Bumped on every change, so SwiftUI redraws whatever shows a shortcut.
    @Published private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyHotkeys()
    }

    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.id)" }
    private static let none = "none"

    /// The combination for `action`; `nil` when it has none.
    func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let stored = defaults.string(forKey: Self.key(action)) else { return action.defaultCombo }
        return stored == Self.none ? nil : KeyCombo(storageValue: stored) ?? action.defaultCombo
    }

    /// Stores `combo` (`nil`: no shortcut) as it is. Validation is the caller's.
    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        let before = defaults.string(forKey: Self.key(action))
        let after: String? = combo == action.defaultCombo ? nil : (combo?.storageValue ?? Self.none)
        guard before != after else { return }
        if let after {
            defaults.set(after, forKey: Self.key(action))
        } else {
            defaults.removeObject(forKey: Self.key(action))
        }
        changed()
    }

    /// The action in a note window that `event` triggers, if any.
    func noteCommand(for event: NSEvent) -> NoteCommand? {
        let pressed = KeyCombo(event: event)
        return NoteCommand.allCases.first { combo(for: .note($0)) == pressed }
    }

    /// "⌥⌘N", or nothing.
    func label(for action: ShortcutAction) -> String? {
        combo(for: action)?.displayString
    }

    private func changed() {
        revision &+= 1
        NotificationCenter.default.post(name: .keepNoteShortcutsChanged, object: self)
    }

    /// The global shortcuts used to be kept as JSON under `hotkey.<command>`.
    private func migrateLegacyHotkeys() {
        for command in GlobalCommand.allCases {
            let legacy = "hotkey.\(command.rawValue)"
            guard let data = defaults.data(forKey: legacy) else { continue }
            if defaults.string(forKey: Self.key(.global(command))) == nil,
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data), combo != command.defaultCombo {
                defaults.set(combo.storageValue, forKey: Self.key(.global(command)))
            }
            defaults.removeObject(forKey: legacy)
        }
    }
}

extension Notification.Name {
    /// A shortcut was recorded, cleared or restored.
    static let keepNoteShortcutsChanged = Notification.Name("keepNote.shortcutsChanged")
}

/// What happens when a combination is recorded in Settings > Shortcuts.
@MainActor
enum ShortcutEditing {
    static func record(_ combo: KeyCombo?, for action: ShortcutAction, store: ShortcutStore,
                       hotkeys: HotkeyService) -> ShortcutRecorderField.Outcome {
        guard let combo else {
            store.set(nil, for: action)
            return .accepted
        }
        guard combo.hasRequiredModifier else { return .refused(L("Needs \u{2318}, \u{2325} or \u{2303}")) }
        store.set(combo, for: action)
        return .accepted
    }
}
