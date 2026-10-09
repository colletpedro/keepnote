import CoreGraphics
import Foundation

/// Every user-visible preference, plus the few pieces of state the panels need
/// to rebuild themselves. Backed by `UserDefaults` inside the sandbox
/// container; nothing here is secret (the encryption key lives in the Keychain
/// and the sync folder is referenced by security-scoped bookmark).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let showOverFullScreen = "showOverFullScreen"
        static let syncEnabled = "syncEnabled"
        static let syncFolderBookmark = "syncFolderBookmark"
        static let fanStagger = "fanStaggerMilliseconds"
        static let autosaveDelay = "autosaveDelayMilliseconds"
        static let undoWindow = "undoWindowSeconds"
        static let defaultNoteColor = "defaultNoteColor"
        static let showInMenuBar = "showInMenuBar"
        static let detachedFrames = "detachedFrames"
        static let launchedBefore = "launchedBefore"
        static let seededFirstNote = "seededFirstNote"
        static let allNotesSelection = "allNotesSelection"
        static let floatingNotes = "floatingNotes"
        static let dailyIntroSeen = "dailyIntroSeen"
        static let archiveAfterDays = "archiveAfterDays"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showOverFullScreen: false,
            Key.showInMenuBar: true,
            Key.syncEnabled: false,
            Key.fanStagger: 45,
            Key.autosaveDelay: 250,
            Key.undoWindow: 10,
            Key.archiveAfterDays: AutoArchive.defaultDays,
        ])
        fanStagger = Double(defaults.integer(forKey: Key.fanStagger)) / 1000.0
        autosaveDelay = Double(defaults.integer(forKey: Key.autosaveDelay)) / 1000.0
        undoWindow = Double(defaults.integer(forKey: Key.undoWindow))
        archiveAfterDays = AutoArchive.normalized(defaults.integer(forKey: Key.archiveAfterDays))
        // "Show in Dock" is gone: the Dock icon now follows the open windows.
        defaults.removeObject(forKey: "showInDock")
        // "Cards before +N" is gone: each screen's height decides it.
        defaults.removeObject(forKey: "stackLimit")
        // No licence and no trial any more: their old keys go, once.
        LegacyDefaults.removeLicenseKeys(from: defaults)
        let storedColor = defaults.integer(forKey: Key.defaultNoteColor)
        defaultNoteColor = storedColor == 0 ? nil : NoteColor.resolve(rawValue: storedColor)
    }

    /// Raises the panel level to `.popUpMenu` and keeps `.fullScreenAuxiliary`
    /// honest, so the stack is reachable from a full-screen app.
    @Published var showOverFullScreen: Bool = UserDefaults.standard.bool(forKey: Key.showOverFullScreen) {
        didSet {
            defaults.set(showOverFullScreen, forKey: Key.showOverFullScreen)
            NotificationCenter.default.post(name: .keepNoteWindowBehaviorChanged, object: nil)
        }
    }

    /// The menu bar icon. On by default.
    @Published var showInMenuBar: Bool = UserDefaults.standard.object(forKey: Key.showInMenuBar) as? Bool ?? true {
        didSet {
            defaults.set(showInMenuBar, forKey: Key.showInMenuBar)
            NotificationCenter.default.post(name: .keepNotePresenceChanged, object: nil)
        }
    }

    /// Off by default. Turning it on is what asks for a folder.
    @Published var syncEnabled: Bool = UserDefaults.standard.bool(forKey: Key.syncEnabled) {
        didSet {
            defaults.set(syncEnabled, forKey: Key.syncEnabled)
            NotificationCenter.default.post(name: .keepNoteSyncSettingsChanged, object: nil)
        }
    }

    /// Security-scoped bookmark for the folder the user handed us through
    /// `NSOpenPanel`. Without this the sandbox forgets the grant on quit.
    var syncFolderBookmark: Data? {
        get { defaults.data(forKey: Key.syncFolderBookmark) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.syncFolderBookmark)
            } else {
                defaults.removeObject(forKey: Key.syncFolderBookmark)
            }
        }
    }


    /// Delay between consecutive cards during the fan animation.
    @Published var fanStagger: TimeInterval {
        didSet {
            defaults.set(Int((fanStagger * 1000).rounded()), forKey: Key.fanStagger)
            NotificationCenter.default.post(name: .keepNoteWindowBehaviorChanged, object: nil)
        }
    }

    /// Quiet period after the last keystroke before the body is sealed and written.
    @Published var autosaveDelay: TimeInterval {
        didSet { defaults.set(Int((autosaveDelay * 1000).rounded()), forKey: Key.autosaveDelay) }
    }

    /// How long a deleted note can still be brought back.
    @Published var undoWindow: TimeInterval {
        didSet { defaults.set(Int(undoWindow), forKey: Key.undoWindow) }
    }

    /// "Archive notes not opened for": 7, 14 or 30 days.
    @Published var archiveAfterDays: Int {
        didSet {
            let days = AutoArchive.normalized(archiveAfterDays)
            if days != archiveAfterDays { archiveAfterDays = days; return }
            defaults.set(days, forKey: Key.archiveAfterDays)
            NotificationCenter.default.post(name: .keepNoteArchiveSettingsChanged, object: nil)
        }
    }

    /// The colour a new note starts with. `nil` keeps the old behaviour: each
    /// new note takes the colour after the previous one.
    @Published var defaultNoteColor: NoteColor? {
        didSet { defaults.set(defaultNoteColor?.rawValue ?? 0, forKey: Key.defaultNoteColor) }
    }

    /// Where each lifted-off note was left, by note id: size and position are
    /// remembered per note. Stored as `FrameRestore` text in one dictionary.
    func detachedFrame(for id: UUID) -> CGRect? {
        let all = defaults.dictionary(forKey: Key.detachedFrames) as? [String: String]
        return all?[id.uuidString].flatMap(FrameRestore.decode)
    }

    /// `nil` forgets it, which is what happens when a note is purged.
    func setDetachedFrame(_ frame: CGRect?, for id: UUID) {
        var all = (defaults.dictionary(forKey: Key.detachedFrames) as? [String: String]) ?? [:]
        if let frame {
            all[id.uuidString] = FrameRestore.encode(frame)
        } else {
            all.removeValue(forKey: id.uuidString)
        }
        defaults.set(all, forKey: Key.detachedFrames)
    }

    /// What All Notes' sidebar had selected, as `NoteSelection.storageValue`.
    var allNotesSelection: String? {
        get { defaults.string(forKey: Key.allNotesSelection) }
        set { defaults.set(newValue, forKey: Key.allNotesSelection) }
    }

    /// Notes that were floating when the app last ran, in the order they were
    /// floated. They reopen floating, where they were left, at the next launch.
    var floatingNoteIDs: [UUID] {
        get { (defaults.stringArray(forKey: Key.floatingNotes) ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: Key.floatingNotes) }
    }

    func setFloating(_ floating: Bool, noteID: UUID) {
        var ids = floatingNoteIDs.filter { $0 != noteID }
        if floating { ids.append(noteID) }
        floatingNoteIDs = ids
    }

    /// "Got it" was pressed on the introduction at the top of the Daily list.
    var dailyIntroSeen: Bool {
        get { defaults.bool(forKey: Key.dailyIntroSeen) }
        set { defaults.set(newValue, forKey: Key.dailyIntroSeen) }
    }

    /// The welcome note was written. Separate from `hasLaunchedBefore`, which is
    /// set when the welcome window has been dismissed.
    var hasSeededFirstNote: Bool {
        get { defaults.bool(forKey: Key.seededFirstNote) }
        set { defaults.set(newValue, forKey: Key.seededFirstNote) }
    }

    /// The welcome window was dismissed ("Get Started" or closing it).
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.launchedBefore) }
        set { defaults.set(newValue, forKey: Key.launchedBefore) }
    }
}

extension Notification.Name {
    static let keepNoteWindowBehaviorChanged = Notification.Name("keepNote.windowBehaviorChanged")
    static let keepNotePresenceChanged = Notification.Name("keepNote.presenceChanged")
    static let keepNoteArchiveSettingsChanged = Notification.Name("keepNote.archiveSettingsChanged")
    static let keepNoteSyncSettingsChanged = Notification.Name("keepNote.syncSettingsChanged")
    static let keepNoteStoreChanged = Notification.Name("keepNote.storeChanged")
    /// Asks an open All Notes window to select something in its sidebar;
    /// `userInfo["selection"]` is a `NoteSelection.storageValue`.
    static let keepNoteShowNotesSelection = Notification.Name("keepNote.showNotesSelection")
}
