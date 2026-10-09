import Foundation

/// Preferences written by earlier builds that nothing reads any more.
enum LegacyDefaults {
    /// The old licence key (kept in plain text), when it was last checked, and
    /// when the trial started. KeepNote has no licence and no trial.
    static let licenseKeys = ["licenseKey", "licenseLastValidated", "trialStartedAt"]
    static let licenseKeysRemoved = "legacyLicenseKeysRemoved"

    /// Removes them, once: a later call finds the marker and does nothing.
    /// Returns whether this call removed them.
    @discardableResult
    static func removeLicenseKeys(from defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: licenseKeysRemoved) else { return false }
        for key in licenseKeys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: licenseKeysRemoved)
        return true
    }
}
