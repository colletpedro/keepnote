import AppKit
import Combine
import SwiftUI

/// The Settings window in the macOS idiom: an `NSTabViewController` in toolbar
/// style, so the tabs are icons in the window's toolbar and the window resizes
/// to each pane. Each pane is a SwiftUI form hosted in its own controller.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let paneWidth: CGFloat = 620

    let window: NSWindow
    var onClose: (() -> Void)?

    private let tabController = NSTabViewController()

    init(settings: AppSettings, sync: FolderSyncService, actions: SettingsActions) {
        tabController.tabStyle = .toolbar
        tabController.transitionOptions = []

        for tab in SettingsTab.allCases {
            let root: AnyView
            switch tab {
            case .general: root = AnyView(GeneralSettingsPane(settings: settings))
            case .notes: root = AnyView(NotesSettingsPane(settings: settings))
            case .deck: root = AnyView(DeckSettingsPane(settings: settings))
            case .daily: root = AnyView(DailySettingsPane(actions: actions))
            case .sync: root = AnyView(SyncSettingsPane(settings: settings, sync: sync, actions: actions))
            case .shortcuts: root = AnyView(ShortcutsSettingsPane())
            case .about: root = AnyView(AboutSettingsPane(actions: actions))
            }
            let size = NSSize(width: Self.paneWidth, height: tab.paneHeight)
            let host = NSHostingController(rootView: root.frame(width: size.width, height: size.height))
            host.preferredContentSize = size
            host.title = tab.title

            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabController.addTabViewItem(item)
        }

        window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.toolbarStyle = .preference
        window.center()
    }

    func select(_ tab: SettingsTab) {
        tabController.selectedTabViewItemIndex = tab.rawValue
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
