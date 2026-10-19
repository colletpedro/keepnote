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
        if let special = KeyCombo.menuSpecials[Int(keyCode)] { return special }
        return KeyCombo.keyName(for: keyCode).lowercased()
    }

    /// Keys whose menu equivalent is not the character they are drawn with.
    private static let menuSpecials: [Int: String] = {
        var keys: [Int: String] = [
            kVK_Delete: "\u{8}", kVK_ForwardDelete: "\u{7F}", kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ",
            kVK_Escape: "\u{1B}",
            kVK_LeftArrow: String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!),
            kVK_RightArrow: String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!),
            kVK_UpArrow: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!),
            kVK_DownArrow: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!),
            kVK_Home: String(UnicodeScalar(UInt16(NSHomeFunctionKey))!),
            kVK_End: String(UnicodeScalar(UInt16(NSEndFunctionKey))!),
            kVK_PageUp: String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!),
            kVK_PageDown: String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!),
        ]
        for (index, code) in functionKeys.enumerated() {
            keys[code] = String(UnicodeScalar(UInt16(NSF1FunctionKey + index))!)
        }
        return keys
    }()

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// The key pressed in `event`, with the modifiers that count for a
    /// shortcut (Caps Lock and Fn do not).
    init(event: NSEvent) {
        self.init(keyCode: Int(event.keyCode),
                  modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]))
    }

    /// Whether `event` is this combination.
    func matches(_ event: NSEvent) -> Bool {
        KeyCombo(event: event) == self
    }

    /// A shortcut needs ⌘, ⌥ or ⌃: Shift alone, or nothing, is typing.
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// How a combination is kept in the preferences: "45:2304".
    var storageValue: String { "\(keyCode):\(carbonModifiers)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], carbonModifiers: parts[1])
    }

    /// The key code for a character typed on a US layout, for the fixed
    /// shortcuts that are written as characters (the Format menu's).
    static func keyCode(forCharacter character: String) -> UInt32? {
        let wanted = character.uppercased()
        for code in 0..<128 where keyName(for: UInt32(code)) == wanted { return UInt32(code) }
        return nil
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
        case kVK_Space: return L("Space")
        case kVK_Return: return "\u{21A9}"
        case kVK_Escape: return "\u{238B}"
        case kVK_Delete: return "\u{232B}"
        case kVK_ForwardDelete: return "\u{2326}"
        case kVK_Tab: return "\u{21E5}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_Home: return "\u{2196}"
        case kVK_End: return "\u{2198}"
        case kVK_PageUp: return "\u{21DE}"
        case kVK_PageDown: return "\u{21DF}"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        default:
            if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
            return "?"
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

    /// Beside a shortcut that could not be registered.
    static var unavailableMessage: String { L("In use by another app") }

    var title: String {
        switch self {
        case .newNote: return L("New Note")
        case .allNotes: return L("All Notes")
        case .archive: return L("[noun] Archive")
        case .todaysDaily: return L("Today\u{2019}s Daily")
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
