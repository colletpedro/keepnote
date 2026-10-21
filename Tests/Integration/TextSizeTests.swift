import AppKit

/// Settings > General > Text size: stored, and the note's text drawn at it.
@MainActor
func runTextSizeTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    expect("text size: Default to begin with", settings.textSize.rawValue, "standard")
    settings.textSize = .extraLarge
    expect("text size: stored", defaults.string(forKey: "textSize"), "extraLarge")
    expect("text size: the four sizes", TextSize.allCases.map(\.title).joined(separator: ","), "Small,Default,Large,Extra Large")
    expectTrue("text size: they grow", zip(TextSize.allCases, TextSize.allCases.dropFirst()).allSatisfy { $0.scale < $1.scale })
    var styler = MarkdownStyler(ink: .black, accent: .blue, highlight: .yellow)
    let base = styler.baseFont.pointSize
    styler.scale = TextSize.extraLarge.scale
    expect("text size: the body at Extra Large", String(Double(styler.baseFont.pointSize)), String(Double(base * TextSize.extraLarge.scale)))
}
