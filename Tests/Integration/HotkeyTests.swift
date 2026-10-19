import AppKit
import Carbon.HIToolbox

/// A global shortcut that cannot be registered: Settings marks it and the menu
/// item loses it. Unusual combinations, so the tests never collide with the
/// running app or anything else on this Mac.
@MainActor
func runHotkeyConflictTests() {
    let suite = "keepnote.tests.hotkeys"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let hyper = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    let combos: [GlobalCommand: KeyCombo] = [
        .newNote: KeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: hyper),
        .allNotes: KeyCombo(keyCode: UInt32(kVK_F14), carbonModifiers: hyper),
        .archive: KeyCombo(keyCode: UInt32(kVK_F15), carbonModifiers: hyper),
        .todaysDaily: KeyCombo(keyCode: UInt32(kVK_F16), carbonModifiers: hyper),
    ]
    let actions: [GlobalCommand: () -> Void] = Dictionary(uniqueKeysWithValues: GlobalCommand.allCases.map { ($0, {}) })

    // A registrar that refuses New Note's combination, the way the window
    // server refuses one another app holds.
    let refusing = HotkeyService(registrar: { combo, id in
        combo == combos[.newNote] ? nil : HotkeyService.carbonRegistrar(combo, id)
    }, defaults: defaults)
    for (command, combo) in combos { refusing.setCombo(combo, for: command) }
    refusing.register(actions)

    expect("hotkeys: the refused one is unavailable", String(refusing.isUnavailable(.newNote)), "true")
    expect("hotkeys: the others are not",
           GlobalCommand.allCases.filter { refusing.isUnavailable($0) }.map(\.rawValue).joined(separator: ","), "newNote")
    expectTrue("hotkeys: the menu shows no combination for it", refusing.menuCombo(for: .newNote) == nil)
    expectTrue("hotkeys: and the stored one is kept, for Settings to show", refusing.combo(for: .newNote) == combos[.newNote])
    expect("hotkeys: the warning", GlobalCommand.unavailableMessage, "In use by another app")

    let item = NSMenuItem(title: "New Note", action: nil, keyEquivalent: "n")
    refusing.applyShortcut(for: .newNote, to: item)
    expect("hotkeys: the menu item has no shortcut", item.keyEquivalent, "")
    let working = NSMenuItem(title: "All Notes", action: nil, keyEquivalent: "")
    refusing.applyShortcut(for: .allNotes, to: working)
    expect("hotkeys: a registered one is shown in the menu", working.keyEquivalent, combos[.allNotes]!.menuKeyEquivalent)
    expectTrue("hotkeys: with its modifiers",
               working.keyEquivalentModifierMask == [.command, .option, .control, .shift])

    var notified = false
    let observer = NotificationCenter.default.addObserver(forName: .keepNoteHotkeysChanged, object: refusing, queue: nil) { _ in
        notified = true
    }
    // Choosing another combination that works clears the warning.
    let freed = KeyCombo(keyCode: UInt32(kVK_F17), carbonModifiers: hyper)
    refusing.setCombo(freed, for: .newNote)
    NotificationCenter.default.removeObserver(observer)
    expect("hotkeys: a combination that works clears it", String(refusing.isUnavailable(.newNote)), "false")
    expectTrue("hotkeys: and the menus are told to rebuild", notified)
    refusing.register([:])

    // A real refusal from the window server: the combination is already held.
    let held = combos[.archive]!
    guard let holder = HotkeyService.carbonRegistrar(held, EventHotKeyID(signature: 0x54455354, id: 1)) else {
        expectTrue("hotkeys: the test could hold its combination", false)
        return
    }
    defer { UnregisterEventHotKey(holder) }
    let real = HotkeyService(defaults: defaults)
    real.register(actions)
    expect("hotkeys: a combination already held is unavailable", String(real.isUnavailable(.archive)), "true")
    expect("hotkeys: only that one",
           GlobalCommand.allCases.filter { real.isUnavailable($0) }.map(\.rawValue).joined(separator: ","), "archive")
    expectTrue("hotkeys: isAvailable agrees", !real.isAvailable(held))
    real.register([:])
}
