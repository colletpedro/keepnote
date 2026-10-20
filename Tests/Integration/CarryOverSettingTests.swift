import Foundation

/// Settings > Daily > "Unfinished tasks from your last daily": Ask each time
/// by default, and remembered.
@MainActor
func runCarryOverSettingTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    expect("carry over: Ask by default", settings.carryOverMode.rawValue, "ask")
    settings.carryOverMode = .automatic
    expect("carry over: stored", defaults.string(forKey: "dailyCarryOver"), "automatic")
    expect("carry over: the choices", CarryOverMode.allCases.map(\.title).joined(separator: " | "),
           "Don\u{2019}t bring | Ask each time | Bring automatically")
}
