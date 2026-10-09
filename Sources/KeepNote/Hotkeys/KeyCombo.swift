import AppKit
import Carbon.HIToolbox

/// A hotkey as the user sees it, and as Carbon wants it.
///
/// Carbon uses its own modifier bit mask (`cmdKey`, `optionKey`, …) rather than
/// `NSEvent.ModifierFlags`, so the translation lives here.
struct KeyCombo: Equatable, Codable, Sendable {
    /// Virtual key code, e.g. `kVK_ANSI_N`.
    var keyCode: UInt32
    /// Carbon modifier mask.
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = KeyCombo.carbonFlags(from: modifiers)
    }

    static func carbonFlags(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// "⌥⌘N" — for menu items and the settings window.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "\u{2303}" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "\u{2325}" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "\u{21E7}" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "\u{2318}" }
        result += KeyCombo.keyName(for: keyCode)
        return result
    }

    /// The character a menu item needs for its key equivalent.
    var menuKeyEquivalent: String {
        KeyCombo.keyName(for: keyCode).lowercased()
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "\u{21A9}"
        case kVK_Escape: return "\u{238B}"
        default: return "?"
        }
    }
}

/// The global commands. Kept as an enum so the settings
/// window, the menu and the registration loop all agree on the list.
enum GlobalCommand: String, CaseIterable, Identifiable, Sendable {
    case newNote
    case allNotes
    case archive
    case todaysDaily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newNote: return "New Note"
        case .allNotes: return "All Notes"
        case .archive: return "Archive"
        case .todaysDaily: return "Today\u{2019}s Daily"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .newNote:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(cmdKey | optionKey))
        case .allNotes:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | optionKey))
        case .archive:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(cmdKey | optionKey))
        case .todaysDaily:
            // Not \u{2325}\u{2318}D, which is the Dock's, nor \u{2325}\u{2318}T, which inserts a table in a note.
            return KeyCombo(keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(cmdKey | optionKey))
        }
    }
}
