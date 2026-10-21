import AppKit
import SwiftUI

/// The Settings panes. Hosted one per tab by `SettingsWindowController`;
/// deliberately short, because most of the app has no options — most of it has
/// no modes.

enum SettingsTab: Int, CaseIterable {
    case general, notes, deck, daily, sync, shortcuts, about

    var title: String {
        switch self {
        case .general: return L("General")
        case .notes: return L("Notes")
        case .deck: return L("Deck")
        case .daily: return L("Daily")
        case .sync: return L("Sync")
        case .shortcuts: return L("Shortcuts")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notes: return "note.text"
        case .deck: return "rectangle.stack"
        case .daily: return "calendar"
        case .sync: return "arrow.triangle.2.circlepath"
        case .shortcuts: return "command"
        case .about: return "info.circle"
        }
    }

    /// Each pane is a fixed size; the window animates between them.
    var paneHeight: CGFloat {
        switch self {
        case .general: return 600
        case .notes: return 270
        case .deck: return 370
        case .daily: return 330
        case .sync: return 430
        case .shortcuts: return 740
        case .about: return 424
        }
    }
}

/// What the panes ask the app to do, kept as closures so the views never reach
/// for a panel or a window themselves.
struct SettingsActions {
    var chooseSyncFolder: () -> Void
    var forgetSyncFolder: () -> Void
    var importNotes: () -> Void
    var exportAll: () -> Void
    var showWelcome: () -> Void
    var editDailyTemplate: () -> Void = {}
    /// Quits and starts KeepNote again, for a new language.
    var relaunch: () -> Void = {}
    /// Back Up Now and Restore…, in General.
    var backUpNow: () -> Void = {}
    var restoreBackup: () -> Void = {}
}

/// An option with its explanation underneath, the way System Settings does it.
private struct Option<Control: View>: View {
    let help: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct HelpNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings
    var actions: SettingsActions
    /// The notes' database, for the Backups section.
    var store: NoteStore?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Option(help: loginHelp) {
                    Toggle(L("Launch at login"), isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                }
                if LaunchAtLogin.needsApproval {
                    Button(L("Open Login Items\u{2026}")) { LaunchAtLogin.openLoginItemsSettings() }
                }
            }

            Section {
                Option(help: L("The language of KeepNote\u{2019}s menus, windows and notes it writes, such as dates and weekdays. System follows the language of this Mac.")) {
                    Picker(L("Language"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                }
                if settings.language != Localization.launchChoice {
                    relaunchRow
                }
                Option(help: L("The size of the text in notes, the peek and All Notes, titles included.")) {
                    Picker(L("Text size"), selection: $settings.textSize) {
                        ForEach(TextSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                }
            }

            Section {
                Option(help: L("The note icon at the right of the menu bar, with New Note, All Notes, Settings and Quit.")) {
                    Toggle(L("Show in menu bar"), isOn: $settings.showInMenuBar)
                }
                Option(help: L("Raises the deck above full-screen windows. Stage Manager leaves it alone either way, because a floating panel is not part of an app\u{2019}s window set.")) {
                    Toggle(L("Show over full-screen apps"), isOn: $settings.showOverFullScreen)
                }
                HelpNote(text: L("KeepNote is in the Dock, with its full menu bar, while one of its windows is open \u{2014} All Notes, Archive, Settings, About or Welcome. When the last one closes it leaves the Dock; the deck, your notes and the menu bar icon stay."))
            }

            if let store {
                BackupsSection(store: store, actions: actions)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    /// Said in the language just chosen, since that is the one being asked for.
    private var relaunchRow: some View {
        let target = Localization.resolved(settings.language)
        return HStack(spacing: 10) {
            Text(L("KeepNote switches language when it opens again.", in: target))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("Relaunch Now", in: target), action: actions.relaunch)
        }
    }

    private var loginHelp: String {
        if let loginError { return loginError }
        if LaunchAtLogin.needsApproval {
            return L("Waiting for your approval in System Settings > General > Login Items.")
        }
        return L("Opens KeepNote when you log in, so the deck is always there.")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = L("Could not change this: %@", error.localizedDescription)
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

/// Backups: when the last copy was made, Back Up Now and Restore….
private struct BackupsSection: View {
    @ObservedObject var store: NoteStore
    var actions: SettingsActions

    var body: some View {
        Section {
            Option(help: L("Each day KeepNote keeps a copy of your notes on this Mac, sealed like the notes themselves, and the seven most recent. One is also made before an update changes how notes are stored.")) {
                LabeledContent(L("Backups")) {
                    Text(lastLine)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent(L("Space used")) {
                Text(spaceLine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Leading, like the buttons of the other panes.
            HStack(spacing: 8) {
                Button(L("Back Up Now"), action: actions.backUpNow)
                Button(L("Restore\u{2026}"), action: actions.restoreBackup)
                    .disabled(store.lastBackup == nil)
                Spacer(minLength: 0)
            }
        }
    }

    /// "3 backups · 1.2 MB".
    private var spaceLine: String {
        let summary = store.backupSummary
        let size = Lbytes(summary.bytes)
        return L("%@ \u{00B7} %@", Lplural(summary.count, L("1 backup"), L("%d backups")), size)
    }

    private var lastLine: String {
        guard let last = store.lastBackup else { return L("No backup yet") }
        return L("Last: %@", Self.formatter.string(from: last.date))
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()
}

// MARK: - Notes

struct NotesSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Option(help: L("The color a new note starts with. Automatic takes the color after the previous note\u{2019}s. You can still change it inside the note.")) {
                    Picker(L("Default color"), selection: $settings.defaultNoteColor) {
                        Text(L("Automatic")).tag(NoteColor?.none)
                        Divider()
                        ForEach(NoteColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(NoteColor?.some(color))
                        }
                    }
                }
            }

            Section {
                Option(help: L("How long to wait after you stop typing before the note is written. Applies to notes opened from now on.")) {
                    LabeledContent(L("Autosave after")) {
                        stepper(
                            "\(Int(settings.autosaveDelay * 1000)) ms",
                            value: Binding(
                                get: { Int(settings.autosaveDelay * 1000) },
                                set: { settings.autosaveDelay = Double($0) / 1000 }
                            ),
                            in: 100...2000, step: 50, named: L("Autosave after")
                        )
                    }
                }
                Option(help: L("A deleted note waits this long, with an Undo button, before it is gone for good.")) {
                    LabeledContent(L("Undo a delete for")) {
                        stepper(
                            "\(Int(settings.undoWindow)) s",
                            value: Binding(
                                get: { Int(settings.undoWindow) },
                                set: { settings.undoWindow = Double($0) }
                            ),
                            in: 3...60, step: 1, named: L("Undo a delete for")
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The value and its stepper. VoiceOver hears the setting's name on the
/// stepper and the value as its value.
private func stepper(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int, named name: String) -> some View {
    HStack(spacing: 6) {
        Text(label).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityHidden(true)
        Stepper(name, value: value, in: range, step: step).labelsHidden()
            .accessibilityLabel(name)
            .accessibilityValue(label)
    }
}

// MARK: - Daily

struct DailySettingsPane: View {
    var actions: SettingsActions
    @ObservedObject var settings: AppSettings = .shared
    @ObservedObject var shortcuts: ShortcutStore = .shared

    /// Names the Today's Daily shortcut as it is set now.
    private var templateHelp: String {
        if let keys = shortcuts.label(for: .global(.todaysDaily)) {
            return L("The template is used only when a new daily note is created: from the calendar button on the deck, %@ or the menu. Adding the daily tag to a note you already have never changes its text.", keys)
        }
        return L("The template is used only when a new daily note is created: from the calendar button on the deck or the menu. Adding the daily tag to a note you already have never changes its text.")
    }

    var body: some View {
        Form {
            Section {
                Option(help: L("New daily notes start from this text instead of a blank page. It is not a note: it stays out of the deck, the lists and search, and it syncs and exports with your notes.")) {
                    Button(L("Edit Daily Template\u{2026}"), action: actions.editDailyTemplate)
                }
                HelpNote(text: DailyTemplateText.variablesHelp)
                HelpNote(text: templateHelp)
            }

            Section {
                Option(help: L("When a new daily note is made, the checklist items left unticked in the dailies of the last day before it. Ask each time offers them at the top of the new note; they go at its end, under the day they came from. The earlier daily is never changed.")) {
                    Picker(L("Unfinished tasks from your last daily"), selection: $settings.carryOverMode) {
                        ForEach(CarryOverMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Deck

struct DeckSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Option(help: L("The side of the screen the deck lives on, on every display. Notes, peeks and the drag back into the deck follow it.")) {
                    // At the trailing edge, where every other control sits.
                    LabeledContent(L("Screen edge")) {
                        Picker(L("Screen edge"), selection: $settings.screenEdge) {
                            ForEach(ScreenEdge.allCases, id: \.self) { edge in
                                Text(edge.title).tag(edge)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Section {
                Option(help: L("How long the cursor rests on the stripe before the deck opens. Arriving slowly opens it at once; crossing the edge quickly, on the way to another display, does not. Zero opens it on contact.")) {
                    LabeledContent(L("Open delay")) {
                        stepper(
                            "\(Int((settings.openDelay * 1000).rounded())) ms",
                            value: Binding(
                                get: { Int((settings.openDelay * 1000).rounded()) },
                                set: { settings.openDelay = Double($0) / 1000 }
                            ),
                            in: 0...400, step: 25, named: L("Open delay")
                        )
                    }
                }
                Option(help: L("The pause between one card sliding out and the next. Zero opens them all at once.")) {
                    LabeledContent(L("Cascade delay")) {
                        stepper(
                            "\(Int(settings.fanStagger * 1000)) ms",
                            value: Binding(
                                get: { Int(settings.fanStagger * 1000) },
                                set: { settings.fanStagger = Double($0) / 1000 }
                            ),
                            in: 0...120, step: 5, named: L("Cascade delay")
                        )
                    }
                }
            }

            Section {
                Option(help: L("A note you have not opened for this long is moved to the Archive, never deleted. Opening a note, docked or floating, starts its time again; a quick look from the deck does not. Notes kept on the deck, pinned notes, open notes and daily notes are never archived this way.")) {
                    Picker(L("Archive notes not opened for"), selection: $settings.archiveAfterDays) {
                        ForEach(AutoArchive.choices, id: \.self) { days in
                            Text(L("%d days", days)).tag(days)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sync

struct SyncSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var sync: FolderSyncService
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                Option(help: L("Writes one plain-text file per note into a folder you choose. Turning it on asks for that folder.")) {
                    Toggle(L("Sync notes through a folder"), isOn: $settings.syncEnabled)
                }
                LabeledContent(L("Status")) {
                    Text(sync.status.summary).foregroundStyle(statusColor)
                }
                LabeledContent(L("Folder")) {
                    Text(sync.folderDisplayName ?? L("None chosen")).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Choose Folder\u{2026}"), action: actions.chooseSyncFolder)
                    Button(L("Forget Folder"), action: actions.forgetSyncFolder)
                        .disabled(sync.folderDisplayName == nil)
                }
            }

            Section {
                HelpNote(text: L("One plain-text file per note, written where you choose \u{2014} iCloud Drive by default, with the notes\u{2019} images and files as plain copies in its Attachments folder. The folder\u{2019}s own provider moves them between Macs; KeepNote has no server and uses no CloudKit."))
                HelpNote(text: L("Files in that folder are readable without the app. The database on this Mac keeps note bodies encrypted, and that key never leaves this Mac \u{2014} which is why it cannot travel with the files."))
            }

            Section {
                Option(help: L("Reads notes, or a KeepNote archive, from files on this Mac.")) {
                    Button(L("Import Notes\u{2026}"), action: actions.importNotes)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusColor: Color {
        switch sync.status {
        case .active: return .green
        case .failed: return .red
        case .needsFolder: return .orange
        case .off: return .secondary
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPane: View {
    @ObservedObject var hotkeys: HotkeyService = .shared
    @ObservedObject var store: ShortcutStore = .shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    HelpNote(text: L("Shortcuts are kept on this Mac. Menus, tooltips and the welcome window always show the ones set here."))
                    Spacer(minLength: 8)
                    Button(L("Restore Defaults")) { ShortcutEditing.restoreDefaults(store: store, hotkeys: hotkeys) }
                        .disabled(store.isAllDefault)
                }
            }

            Section(L("Global")) {
                ForEach(GlobalCommand.allCases) { command in
                    globalRow(command)
                }
                HelpNote(text: L("Click a shortcut and press the new combination; it needs \u{2318}, \u{2325} or \u{2303}. Esc cancels, Delete leaves the command without one."))
                HelpNote(text: L("Registered through the system\u{2019}s hotkey API, which delivers only these combinations to KeepNote. No Accessibility or Input Monitoring permission is involved."))
            }

            Section(L("Daily notes")) {
                row(L("Today\u{2019}s Daily, from the deck"), L("the calendar button beside +"))
                row(L("Earlier dailies"), L("click the daily chip in a note"))
                HelpNote(text: L("Today\u{2019}s Daily opens the latest daily of today, or makes one titled with the day and month. Any note becomes a daily when it has the daily tag, as many as you like per day. The dailies of your two most recent days stay on the deck; older ones are archived (never deleted) and kept under Daily in All Notes. One you bring back to the deck yourself stays there."))
            }

            Section(L("Pinned and kept notes")) {
                row(L("Pin to Center"), L("the pin in a note\u{2019}s header \u{00B7} Tools \u{00B7} right-click a tab \u{00B7} All Notes"))
                row(L("Keep on Deck"), L("Tools \u{00B7} right-click a tab \u{00B7} All Notes"))
                HelpNote(text: L("Up to five notes can be pinned. They stay in the middle of the deck\u{2019}s height, always whole and never overlapped: the first pinned in the middle, the second above it, the third below, the fourth above and the fifth below. Pinning also turns on Keep on Deck; unpinning leaves it on. A kept or pinned note is never archived by the time rule."))
                HelpNote(text: L("Notes not opened for the time set under Deck (7, 14 or 30 days; 14 by default) are archived on their own, never deleted. Opening a note, docked or floating, starts its time again; a quick look from the deck does not. In the last two days a clock appears on the tab and the note says \u{201C}Archives in 2 days\u{201D} or \u{201C}Archives tomorrow\u{201D}. Daily notes follow their own rule. In the Archive such notes say \u{201C}Archived automatically\u{201D} and the date."))
            }

            Section(L("Inside a note")) {
                row(L("Close"), L("esc \u{00B7} \u{2318}W"))
                ForEach(NoteCommand.allCases) { command in
                    recorderRow(.note(command))
                }
                HelpNote(text: L("Float Note lifts the note off the deck so it stays on the desk; Return to Deck puts it back. Both are the round button under Close on the note\u{2019}s spine. Dragging the spine or the header more than a short way from the edge floats the note too, and dragging a floating note to the deck\u{2019}s edge returns it."))
            }

            Section(L("Formatting")) {
                ForEach(FormatCommand.allCases, id: \.title) { command in
                    row(command.title, command.shortcutLabel)
                }
                HelpNote(text: L("Bold, italic and strikethrough wrap the selection, or unwrap it if it is already wrapped. Link turns the selection into [text](url) and uses the URL on the clipboard; pasting a URL over selected text does the same. The lists apply to every selected line and toggle. The same commands sit at the top of the right-click menu."))
            }

            Section(L("Lists")) {
                row(L("Tick or untick the task"), "\u{2318}\u{21A9}")
                row(L("Indent item"), "\u{21E5}")
                row(L("Outdent item"), "\u{21E7}\u{21E5}")
                row(L("End the list, or outdent when nested"), L("\u{21A9} on an empty item"))
                HelpNote(text: L("Tab works anywhere inside an item, or on several selected items. Numbered items renumber themselves when you insert, remove, indent or paste."))
                HelpNote(text: L("With System Settings > Keyboard > Keyboard navigation on, Tab also moves between the buttons of notes, All Notes and Settings, each shown with a focus ring."))
            }
        }
        .formStyle(.grouped)
    }

    /// A global shortcut another app already holds is marked, so its absence
    /// is explained rather than silent.
    /// The name, then the field on the same line. A plain row rather than
    /// `LabeledContent`, which puts a hosted AppKit view on a line of its own.
    private func globalRow(_ command: GlobalCommand) -> some View {
        HStack(spacing: 6) {
            Text(command.title)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if hotkeys.isUnavailable(command) {
                    Label(GlobalCommand.unavailableMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(L("Another app registered this shortcut first, so KeepNote does not receive it. The command still works from the menu."))
                }
                recorder(.global(command))
            }
        }
    }

    private func recorderRow(_ action: ShortcutAction) -> some View {
        HStack(spacing: 6) {
            Text(action.title)
            Spacer(minLength: 8)
            recorder(action)
        }
    }

    private func recorder(_ action: ShortcutAction) -> some View {
        ShortcutRecorder(
            action: action,
            store: store,
            record: { ShortcutEditing.record($0, for: action, store: store, hotkeys: hotkeys) },
            recordingChanged: { recording in recording ? hotkeys.suspend() : hotkeys.resume() }
        )
        .frame(width: 150, height: 22)
    }

    private func row(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - About

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    /// Where new versions are published. The app never asks it anything: the
    /// address is only handed to the browser.
    static let siteURL = URL(string: "https://colletpedro.github.io/keepnote/")!
    /// Where problems are reported. Also only handed to the browser.
    static let issuesURL = URL(string: "https://github.com/colletpedro/keepnote/issues")!
}

struct AboutSettingsPane: View {
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("KeepNote")
                .font(.system(size: 22, weight: .semibold))
            Text(L("Version %@ (%@)", AppInfo.version, AppInfo.build))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("Check for Updates\u{2026}")) { NSWorkspace.shared.open(AppInfo.siteURL) }
                .help(L("Opens the KeepNote site in your browser"))
            Link(L("Report a problem"), destination: AppInfo.issuesURL)
                .font(.callout)
                .help(L("Opens KeepNote\u{2019}s issues on GitHub in your browser"))
            Text(L("Sticky notes on the edge of your screen."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("Open source, MIT License"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            HStack(spacing: 10) {
                Button(L("Export All Notes\u{2026}"), action: actions.exportAll)
                Button(L("Show Welcome\u{2026}"), action: actions.showWelcome)
            }
            HelpNote(text: L("Export writes Markdown, plain text or an archive KeepNote can read back. Show Welcome reopens the first-launch window. KeepNote never checks for updates by itself; Check for Updates opens its site in your browser, and Report a problem its issues on GitHub."))
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        // The same margins as the other panes' content.
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
