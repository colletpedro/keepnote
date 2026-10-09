import AppKit
import SwiftUI

/// Shown once, on the very first launch: where the deck is, how to reach it
/// from the keyboard, and the one choice worth making up front.
struct WelcomeView: View {
    var onDone: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    private var newNote: String { HotkeyService.shared.combo(for: .newNote).displayString }
    private var allNotes: String { HotkeyService.shared.combo(for: .allNotes).displayString }
    private var archive: String { HotkeyService.shared.combo(for: .archive).displayString }
    private var daily: String { HotkeyService.shared.combo(for: .todaysDaily).displayString }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to KeepNote")
                .font(.system(size: 24, weight: .semibold))

            Text("Your notes live in a deck on the right edge of the screen \u{2014} move the cursor there and the cards fan out.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                shortcut("New note", newNote)
                shortcut("All notes", allNotes)
                shortcut("Archive", archive)
                shortcut("Today\u{2019}s Daily", daily)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Text("These work from any app. KeepNote also lives in the menu bar, and in the Dock while one of its windows is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("The calendar button beside + opens today\u{2019}s daily. Give any note the daily tag to make it a daily: the last two days stay on the deck, older ones move to Daily in All Notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Pin to Center holds up to five notes in the middle of the deck, always whole; Keep on Deck stops a note from being archived. Notes you have not opened for 14 days (you choose 7, 14 or 30 in Settings) move to the Archive on their own \u{2014} never deleted, and a clock on the tab warns you for the last two days.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("To keep a note on screen, use Float Note on its spine (\u{2325}\u{2318}P), or drag it off the edge. Return to Deck puts it back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { set($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Button("Get Started", action: onDone)
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
            loginError = "Could not change this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
