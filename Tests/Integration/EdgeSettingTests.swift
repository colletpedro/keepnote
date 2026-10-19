import Foundation

/// Settings > Deck > Screen edge: Right by default, stored, and announced the
/// moment it changes so every display's deck moves at once.
@MainActor
func runEdgeSettingTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    expect("edge: Right by default", settings.screenEdge.rawValue, "right")
    var announced = 0
    let observer = NotificationCenter.default.addObserver(forName: .keepNoteWindowBehaviorChanged, object: nil, queue: nil) { _ in
        announced += 1
    }
    settings.screenEdge = .left
    settings.screenEdge = .left
    NotificationCenter.default.removeObserver(observer)
    expect("edge: stored", defaults.string(forKey: "screenEdge"), "left")
    expect("edge: announced once per change", String(announced), "1")
    expect("edge: the choices, in order", ScreenEdge.allCases.map(\.title).joined(separator: ","), "Right,Left")
}
