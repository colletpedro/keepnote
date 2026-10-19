import AppKit

/// The app's main menu. Always installed: with the Dock icon on it is what the
/// menu bar shows, and with it off AppKit still reads its key equivalents
/// (⌘C, ⌘V, ⌘Z, the Format shortcuts) while a note has focus.
@MainActor
enum MainMenu {
    static func make(target: AppCoordinator) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu(target)))
        main.addItem(submenuItem(fileMenu(target)))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(FormatCommand.makeMenu()))

        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window

        let help = helpMenu(target)
        main.addItem(submenuItem(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        mask: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = mask }
        item.target = target
        menu.addItem(item)
    }

    // MARK: - KeepNote

    private static func appMenu(_ target: AppCoordinator) -> NSMenu {
        let menu = NSMenu(title: "KeepNote")
        add(to: menu, L("About KeepNote"), #selector(AppCoordinator.menuAbout), target: target)
        menu.addItem(.separator())
        add(to: menu, L("Settings\u{2026}"), #selector(AppCoordinator.menuSettings), ",", target: target)
        menu.addItem(.separator())

        let services = NSMenu(title: L("Services"))
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        add(to: menu, L("Hide KeepNote"), #selector(NSApplication.hide(_:)), "h")
        add(to: menu, L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", mask: [.command, .option])
        add(to: menu, L("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(to: menu, L("Quit KeepNote"), #selector(AppCoordinator.menuQuit), "q", target: target)
        return menu
    }

    // MARK: - File

    private static func fileMenu(_ target: AppCoordinator) -> NSMenu {
        let menu = NSMenu(title: L("File"))
        add(to: menu, L("New Note"), #selector(AppCoordinator.menuNewNote), "n", target: target)
        add(to: menu, L("Today\u{2019}s Daily"), #selector(AppCoordinator.menuTodaysDaily), target: target)
        add(to: menu, L("Edit Daily Template\u{2026}"), #selector(AppCoordinator.menuEditDailyTemplate), target: target)
        add(to: menu, L("All Notes"), #selector(AppCoordinator.menuAllNotes), target: target)
        add(to: menu, L("Archive"), #selector(AppCoordinator.menuArchive), target: target)
        menu.addItem(.separator())
        add(to: menu, L("Import\u{2026}"), #selector(AppCoordinator.menuImport), "i", target: target)
        add(to: menu, L("Export All\u{2026}"), #selector(AppCoordinator.menuExportAll), "e", target: target)
        menu.addItem(.separator())
        add(to: menu, L("Close"), #selector(NSWindow.performClose(_:)), "w")
        return menu
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: L("Edit"))
        add(to: menu, L("Undo"), Selector(("undo:")), "z")
        add(to: menu, L("Redo"), Selector(("redo:")), "z", mask: [.command, .shift])
        menu.addItem(.separator())
        add(to: menu, L("Cut"), #selector(NSText.cut(_:)), "x")
        add(to: menu, L("Copy"), #selector(NSText.copy(_:)), "c")
        add(to: menu, L("Paste"), #selector(NSText.paste(_:)), "v")
        add(to: menu, L("Select All"), #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    // MARK: - Window, Help

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: L("Window"))
        add(to: menu, L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(to: menu, L("Zoom"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(to: menu, L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu(_ target: AppCoordinator) -> NSMenu {
        let menu = NSMenu(title: L("Help"))
        add(to: menu, L("Keyboard Shortcuts"), #selector(AppCoordinator.menuShortcuts), target: target)
        return menu
    }
}
