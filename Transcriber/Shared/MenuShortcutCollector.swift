import AppKit

/// Reads the shortcuts off a menu as it is built, so the Shortcuts page can
/// never drift from the menu bar: one section per menu and per submenu,
/// titled after it, in menu order.
enum MenuShortcutCollector {
    static func sections(in mainMenu: NSMenu) -> [KeyboardShortcut.Section] {
        mainMenu.items.compactMap(\.submenu).flatMap { sections(in: $0, titled: $0.title) }
    }

    /// The menu's own shortcuts first, then each submenu's after it.
    private static func sections(in menu: NSMenu, titled title: String) -> [KeyboardShortcut.Section] {
        var shortcuts: [KeyboardShortcut] = []
        var submenus: [KeyboardShortcut.Section] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                submenus += sections(in: submenu, titled: item.title)
                continue
            }
            guard !item.keyEquivalent.isEmpty, !item.title.isEmpty else {
                continue
            }
            let shortcut = KeyboardShortcut(
                name: item.title,
                keyEquivalent: item.keyEquivalent,
                modifiers: KeyCapFormatter.Modifiers(rawValue: item.keyEquivalentModifierMask.rawValue)
            )
            // An alternate item showing the same command twice adds nothing.
            if !shortcuts.contains(shortcut) {
                shortcuts.append(shortcut)
            }
        }
        return [KeyboardShortcut.Section(title: title, shortcuts: shortcuts)] + submenus
    }
}
