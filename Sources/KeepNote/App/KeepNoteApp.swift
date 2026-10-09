import AppKit

/// Entry point.
///
/// Not a `main.swift`: top-level code is nonisolated, and both `AppDelegate`
/// and `NSApplication` are main-actor bound. A `@main` type with a
/// `@MainActor static func main()` gets the isolation right without any
/// `assumeIsolated` escape hatch — which matters here, since that API is
/// macOS 14 and this app targets macOS 13.
@main
enum KeepNoteApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // The activation policy is also set in `applicationDidFinishLaunching`;
        // doing it here too keeps the app out of the Dock even if launching
        // fails early.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
