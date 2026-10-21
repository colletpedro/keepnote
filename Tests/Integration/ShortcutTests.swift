import AppKit
import Carbon.HIToolbox

/// Changeable shortcuts: which combinations are accepted, conflicts inside
/// KeepNote, the system's refusal, Restore Defaults, what is kept on this Mac,
/// and the recording field with what it tells VoiceOver.
@MainActor
func runShortcutTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    let command = UInt32(cmdKey), option = UInt32(optionKey), shift = UInt32(shiftKey), control = UInt32(controlKey)
    func combo(_ code: Int, _ modifiers: UInt32) -> KeyCombo { KeyCombo(keyCode: UInt32(code), carbonModifiers: modifiers) }
    func refusal(_ combo: KeyCombo, for action: ShortcutAction, available: Bool = true) -> String {
        ShortcutEditing.refusal(of: combo, for: action, store: store, isAvailable: { _ in available })?.message ?? "ok"
    }

    // Combinations.
    expect("valid: ⌥⌘J", refusal(combo(kVK_ANSI_J, command | option), for: .global(.newNote)), "ok")
    expect("valid: ⌃J alone is enough", refusal(combo(kVK_ANSI_J, control), for: .global(.newNote)), "ok")
    expect("valid: ⌥F5", refusal(combo(kVK_F5, option), for: .note(.find)), "ok")
    expect("invalid: a bare key", refusal(combo(kVK_ANSI_J, 0), for: .global(.newNote)), "Needs \u{2318}, \u{2325} or \u{2303}")
    expect("invalid: Shift alone is typing", refusal(combo(kVK_ANSI_J, shift), for: .global(.newNote)), "Needs \u{2318}, \u{2325} or \u{2303}")
    expect("display: ⌃⌥⇧⌘ order", combo(kVK_ANSI_J, command | option | shift | control).displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}J")
    expect("display: Delete", combo(kVK_Delete, command | shift).displayString, "\u{21E7}\u{2318}\u{232B}")
    expect("display: F-keys", combo(kVK_F12, option).displayString, "\u{2325}F12")
    expect("spoken", combo(kVK_ANSI_N, command | option).spokenString, "Option Command N")

    // Conflicts inside KeepNote.
    expect("conflict: another changeable action", refusal(combo(kVK_ANSI_F, command), for: .global(.newNote)), "Used by Find in note")
    expect("conflict: a global against a note command", refusal(combo(kVK_ANSI_P, command | option), for: .global(.archive)),
           "Used by Float Note \u{00B7} Return to Deck")
    expect("conflict: a note command against a global", refusal(combo(kVK_ANSI_N, command | option), for: .note(.find)), "Used by New Note")
    expect("conflict: formatting is fixed", refusal(combo(kVK_ANSI_B, command), for: .note(.find)), "Used by Bold")
    expect("conflict: and ⇧⌘7", refusal(combo(kVK_ANSI_7, command | shift), for: .note(.find)), "Used by Bulleted List")
    expect("conflict: ⌘Q", refusal(combo(kVK_ANSI_Q, command), for: .global(.newNote)), "Used by Quit KeepNote")
    expect("conflict: ⌘W", refusal(combo(kVK_ANSI_W, command), for: .note(.float)), "Used by Close")
    expect("no conflict with itself", refusal(combo(kVK_ANSI_F, command), for: .note(.find)), "ok")

    // The system's refusal: another app holds it.
    expect("refused by the system", refusal(combo(kVK_ANSI_J, command | option), for: .global(.newNote), available: false),
           "In use by another app")

    // Recording through a HotkeyService whose registrar refuses one combination.
    let held = combo(kVK_ANSI_K, command | option | control)
    let hotkeys = HotkeyService(registrar: { wanted, id in wanted == held ? nil : HotkeyService.carbonRegistrar(wanted, id) },
                                defaults: defaults)
    let editStore = hotkeys.store
    let before = editStore.combo(for: .global(.allNotes))
    expect("record: refused by the system, said why",
           "\(ShortcutEditing.record(held, for: .global(.allNotes), store: editStore, hotkeys: hotkeys))",
           "\(ShortcutRecorderField.Outcome.refused("In use by another app"))")
    expectTrue("record: and the shortcut it had is kept", editStore.combo(for: .global(.allNotes)) == before)
    let free = combo(kVK_ANSI_J, command | option | control)
    expect("record: a free one is taken",
           "\(ShortcutEditing.record(free, for: .global(.allNotes), store: editStore, hotkeys: hotkeys))", "accepted")
    expectTrue("record: and kept", editStore.combo(for: .global(.allNotes)) == free)
    _ = ShortcutEditing.record(nil, for: .global(.archive), store: editStore, hotkeys: hotkeys)
    expectTrue("record: Delete leaves it without one", editStore.combo(for: .global(.archive)) == nil)
    expect("record: shown as nothing", editStore.label(for: .global(.archive)) ?? "none", "none")
    expect("record: the tooltip without it", editStore.tooltip("Archive", .global(.archive)), "Archive")
    expect("record: a tooltip with one", editStore.tooltip("Float Note", .note(.float)), "Float Note (\u{2325}\u{2318}P)")

    // Kept on this Mac.
    let reopened = ShortcutStore(defaults: defaults)
    expectTrue("kept: a recorded shortcut", reopened.combo(for: .global(.allNotes)) == free)
    expectTrue("kept: no shortcut is kept as none", reopened.combo(for: .global(.archive)) == nil)
    expectTrue("kept: the others are the defaults", reopened.combo(for: .note(.find)) == NoteCommand.find.defaultCombo)
    expectTrue("kept: not all default now", !reopened.isAllDefault)

    // Restore Defaults.
    var told = 0
    let observer = NotificationCenter.default.addObserver(forName: .keepNoteShortcutsChanged, object: editStore, queue: nil) { _ in told += 1 }
    ShortcutEditing.restoreDefaults(store: editStore, hotkeys: hotkeys)
    NotificationCenter.default.removeObserver(observer)
    expectTrue("restore: every shortcut is the default again",
               ShortcutAction.all.allSatisfy { editStore.combo(for: $0) == $0.defaultCombo })
    expectTrue("restore: and none is left without one", ShortcutAction.all.allSatisfy { editStore.combo(for: $0) != nil })
    expectTrue("restore: all default", editStore.isAllDefault)
    expect("restore: menus and registrations are told", String(told), "1")
    expectTrue("restore: and it is kept", ShortcutStore(defaults: defaults).isAllDefault)
    expectTrue("defaults: no two actions share one",
               Set(ShortcutAction.all.map { $0.defaultCombo.storageValue }).count == ShortcutAction.all.count)
    expectTrue("defaults: none clashes with a fixed one",
               ShortcutAction.all.allSatisfy { action in !ShortcutEditing.fixedShortcuts.contains { $0.combo == action.defaultCombo } })

    // The old way global shortcuts were kept is read once, then dropped.
    let legacySuite = "keepnote-tests-\(UUID().uuidString)"
    let legacy = UserDefaults(suiteName: legacySuite)!
    defer { legacy.removePersistentDomain(forName: legacySuite) }
    legacy.set(try! JSONEncoder().encode(free), forKey: "hotkey.newNote")
    let migrated = ShortcutStore(defaults: legacy)
    expectTrue("legacy: an old recorded shortcut is kept", migrated.combo(for: .global(.newNote)) == free)
    expectTrue("legacy: and the old key is gone", legacy.object(forKey: "hotkey.newNote") == nil)

    // In a note: an event finds its command by the shortcut set now.
    func key(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
    }
    expect("note: ⌘F finds", editStore.noteCommand(for: key(kVK_ANSI_F, .command, "f"))?.rawValue, "find")
    expect("note: ⇧⌘G goes back", editStore.noteCommand(for: key(kVK_ANSI_G, [.command, .shift], "g"))?.rawValue, "findPrevious")
    expect("note: ⇧⌘⌫ deletes", editStore.noteCommand(for: key(kVK_Delete, [.command, .shift]))?.rawValue, "delete")
    expect("note: Caps Lock does not count", editStore.noteCommand(for: key(kVK_ANSI_F, [.command, .capsLock], "f"))?.rawValue, "find")
    editStore.set(combo(kVK_ANSI_L, command | control), for: .note(.find))
    expect("note: the new shortcut finds", editStore.noteCommand(for: key(kVK_ANSI_L, [.command, .control], "l"))?.rawValue, "find")
    expectTrue("note: and the old one no longer does", editStore.noteCommand(for: key(kVK_ANSI_F, .command, "f")) == nil)
    editStore.restoreDefaults()

    // The recording field, driven by key presses.
    let field = ShortcutRecorderField(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
    field.actionTitle = "New Note"
    field.combo = editStore.combo(for: .global(.newNote))
    field.onRecord = { ShortcutEditing.record($0, for: .global(.newNote), store: editStore, hotkeys: hotkeys) }
    expect("field: shows the shortcut", field.textForTesting, "\u{2325}\u{2318}N")
    expect("field: VoiceOver hears what it is", field.accessibilityLabel(), "Shortcut for New Note")
    expect("field: and the shortcut, spoken", field.accessibilityValue() as? String, "Option Command N")
    field.startRecording()
    expect("field: asks for the combination", field.textForTesting, "Type a shortcut")
    expect("field: and says so", ShortcutRecorderField.lastAnnouncement,
           "Press the new shortcut for New Note. Escape cancels, Delete leaves it without one.")
    expectTrue("field: the app's keys stand aside while recording", ShortcutRecorderField.isRecordingAny)
    field.recordForTesting(key(kVK_Escape, []))
    expect("field: Esc cancels", field.textForTesting, "\u{2325}\u{2318}N")
    expectTrue("field: nothing changed", editStore.combo(for: .global(.newNote)) == GlobalCommand.newNote.defaultCombo)
    expectTrue("field: no longer recording", !ShortcutRecorderField.isRecordingAny)
    field.recordForTesting(key(kVK_ANSI_J, .shift, "J"))
    expect("field: Shift alone is refused, and says why", field.textForTesting, "Needs \u{2318}, \u{2325} or \u{2303}")
    expect("field: VoiceOver hears why and what is kept", ShortcutRecorderField.lastAnnouncement,
           "Needs \u{2318}, \u{2325} or \u{2303}. New Note keeps Option Command N")
    expectTrue("field: the shortcut it had is kept", field.combo == GlobalCommand.newNote.defaultCombo)
    field.recordForTesting(key(kVK_ANSI_F, .command, "f"))
    expect("field: a conflict is refused", field.messageForTesting, "Used by Find in note")
    field.recordForTesting(key(kVK_ANSI_J, [.command, .option, .control], "j"))
    expect("field: a free one is set", field.combo?.displayString, "\u{2303}\u{2325}\u{2318}J")
    expect("field: and announced", ShortcutRecorderField.lastAnnouncement, "New Note set to Control Option Command J")
    expectTrue("field: in the store", editStore.combo(for: .global(.newNote)) == combo(kVK_ANSI_J, command | option | control))
    field.recordForTesting(key(kVK_Delete, []))
    expectTrue("field: Delete clears it", field.combo == nil && editStore.combo(for: .global(.newNote)) == nil)
    expect("field: shown as None", field.textForTesting, "None")
    expect("field: announced", ShortcutRecorderField.lastAnnouncement, "New Note now has no shortcut")
    editStore.restoreDefaults()
    hotkeys.register([:])
}
