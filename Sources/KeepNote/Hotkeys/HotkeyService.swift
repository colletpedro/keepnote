import AppKit
import Carbon.HIToolbox

/// Registers the global shortcuts.
///
/// This is the Carbon `RegisterEventHotKey` path on purpose.
/// `NSEvent.addGlobalMonitorForEvents` would see keystrokes aimed at other
/// apps, which macOS gates behind Accessibility or Input Monitoring — a
/// permission prompt the app promises never to show. `RegisterEventHotKey`
/// asks the window server to deliver one specific combination to us and
/// nothing else, so it needs no permission at all.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    private struct Registration {
        let command: GlobalCommand
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1

    /// Four-char code identifying our hotkeys in the Carbon event stream.
    private let signature: OSType = 0x484D_4E54 // 'HMNT'

    private init() {}

    deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Stored combos

    func combo(for command: GlobalCommand) -> KeyCombo {
        let defaults = UserDefaults.standard
        guard
            let data = defaults.data(forKey: Self.defaultsKey(command)),
            let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        else {
            return command.defaultCombo
        }
        return combo
    }

    func setCombo(_ combo: KeyCombo?, for command: GlobalCommand) {
        let defaults = UserDefaults.standard
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: Self.defaultsKey(command))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(command))
        }
        reregister()
    }

    private static func defaultsKey(_ command: GlobalCommand) -> String {
        "hotkey.\(command.rawValue)"
    }

    // MARK: - Registration

    private var actions: [GlobalCommand: () -> Void] = [:]

    /// Called once at launch with the app's three entry points.
    func register(_ actions: [GlobalCommand: () -> Void]) {
        self.actions = actions
        installEventHandlerIfNeeded()
        reregister()
    }

    private func reregister() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()

        for command in GlobalCommand.allCases {
            guard let handler = actions[command] else { continue }
            let combo = combo(for: command)
            register(combo, command: command, handler: handler)
        }
    }

    @discardableResult
    private func register(_ combo: KeyCombo, command: GlobalCommand, handler: @escaping () -> Void) -> Bool {
        let identifier = nextIdentifier
        nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // A combination another app already owns comes back as an error. That
        // is not fatal: the other two shortcuts still work and Settings shows
        // the conflict.
        guard status == noErr, let ref else { return false }
        registrations[identifier] = Registration(command: command, ref: ref, handler: handler)
        return true
    }

    /// Whether the combination could be claimed. Used by Settings to warn
    /// about a conflict before storing it.
    func isAvailable(_ combo: KeyCombo) -> Bool {
        let hotKeyID = EventHotKeyID(signature: signature, id: 0xFFFF)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
            let identifier = hotKeyID.id
            Task { @MainActor in
                service.handle(identifier: identifier)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    fileprivate func handle(identifier: UInt32) {
        registrations[identifier]?.handler()
    }
}
