import AppKit
import ObjectiveC

// The store, sync and note-window tests: they need the whole app compiled in
// (SQLite, CryptoKit, AppKit), so Scripts/test.sh builds them as a second
// runner. Real windows are built but never ordered in, and the runner never
// takes focus.

extension NSWindow {
    @objc func test_orderFrontRegardless() {}
    @objc func test_makeKeyAndOrderFront(_ sender: Any?) {}
    @objc func test_orderFront(_ sender: Any?) {}
}

extension NSApplication {
    @objc func test_activate(ignoringOtherApps flag: Bool) {}
}

func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else {
        fatalError("cannot swizzle \(original)")
    }
    method_exchangeImplementations(a, b)
}

swizzle(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.test_orderFrontRegardless))
swizzle(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.test_makeKeyAndOrderFront(_:)))
swizzle(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.test_orderFront(_:)))
swizzle(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.test_activate(ignoringOtherApps:)))

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    runLockedNoteTests()
    runLastEditTests()
    runEditedDateTests()
    runLatestWriteTests()
    runBatchTests()
    runSyncWriteTests()
    runDerivedTextTests()
    runDailyDayStoreTests()
    runDailyRuleStoreTests()
    runManyDailiesTests()
    runDailyArchiveSearchTests()
    runDailyIntroTests()
    runOpenArchivedDailyTests()
    runNoteScreenTests()
    runDeckTests()
    runDeckClickTests()
    runPinnedDeckTests()
    runExpiringMarkTests()
    runDeckUpdateTests()
    runDeckButtonTests()
    runDailyMarkTests()
    runKeepOnDeckTests()
    runPinStoreTests()
    runArchiveSettingTests()
    runOpenedDayStoreTests()
    runTimeRuleStoreTests()
    runAutoArchivedMarkTests()
    runDailyTemplateStoreTests()
    runDailyTemplateSyncTests()
    runDailyTemplateArchiveTests()
    runDailyTemplateWindowTests()
    runDailyTemplateApplyTests()
    runDailyTemplateRowTests()
    removeScratch()
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
}
finish()
