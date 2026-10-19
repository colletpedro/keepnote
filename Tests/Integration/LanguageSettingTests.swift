import Foundation

/// The Language setting is stored, and written as the app's AppleLanguages so
/// AppKit's own text follows it after the relaunch; System clears that.
@MainActor
func runLanguageSettingTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    settings.language = .portuguese
    expect("language: stored", defaults.string(forKey: Localization.preferenceKey), "pt-BR")
    expect("language: and given to AppKit", defaults.stringArray(forKey: "AppleLanguages")?.joined(separator: ","), "pt-BR")
    settings.language = .english
    expect("language: English", defaults.stringArray(forKey: "AppleLanguages")?.joined(separator: ","), "en")
    settings.language = .system
    expect("language: System stored", defaults.string(forKey: Localization.preferenceKey), "system")
    expectTrue("language: System leaves AppKit to the Mac", defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    expect("relaunch: the argument the new copy waits on", AppRelaunch.argument, "--relaunched")
}
