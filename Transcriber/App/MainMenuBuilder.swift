import AppKit

/// Builds the menu bar in code, since the app has no storyboard.
enum MainMenuBuilder {
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(makeApplicationMenu()))
        mainMenu.addItem(submenuItem(makeFileMenu()))
        mainMenu.addItem(submenuItem(makeEditMenu()))
        mainMenu.addItem(submenuItem(SubtitleEditorMenu.makeMainMenu()))
        mainMenu.addItem(submenuItem(makeViewMenu()))
        mainMenu.addItem(submenuItem(makeWindowMenu()))
        return mainMenu
    }

    private static func makeApplicationMenu() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: appName)
        menu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Settings…"),
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private static func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(withTitle: String(localized: "Add Files…"), action: #selector(MainWindowController.addFiles(_:)), keyEquivalent: "o")
        menu.addItem(withTitle: String(localized: "Start"), action: #selector(MainWindowController.startQueue(_:)), keyEquivalent: "r")
        menu.addItem(withTitle: String(localized: "Stop"), action: #selector(MainWindowController.stopQueue(_:)), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        let player = menu.addItem(
            withTitle: String(localized: "Hide Player"), action: #selector(MainWindowController.togglePlayer(_:)), keyEquivalent: "p"
        )
        player.keyEquivalentModifierMask = [.command, .option]
        SubtitleEditorMenu.add(SubtitleEditorMenu.viewItems, to: menu)
        return menu
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let activity = menu.addItem(withTitle: String(localized: "Activity"), action: #selector(AppDelegate.showActivity(_:)), keyEquivalent: "l")
        activity.keyEquivalentModifierMask = [.command, .option]
        NSApp.windowsMenu = menu
        return menu
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }
}
