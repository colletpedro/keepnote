import AppKit
import SwiftUI

/// Shown once, on the very first launch: where the deck is, how to reach it
/// from the keyboard, and the one choice worth making up front.
struct WelcomeView: View {
    var onDone: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    /// The shortcuts as they are set now, kept current while the window is open.
    @ObservedObject private var shortcuts: ShortcutStore = .shared
    private func keys(_ action: ShortcutAction) -> String { shortcuts.label(for: action) ?? L("None") }
    private var newNote: String { keys(.global(.newNote)) }
    private var allNotes: String { keys(.global(.allNotes)) }
    private var archive: String { keys(.global(.archive)) }
    private var daily: String { keys(.global(.todaysDaily)) }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(L("Welcome to KeepNote"))
                .font(.system(size: 24, weight: .semibold))

            Text(L("Your notes live in a deck on the right edge of the screen \u{2014} move the cursor there and the cards fan out."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                shortcut(L("New note"), newNote)
                shortcut(L("All notes"), allNotes)
                shortcut(L("[noun] Archive"), archive)
                shortcut(L("Today\u{2019}s Daily"), daily)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Text(L("These work from any app. KeepNote also lives in the menu bar, and in the Dock while one of its windows is open."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(L("The calendar button beside + opens today\u{2019}s daily. Give any note the daily tag to make it a daily: the last two days stay on the deck, older ones move to Daily in All Notes."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(L("Pin to Center holds up to five notes in the middle of the deck, always whole; Keep on Deck stops a note from being archived. Notes you have not opened for 14 days (you choose 7, 14 or 30 in Settings) move to the Archive on their own \u{2014} never deleted, and a clock on the tab warns you for the last two days."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(L("To keep a note on screen, use Float Note on its spine (\u{2325}\u{2318}P), or drag it off the edge. Return to Deck puts it back."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { set($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Button(L("Get Started"), action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func set(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = L("Could not change this: %@", error.localizedDescription)
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
