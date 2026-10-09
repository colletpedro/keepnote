import Foundation

func runLegacyDefaultsTests() {
    let suite = "com.keepnote.tests.legacy-defaults"
    guard let defaults = UserDefaults(suiteName: suite) else {
        expectTrue("legacy defaults: suite opens", false)
        return
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("KN-PLAIN-TEXT-KEY", forKey: "licenseKey")
    defaults.set(Date(), forKey: "licenseLastValidated")
    defaults.set(Date(), forKey: "trialStartedAt")
    defaults.set(8, forKey: "stackLimit")

    expectTrue("legacy defaults: first launch removes them", LegacyDefaults.removeLicenseKeys(from: defaults))
    for key in LegacyDefaults.licenseKeys {
        expectTrue("legacy defaults: \(key) is gone", defaults.object(forKey: key) == nil)
    }
    expect("legacy defaults: other preferences stay", String(defaults.integer(forKey: "stackLimit")), "8")

    defaults.set("written again", forKey: "licenseKey")
    expectTrue("legacy defaults: only once", !LegacyDefaults.removeLicenseKeys(from: defaults))
    expect("legacy defaults: a second launch touches nothing", defaults.string(forKey: "licenseKey"), "written again")
}
