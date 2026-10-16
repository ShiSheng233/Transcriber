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
    func translateSubtitles(_ sender: Any?)
    func retranslateLines(_ sender: Any?)
    func proofreadLines(_ sender: Any?)
    func retranscribeLines(_ sender: Any?)
    func saveSubtitles(_ sender: Any?)
    func playSelection(_ sender: Any?)
    func playNextLine(_ sender: Any?)
    func playBeforeStart(_ sender: Any?)
    func playAfterStart(_ sender: Any?)
    func playBeforeEnd(_ sender: Any?)
    func playAfterEnd(_ sender: Any?)
    func togglePlayback(_ sender: Any?)
    func selectNextLine(_ sender: Any?)
    func selectPreviousLine(_ sender: Any?)
    func splitLineAtPlayhead(_ sender: Any?)
    func joinLinesKeepingFirstText(_ sender: Any?)
    func swapLines(_ sender: Any?)
    func sortLinesByStart(_ sender: Any?)
    func showTimingPostProcessor(_ sender: Any?)
    func showSelectLines(_ sender: Any?)
    func toggleWaveform(_ sender: Any?)
    func toggleSourceColumn(_ sender: Any?)
    func zoomInWaveform(_ sender: Any?)
    func zoomOutWaveform(_ sender: Any?)
    func fitWaveformToLine(_ sender: Any?)
}

/// The Subtitle menu, the grid's context menu, the action bar's pull-downs
/// and the View menu's editor items, from one list with one set of shortcuts.
///
/// Shortcuts follow Aegisub's macOS hotkeys (src/libresrc/osx/default_hotkey.json)
/// where they fit macOS: 1 is a line's start, 2 its end, 3/4 set them; ⌥ means
/// before and ⌃ after (⇧ would turn the digit into a symbol, which never
/// matches). Play Line is ⌘↩ (Aegisub's ⌘P is Print on macOS).
enum SubtitleEditorMenu {
    struct Item {
        let title: String
        let action: Selector
        var key = ""
        var modifiers: NSEvent.ModifierFlags = .command
    }

    private typealias Commands = SubtitleEditorCommands
    /// `nil` in a list is a separator.
    typealias Group = [Item?]

    static let playbackItems: Group = [
        Item(title: String(localized: "Play Line"), action: #selector(Commands.playLine(_:)), key: "\r"),
        Item(title: String(localized: "Play Selection"), action: #selector(Commands.playSelection(_:)), key: "\r", modifiers: [.command, .shift]),
        Item(title: String(localized: "Play Next Line"), action: #selector(Commands.playNextLine(_:)), key: "\r", modifiers: [.command, .option]),
        nil,
        Item(title: String(localized: "Play 500 ms Before Start"), action: #selector(Commands.playBeforeStart(_:)), key: "1", modifiers: [.command, .option]),
        Item(title: String(localized: "Play 500 ms After Start"), action: #selector(Commands.playAfterStart(_:)), key: "1", modifiers: [.command, .control]),
        Item(title: String(localized: "Play 500 ms Before End"), action: #selector(Commands.playBeforeEnd(_:)), key: "2", modifiers: [.command, .option]),
        Item(title: String(localized: "Play 500 ms After End"), action: #selector(Commands.playAfterEnd(_:)), key: "2", modifiers: [.command, .control]),
        nil,
        Item(title: String(localized: "Jump to Line Start"), action: #selector(Commands.jumpToLineStart(_:)), key: "1"),
        Item(title: String(localized: "Jump to Line End"), action: #selector(Commands.jumpToLineEnd(_:)), key: "2"),
    ]

    static let continuousItems: Group = [
        Item(title: String(localized: "Make Times Continuous (Change Start)"), action: #selector(Commands.makeStartsContinuous(_:))),
        Item(title: String(localized: "Make Times Continuous (Change End)"), action: #selector(Commands.makeEndsContinuous(_:))),
    ]

    static let timingItems: Group = [
        Item(title: String(localized: "Set Start to Playhead"), action: #selector(Commands.setStartToPlayback(_:)), key: "3"),
        Item(title: String(localized: "Set End to Playhead"), action: #selector(Commands.setEndToPlayback(_:)), key: "4"),
        Item(title: String(localized: "Shift Lines to Playhead"), action: #selector(Commands.shiftToPlayback(_:)), key: "6"),
    ] + continuousItems + [
        nil,
        Item(title: String(localized: "Shift Times…"), action: #selector(Commands.shiftTimes(_:)), key: "i"),
        Item(title: String(localized: "Adjust Timing…"), action: #selector(Commands.showTimingPostProcessor(_:)), key: "i", modifiers: [.command, .shift]),
    ]

    static let splitItems: Group = [
        Item(title: String(localized: "Split Line at Cursor"), action: #selector(Commands.splitLine(_:)), key: "d"),
        Item(title: String(localized: "Split Line at Playhead"), action: #selector(Commands.splitLineAtPlayhead(_:)), key: "d", modifiers: [.command, .shift]),
    ]

    static let joinItems: Group = [
        Item(title: String(localized: "Join Lines"), action: #selector(Commands.joinLines(_:)), key: "j"),
        Item(title: String(localized: "Join Lines (Keep First Text)"), action: #selector(Commands.joinLinesKeepingFirstText(_:)), key: "j", modifiers: [.command, .shift]),
    ]

    static let lineItems: Group = [
        Item(title: String(localized: "Insert Line Before"), action: #selector(Commands.insertLineBefore(_:))),
        Item(title: String(localized: "Insert Line After"), action: #selector(Commands.insertLineAfter(_:))),
        Item(title: String(localized: "Duplicate Lines"), action: #selector(Commands.duplicateLines(_:))),
    ] + splitItems + joinItems + [
        Item(title: String(localized: "Swap Lines"), action: #selector(Commands.swapLines(_:))),
        Item(title: String(localized: "Sort Lines by Start Time"), action: #selector(Commands.sortLinesByStart(_:))),
        Item(title: String(localized: "Delete Lines"), action: #selector(Commands.deleteLines(_:)), key: "\u{8}"),
    ]

    static let modelItems: Group = [
        Item(title: String(localized: "Retranscribe Selected Lines"), action: #selector(Commands.retranscribeLines(_:)), key: "r", modifiers: [.command, .option]),
        Item(title: String(localized: "Retranslate Selected Lines"), action: #selector(Commands.retranslateLines(_:)), key: "r", modifiers: [.command, .shift]),
        Item(title: String(localized: "Proofread Selected Lines"), action: #selector(Commands.proofreadLines(_:)), key: "p", modifiers: [.command, .shift]),
    ]

    static let viewItems: Group = [
        Item(title: String(localized: "Timing Mode"), action: #selector(Commands.toggleWaveform(_:)), key: "a", modifiers: [.command, .option]),
        Item(title: String(localized: "Show Original Text"), action: #selector(Commands.toggleSourceColumn(_:)), key: "o", modifiers: [.command, .option]),
        nil,
        Item(title: String(localized: "Zoom In Waveform"), action: #selector(Commands.zoomInWaveform(_:)), key: "="),
        Item(title: String(localized: "Zoom Out Waveform"), action: #selector(Commands.zoomOutWaveform(_:)), key: "-"),
        Item(title: String(localized: "Fit Waveform to Line"), action: #selector(Commands.fitWaveformToLine(_:)), key: "0"),
    ]

    private static var allItems: [Item] {
        (playbackItems + timingItems + lineItems + modelItems + viewItems).compactMap { $0 }
    }

    /// "Play Line (⌘↩)", for buttons that run a menu command.
    static func toolTip(_ title: String, for action: Selector) -> String {
        guard let item = allItems.first(where: { $0.action == action }), !item.key.isEmpty else {
            return title
        }
        return "\(title) (\(shortcutText(item)))"
    }

    private static func shortcutText(_ item: Item) -> String {
        KeyCapFormatter.text(keyEquivalent: item.key, modifiers: KeyCapFormatter.Modifiers(rawValue: item.modifiers.rawValue))
    }

    static func add(_ items: Group, to menu: NSMenu) {
        for item in items {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = item.key.isEmpty ? [] : item.modifiers
            menu.addItem(menuItem)
        }
    }

    private static func submenu(_ title: String, _ items: Group) -> NSMenuItem {
        let menu = NSMenu(title: title)
        add(items, to: menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// The menu bar's Subtitle menu.
    static func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Subtitle"))
        let top: Group = [
            Item(title: String(localized: "Save Subtitles"), action: #selector(Commands.saveSubtitles(_:)), key: "s"),
            Item(title: String(localized: "Translate Subtitles"), action: #selector(Commands.translateSubtitles(_:)), key: "t", modifiers: [.command, .shift]),
            nil,
            Item(title: String(localized: "Find and Replace…"), action: #selector(Commands.showFindReplace(_:)), key: "f"),
            Item(title: String(localized: "Find Next"), action: #selector(Commands.findNextSubtitle(_:)), key: "g"),
            Item(title: String(localized: "Select Lines…"), action: #selector(Commands.showSelectLines(_:)), key: "l"),
            nil,
        ]
        add(top + lineItems + [nil], to: menu)
        menu.addItem(submenu(String(localized: "Timing"), timingItems))
        menu.addItem(submenu(String(localized: "Playback"), playbackItems))
        menu.addItem(.separator())
        add(modelItems, to: menu)
        return menu
    }

    /// The grid's and the waveform's context menu: the same commands, no shortcuts shown twice.
    static func make() -> NSMenu {
        let menu = NSMenu()
        add(lineItems + [nil], to: menu)
        menu.addItem(submenu(String(localized: "Timing"), timingItems))
        menu.addItem(submenu(String(localized: "Playback"), playbackItems))
        menu.addItem(.separator())
        add(modelItems, to: menu)
        return menu
    }
}
