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
final class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    /// Claims one combination from the window server; `nil` when another app
    /// already holds it. Replaced in the tests to make a registration fail.
    typealias Registrar = (_ combo: KeyCombo, _ id: EventHotKeyID) -> EventHotKeyRef?

    static let carbonRegistrar: Registrar = { combo, id in
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

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

    private let registrar: Registrar
    /// Where the combinations are kept, global and in-note alike.
    let store: ShortcutStore
    private var storeObserver: NSObjectProtocol?
    /// While a shortcut is being recorded nothing is registered, so the
    /// combination pressed reaches the recorder instead of its command.
    private(set) var isSuspended = false

    /// The commands whose combination could not be registered, because another
    /// app holds it. Settings marks them and the menus show them without it.
    @Published private(set) var unavailable: Set<GlobalCommand> = []

    init(registrar: Registrar? = nil, defaults: UserDefaults = .standard) {
        self.registrar = registrar ?? Self.carbonRegistrar
        self.store = defaults == .standard ? ShortcutStore.shared : ShortcutStore(defaults: defaults)
        storeObserver = NotificationCenter.default.addObserver(
            forName: .keepNoteShortcutsChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSuspended else { return }
                self.reregister()
            }
        }
    }

    func isUnavailable(_ command: GlobalCommand) -> Bool { unavailable.contains(command) }

    /// The combination to show beside the command in a menu: none when it is
    /// not actually registered, so the menu never promises a shortcut that
    /// another app will receive.
    func menuCombo(for command: GlobalCommand) -> KeyCombo? {
        isUnavailable(command) ? nil : combo(for: command)
    }

    /// A menu item for a global command, its shortcut shown when it works.
    func applyShortcut(for command: GlobalCommand, to item: NSMenuItem) {
        if let combo = menuCombo(for: command) {
            item.keyEquivalent = combo.menuKeyEquivalent
            item.keyEquivalentModifierMask = combo.modifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Stored combos

    /// The combination for `command`; `nil` when it has none.
    func combo(for command: GlobalCommand) -> KeyCombo? {
        store.combo(for: .global(command))
    }

    /// "⌥⌘N", or "" when the command has no shortcut.
    func label(for command: GlobalCommand) -> String {
        combo(for: command)?.displayString ?? ""
    }

    func setCombo(_ combo: KeyCombo?, for command: GlobalCommand) {
        store.set(combo, for: .global(command))
        if isSuspended { return }
        reregister()
    }

    // MARK: - Recording

    /// Takes every global shortcut away while one is being recorded.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        reregister()
    }

    // MARK: - Registration

    private var actions: [GlobalCommand: () -> Void] = [:]

    /// Called once at launch with the app's three entry points.
    func register(_ actions: [GlobalCommand: () -> Void]) {
        self.actions = actions
        installEventHandlerIfNeeded()
        reregister()
    }

    private func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func reregister() {
        unregisterAll()
        var failed: Set<GlobalCommand> = []
        for command in GlobalCommand.allCases {
            guard let handler = actions[command], let combo = combo(for: command) else { continue }
            if !register(combo, command: command, handler: handler) { failed.insert(command) }
        }
        unavailable = failed
        NotificationCenter.default.post(name: .keepNoteHotkeysChanged, object: self)
    }

    @discardableResult
    private func register(_ combo: KeyCombo, command: GlobalCommand, handler: @escaping () -> Void) -> Bool {
        let identifier = nextIdentifier
        nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        // A combination another app already owns comes back as an error. That
        // is not fatal: the other shortcuts still work, Settings shows the
        // conflict and the menus leave that shortcut off.
        guard let ref = registrar(combo, hotKeyID) else { return false }
        registrations[identifier] = Registration(command: command, ref: ref, handler: handler)
        return true
    }

    /// Whether the combination could be claimed. Used by Settings to warn
    /// about a conflict before storing it.
    func isAvailable(_ combo: KeyCombo) -> Bool {
        let hotKeyID = EventHotKeyID(signature: signature, id: 0xFFFF)
        guard let ref = registrar(combo, hotKeyID) else { return false }
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

extension Notification.Name {
    /// The global shortcuts were registered again; `unavailable` may differ.
    static let keepNoteHotkeysChanged = Notification.Name("keepNote.hotkeysChanged")
}
