import AppKit
import SwiftUI

/// The Settings panes. Hosted one per tab by `SettingsWindowController`;
/// deliberately short, because most of the app has no options — most of it has
/// no modes.

enum SettingsTab: Int, CaseIterable {
    case general, notes, deck, daily, sync, shortcuts, about

    var title: String {
        switch self {
        case .general: return "General"
        case .notes: return "Notes"
        case .deck: return "Deck"
        case .daily: return "Daily"
        case .sync: return "Sync"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
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
        case .general: return 350
        case .notes: return 270
        case .deck: return 270
        case .daily: return 230
        case .sync: return 440
        case .shortcuts: return 740
        case .about: return 340
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
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Option(help: loginHelp) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                }
                if LaunchAtLogin.needsApproval {
                    Button("Open Login Items\u{2026}") { LaunchAtLogin.openLoginItemsSettings() }
                }
            }

            Section {
                Option(help: "The note icon at the right of the menu bar, with New Note, All Notes, Settings and Quit.") {
                    Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                }
                Option(help: "Raises the deck above full-screen windows. Stage Manager leaves it alone either way, because a floating panel is not part of an app's window set.") {
                    Toggle("Show over full-screen apps", isOn: $settings.showOverFullScreen)
                }
                HelpNote(text: "KeepNote is in the Dock, with its full menu bar, while one of its windows is open \u{2014} All Notes, Archive, Settings, About, Welcome or Daily Template. When the last one closes it leaves the Dock; the deck, your notes and the menu bar icon stay.")
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var loginHelp: String {
        if let loginError { return loginError }
        if LaunchAtLogin.needsApproval {
            return "Waiting for your approval in System Settings > General > Login Items."
        }
        return "Opens KeepNote when you log in, so the deck is always there."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

// MARK: - Notes

struct NotesSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Option(help: "The color a new note starts with. Automatic takes the color after the previous note's. You can still change it inside the note.") {
                    Picker("Default color", selection: $settings.defaultNoteColor) {
                        Text("Automatic").tag(NoteColor?.none)
                        Divider()
                        ForEach(NoteColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(NoteColor?.some(color))
                        }
                    }
                }
            }

            Section {
                Option(help: "How long to wait after you stop typing before the note is written. Applies to notes opened from now on.") {
                    LabeledContent("Autosave after") {
                        stepper(
                            "\(Int(settings.autosaveDelay * 1000)) ms",
                            value: Binding(
                                get: { Int(settings.autosaveDelay * 1000) },
                                set: { settings.autosaveDelay = Double($0) / 1000 }
                            ),
                            in: 100...2000, step: 50
                        )
                    }
                }
                Option(help: "A deleted note waits this long, with an Undo button, before it is gone for good.") {
                    LabeledContent("Undo a delete for") {
                        stepper(
                            "\(Int(settings.undoWindow)) s",
                            value: Binding(
                                get: { Int(settings.undoWindow) },
                                set: { settings.undoWindow = Double($0) }
                            ),
                            in: 3...60, step: 1
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private func stepper(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int) -> some View {
    HStack(spacing: 6) {
        Text(label).monospacedDigit().foregroundStyle(.secondary)
        Stepper("", value: value, in: range, step: step).labelsHidden()
    }
}

// MARK: - Daily

struct DailySettingsPane: View {
    var actions: SettingsActions

    var body: some View {
        Form {
            Section {
                Option(help: "New daily notes start from this text instead of a blank page. It is not a note: it stays out of the deck, the lists and search, and it syncs and exports with your notes.") {
                    Button("Edit Daily Template\u{2026}", action: actions.editDailyTemplate)
                }
                HelpNote(text: DailyTemplateEditorView.help)
                HelpNote(text: "The template is used only when a new daily note is created: from the calendar button on the deck, \u{2325}\u{2318}Y or the menu. Adding the daily tag to a note you already have never changes its text.")
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
                Option(help: "The pause between one card sliding out and the next. Zero opens them all at once.") {
                    LabeledContent("Cascade delay") {
                        stepper(
                            "\(Int(settings.fanStagger * 1000)) ms",
                            value: Binding(
                                get: { Int(settings.fanStagger * 1000) },
                                set: { settings.fanStagger = Double($0) / 1000 }
                            ),
                            in: 0...120, step: 5
                        )
                    }
                }
            }

            Section {
                Option(help: "A note you have not opened for this long is moved to the Archive, never deleted. Opening a note, docked or floating, starts its time again; a quick look from the deck does not. Notes kept on the deck, pinned notes, open notes and daily notes are never archived this way.") {
                    Picker("Archive notes not opened for", selection: $settings.archiveAfterDays) {
                        ForEach(AutoArchive.choices, id: \.self) { days in
                            Text("\(days) days").tag(days)
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
                Option(help: "Writes one plain-text file per note into a folder you choose. Turning it on asks for that folder.") {
                    Toggle("Sync notes through a folder", isOn: $settings.syncEnabled)
                }
                LabeledContent("Status") {
                    Text(sync.status.summary).foregroundStyle(statusColor)
                }
                LabeledContent("Folder") {
                    Text(sync.folderDisplayName ?? "None chosen").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder\u{2026}", action: actions.chooseSyncFolder)
                    Button("Forget Folder", action: actions.forgetSyncFolder)
                        .disabled(sync.folderDisplayName == nil)
                }
            }

            Section {
                HelpNote(text: "One plain-text file per note, written where you choose \u{2014} iCloud Drive by default. The folder's own provider moves the files between Macs; KeepNote has no server and uses no CloudKit.")
                HelpNote(text: "Files in that folder are readable without the app. The database on this Mac keeps note bodies encrypted, and that key never leaves this Mac \u{2014} which is why it cannot travel with the files.")
            }

            Section {
                Option(help: "Reads notes, or a KeepNote archive, from files on this Mac.") {
                    Button("Import Notes\u{2026}", action: actions.importNotes)
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
    var body: some View {
        Form {
            Section("Global") {
                ForEach(GlobalCommand.allCases) { command in
                    row(command.title, HotkeyService.shared.combo(for: command).displayString)
                }
                HelpNote(text: "Registered through the system's hotkey API, which delivers only these combinations to KeepNote. No Accessibility or Input Monitoring permission is involved.")
            }

            Section("Daily notes") {
                row("Today\u{2019}s Daily, from the deck", "the calendar button beside +")
                row("Earlier dailies", "click the daily chip in a note")
                HelpNote(text: "Today\u{2019}s Daily opens the latest daily of today, or makes one titled with the day and month. Any note becomes a daily when it has the daily tag, as many as you like per day. The dailies of your two most recent days stay on the deck; older ones are archived (never deleted) and kept under Daily in All Notes. One you bring back to the deck yourself stays there.")
            }

            Section("Pinned and kept notes") {
                row("Pin to Center", "the pin in a note's header \u{00B7} Tools \u{00B7} right-click a tab \u{00B7} All Notes")
                row("Keep on Deck", "Tools \u{00B7} right-click a tab \u{00B7} All Notes")
                HelpNote(text: "Up to five notes can be pinned. They stay in the middle of the deck's height, always whole and never overlapped: the first pinned in the middle, the second above it, the third below, the fourth above and the fifth below. Pinning also turns on Keep on Deck; unpinning leaves it on. A kept or pinned note is never archived by the time rule.")
                HelpNote(text: "Notes not opened for the time set under Deck (7, 14 or 30 days; 14 by default) are archived on their own, never deleted. Opening a note, docked or floating, starts its time again; a quick look from the deck does not. In the last two days a clock appears on the tab and the note says \u{201C}Archives in 2 days\u{201D} or \u{201C}Archives tomorrow\u{201D}. Daily notes follow their own rule. In the Archive such notes say \u{201C}Archived automatically\u{201D} and the date.")
            }

            Section("Inside a note") {
                row("Close", "esc")
                row("Find in note", "\u{2318}F")
                row("Next / previous match", "\u{2318}G \u{00B7} \u{21E7}\u{2318}G")
                row("Next color", "\u{2325}\u{2318}C")
                row("Float Note \u{00B7} Return to Deck", "\u{2325}\u{2318}P")
                row("Archive", "\u{21E7}\u{2318}E")
                row("Delete (undoable)", "\u{21E7}\u{2318}\u{232B}")
                HelpNote(text: "Float Note lifts the note off the deck so it stays on the desk; Return to Deck puts it back. Both are the round button under Close on the note's spine. Dragging the spine or the header more than a short way from the edge floats the note too, and dragging a floating note to the right edge returns it.")
            }

            Section("Formatting") {
                ForEach(FormatCommand.allCases, id: \.title) { command in
                    row(command.title, command.shortcutLabel)
                }
                HelpNote(text: "Bold, italic and strikethrough wrap the selection, or unwrap it if it is already wrapped. Link turns the selection into [text](url) and uses the URL on the clipboard; pasting a URL over selected text does the same. The lists apply to every selected line and toggle. The same commands sit at the top of the right-click menu.")
            }

            Section("Lists") {
                row("Indent item", "\u{21E5}")
                row("Outdent item", "\u{21E7}\u{21E5}")
                row("End the list, or outdent when nested", "\u{21A9} on an empty item")
                HelpNote(text: "Tab works anywhere inside an item, or on several selected items. Numbered items renumber themselves when you insert, remove, indent or paste.")
            }
        }
        .formStyle(.grouped)
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
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Sticky notes on the edge of your screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open source, MIT License")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            HStack(spacing: 10) {
                Button("Export All Notes\u{2026}", action: actions.exportAll)
                Button("Show Welcome\u{2026}", action: actions.showWelcome)
            }
            HelpNote(text: "Export writes Markdown, plain text or an archive KeepNote can read back. Show Welcome reopens the first-launch window.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
