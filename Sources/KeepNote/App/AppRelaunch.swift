import AppKit

/// Quits KeepNote and starts it again, for Settings > General > Language: the
/// interface language is settled at launch, AppKit's own strings included.
@MainActor
enum AppRelaunch {
    /// Passed to the new instance, so it waits for this one rather than
    /// handing itself over to it (see `AppDelegate`).
    static let argument = "--relaunched"

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [argument]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { @Sendable _, error in
            Task { @MainActor in
                // If the new copy could not start, this one stays.
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    /// The new instance: the old one is writing its last changes and quitting.
    /// Its hotkeys, deck and database are free once it has gone; give it up to
    /// ten seconds.
    static func waitForEarlierInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
