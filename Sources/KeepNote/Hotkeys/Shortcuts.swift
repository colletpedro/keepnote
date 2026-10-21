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

    /// A tooltip naming the shortcut as it is now: "Float Note (⌥⌘P)".
    func tooltip(_ title: String, _ action: ShortcutAction) -> String {
        label(for: action).map { L("%@ (%@)", title, $0) } ?? title
    }

    /// Every shortcut back to KeepNote's own, none of them left without one.
    func restoreDefaults() {
        for action in ShortcutAction.all { defaults.removeObject(forKey: Self.key(action)) }
        changed()
    }

    /// Whether every shortcut is the one KeepNote comes with.
    var isAllDefault: Bool {
        ShortcutAction.all.allSatisfy { defaults.object(forKey: Self.key($0)) == nil }
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
    /// Why a combination cannot be had.
    enum Refusal: Equatable {
        case needsModifier
        /// Another KeepNote action has it: a changeable one or a fixed one
        /// (formatting, ⌘Q, ⌘W, the Edit menu…), named by its title.
        case usedBy(String)
        /// The system refused it: another app has it as a global shortcut.
        case inUseByAnotherApp

        var message: String {
            switch self {
            case .needsModifier: return L("Needs \u{2318}, \u{2325} or \u{2303}")
            case .usedBy(let title): return L("Used by %@", title)
            case .inUseByAnotherApp: return GlobalCommand.unavailableMessage
            }
        }
    }

    /// `nil` when `combo` can be given to `action`. `isAvailable` asks the
    /// system whether another app holds it; the global shortcuts are taken
    /// away while recording, so KeepNote's own never answer for it.
    static func refusal(of combo: KeyCombo, for action: ShortcutAction, store: ShortcutStore,
                        isAvailable: (KeyCombo) -> Bool) -> Refusal? {
        guard combo.hasRequiredModifier else { return .needsModifier }
        if let other = ShortcutAction.all.first(where: { $0 != action && store.combo(for: $0) == combo }) {
            return .usedBy(other.title)
        }
        if let fixed = fixedShortcuts.first(where: { $0.combo == combo }) {
            return .usedBy(fixed.title)
        }
        return isAvailable(combo) ? nil : .inUseByAnotherApp
    }

    /// Restore Defaults: KeepNote's own shortcuts back, registered again at
    /// once (the store's change does that).
    static func restoreDefaults(store: ShortcutStore, hotkeys: HotkeyService) {
        store.restoreDefaults()
    }

    static func record(_ combo: KeyCombo?, for action: ShortcutAction, store: ShortcutStore,
                       hotkeys: HotkeyService) -> ShortcutRecorderField.Outcome {
        guard let combo else {
            store.set(nil, for: action)
            return .accepted
        }
        if let refusal = refusal(of: combo, for: action, store: store, isAvailable: hotkeys.isAvailable) {
            return .refused(refusal.message)   // the field keeps the shortcut it had
        }
        store.set(combo, for: action)
        return .accepted
    }

    /// The shortcuts that cannot be changed, so cannot be taken either: the
    /// Format menu's, closing a note, and the app's menus.
    static var fixedShortcuts: [(combo: KeyCombo, title: String)] {
        let command = UInt32(cmdKey), option = UInt32(optionKey), shift = UInt32(shiftKey)
        func key(_ code: Int, _ modifiers: UInt32) -> KeyCombo { KeyCombo(keyCode: UInt32(code), carbonModifiers: modifiers) }
        var fixed: [(KeyCombo, String)] = FormatCommand.allCases.compactMap { format in
            KeyCombo.keyCode(forCharacter: format.key).map {
                (KeyCombo(keyCode: $0, carbonModifiers: KeyCombo.carbonFlags(from: format.modifiers)), format.title)
            }
        }
        fixed += [
            (key(kVK_ANSI_W, command), L("Close")),
            (key(kVK_Return, command), L("Tick or untick the task")),
            (key(kVK_ANSI_Q, command), L("Quit KeepNote")),
            (key(kVK_ANSI_Comma, command), L("Settings\u{2026}")),
            (key(kVK_ANSI_H, command), L("Hide KeepNote")),
            (key(kVK_ANSI_H, command | option), L("Hide Others")),
            (key(kVK_ANSI_M, command), L("Minimize")),
            (key(kVK_ANSI_N, command), L("New Note")),
            (key(kVK_ANSI_I, command), L("Import\u{2026}")),
            (key(kVK_ANSI_E, command), L("Export All\u{2026}")),
            (key(kVK_ANSI_Z, command), L("Undo")),
            (key(kVK_ANSI_Z, command | shift), L("Redo")),
            (key(kVK_ANSI_X, command), L("Cut")),
            (key(kVK_ANSI_C, command), L("Copy")),
            (key(kVK_ANSI_V, command), L("Paste")),
            (key(kVK_ANSI_A, command), L("Select All")),
        ]
        return fixed.map { (combo: $0.0, title: $0.1) }
    }
}
