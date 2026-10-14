import AppKit

/// Editor commands sent up the responder chain; `MainWindowController`
/// handles them.
@objc protocol SubtitleEditorCommands {
    func insertLineBefore(_ sender: Any?)
    func insertLineAfter(_ sender: Any?)
    func duplicateLines(_ sender: Any?)
    func deleteLines(_ sender: Any?)
    func joinLines(_ sender: Any?)
    func splitLine(_ sender: Any?)
    func makeStartsContinuous(_ sender: Any?)
    func makeEndsContinuous(_ sender: Any?)
    func setStartToPlayback(_ sender: Any?)
    func setEndToPlayback(_ sender: Any?)
    func shiftToPlayback(_ sender: Any?)
    func shiftTimes(_ sender: Any?)
    func playLine(_ sender: Any?)
    func jumpToLineStart(_ sender: Any?)
    func jumpToLineEnd(_ sender: Any?)
    func showFindReplace(_ sender: Any?)
    func findNextSubtitle(_ sender: Any?)
    func saveSubtitles(_ sender: Any?)
}

/// The Subtitle menu and the grid's context menu, with one set of shortcuts.
enum SubtitleEditorMenu {
    private struct Item {
        let title: String
        let action: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    /// Shortcuts follow Aegisub's macOS hotkeys (src/libresrc/osx/default_hotkey.json),
    /// except Play Line (Aegisub's Cmd-P is Print on macOS) and Split (Cmd-D,
    /// Aegisub's frame split has no use without frames).
    private static let groups: [[Item]] = [
        [
            Item(title: String(localized: "Play Line"), action: #selector(SubtitleEditorCommands.playLine(_:)), key: "\r", modifiers: .command),
            Item(title: String(localized: "Jump to Line Start"), action: #selector(SubtitleEditorCommands.jumpToLineStart(_:)), key: "1", modifiers: .command),
            Item(title: String(localized: "Jump to Line End"), action: #selector(SubtitleEditorCommands.jumpToLineEnd(_:)), key: "2", modifiers: .command),
        ],
        [
            Item(title: String(localized: "Set Start to Playhead"), action: #selector(SubtitleEditorCommands.setStartToPlayback(_:)), key: "3", modifiers: .command),
            Item(title: String(localized: "Set End to Playhead"), action: #selector(SubtitleEditorCommands.setEndToPlayback(_:)), key: "4", modifiers: .command),
            Item(title: String(localized: "Shift Lines to Playhead"), action: #selector(SubtitleEditorCommands.shiftToPlayback(_:)), key: "6", modifiers: .command),
            Item(title: String(localized: "Make Times Continuous (Change Start)"), action: #selector(SubtitleEditorCommands.makeStartsContinuous(_:)), key: "", modifiers: []),
            Item(title: String(localized: "Make Times Continuous (Change End)"), action: #selector(SubtitleEditorCommands.makeEndsContinuous(_:)), key: "", modifiers: []),
            Item(title: String(localized: "Shift Times…"), action: #selector(SubtitleEditorCommands.shiftTimes(_:)), key: "i", modifiers: .command),
        ],
        [
            Item(title: String(localized: "Insert Line Before"), action: #selector(SubtitleEditorCommands.insertLineBefore(_:)), key: "", modifiers: []),
            Item(title: String(localized: "Insert Line After"), action: #selector(SubtitleEditorCommands.insertLineAfter(_:)), key: "", modifiers: []),
            Item(title: String(localized: "Duplicate Lines"), action: #selector(SubtitleEditorCommands.duplicateLines(_:)), key: "", modifiers: []),
            Item(title: String(localized: "Split Line at Cursor"), action: #selector(SubtitleEditorCommands.splitLine(_:)), key: "d", modifiers: .command),
            Item(title: String(localized: "Join Lines"), action: #selector(SubtitleEditorCommands.joinLines(_:)), key: "j", modifiers: .command),
            Item(title: String(localized: "Delete Lines"), action: #selector(SubtitleEditorCommands.deleteLines(_:)), key: "\u{8}", modifiers: .command),
        ],
    ]

    /// For the menu bar: the commands plus Save Subtitles.
    static func makeMainMenu() -> NSMenu {
        let menu = make()
        menu.title = String(localized: "Subtitle")
        let top = [
            NSMenuItem(title: String(localized: "Save Subtitles"), action: #selector(SubtitleEditorCommands.saveSubtitles(_:)), keyEquivalent: "s"),
            .separator(),
            NSMenuItem(title: String(localized: "Find and Replace…"), action: #selector(SubtitleEditorCommands.showFindReplace(_:)), keyEquivalent: "f"),
            NSMenuItem(title: String(localized: "Find Next"), action: #selector(SubtitleEditorCommands.findNextSubtitle(_:)), keyEquivalent: "g"),
            .separator(),
        ]
        for (index, item) in top.enumerated() {
            menu.insertItem(item, at: index)
        }
        return menu
    }

    static func make() -> NSMenu {
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in group {
                let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.key)
                menuItem.keyEquivalentModifierMask = item.modifiers
                menu.addItem(menuItem)
            }
        }
        return menu
    }
}
