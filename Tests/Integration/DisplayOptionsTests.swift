import AppKit

/// Increase contrast and Reduce transparency, as the app draws with them.
@MainActor
func runDisplayOptionsTests() {
    defer {
        DisplayOptions.increaseContrastOverride = nil
        DisplayOptions.reduceTransparencyOverride = nil
    }
    DisplayOptions.reduceTransparencyOverride = false
    expect("transparency: see-through by default", String(Double(DisplayOptions.alpha(0.3))), "0.3")
    DisplayOptions.reduceTransparencyOverride = true
    expect("transparency: solid when reduced", String(Double(DisplayOptions.alpha(0.3))), "1.0")

    DisplayOptions.increaseContrastOverride = false
    let quiet = NoteColor.allCases.map { $0.secondaryInk }
    let faint = NoteColor.butter.rule.alphaComponent
    DisplayOptions.increaseContrastOverride = true
    expectTrue("contrast: quiet text becomes the body's ink",
               NoteColor.allCases.allSatisfy { $0.secondaryInk == $0.ink } && quiet.allSatisfy { $0 != NoteColor.butter.ink })
    expectTrue("contrast: rules and the perforation firmer", NoteColor.butter.rule.alphaComponent > faint)
    var announced = false
    let observer = NotificationCenter.default.addObserver(forName: .keepNoteWindowBehaviorChanged, object: nil, queue: nil) { _ in announced = true }
    DisplayOptions.observe()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    spin(0.1)
    NotificationCenter.default.removeObserver(observer)
    expectTrue("a change redraws the deck and the notes", announced)
}
