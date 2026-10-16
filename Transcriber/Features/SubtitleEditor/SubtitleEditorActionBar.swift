import AppKit

/// The strip of editing buttons above the edit box. Every button sends the
/// same action as its menu item up the responder chain, so the menu bar,
/// the context menu and this bar always do the same thing; the less common
/// commands sit in pull-down menus.
final class SubtitleEditorActionBar: NSView {
    private struct Command {
        let title: String
        let symbol: String
        let action: Selector
    }

    private static let height: CGFloat = 28
    private static let groupSeparatorHeight: CGFloat = 14

    /// Asked whether a command can run now; set by whoever handles the commands.
    var isCommandEnabled: (Selector) -> Bool = { _ in false }
    /// Asked whether a toggle command is on.
    var isCommandOn: (Selector) -> Bool = { _ in false }

    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    private var toggles: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SubtitleEditorActionBar is created in code")
    }

    private func build() {
        typealias Commands = SubtitleEditorCommands
        let lines: [NSView] = [
            button(Command(title: String(localized: "Insert Line After"), symbol: "plus", action: #selector(Commands.insertLineAfter(_:)))),
            button(Command(title: String(localized: "Delete Lines"), symbol: "minus", action: #selector(Commands.deleteLines(_:)))),
            pullDown(String(localized: "Split"), symbol: "scissors", items: SubtitleEditorMenu.splitItems),
            pullDown(String(localized: "Join"), symbol: "arrow.triangle.merge", items: SubtitleEditorMenu.joinItems),
            button(Command(title: String(localized: "Swap Lines"), symbol: "arrow.up.arrow.down", action: #selector(Commands.swapLines(_:)))),
        ]
        let timing: [NSView] = [
            button(Command(title: String(localized: "Set Start to Playhead"), symbol: "arrow.left.to.line", action: #selector(Commands.setStartToPlayback(_:)))),
            button(Command(title: String(localized: "Set End to Playhead"), symbol: "arrow.right.to.line", action: #selector(Commands.setEndToPlayback(_:)))),
            button(Command(title: String(localized: "Shift Lines to Playhead"), symbol: "arrow.right.to.line.compact", action: #selector(Commands.shiftToPlayback(_:)))),
            pullDown(String(localized: "Make Times Continuous"), symbol: "arrow.left.and.right.square", items: SubtitleEditorMenu.continuousItems),
            button(Command(title: String(localized: "Shift Times…"), symbol: "clock.arrow.circlepath", action: #selector(Commands.shiftTimes(_:)))),
            button(Command(title: String(localized: "Adjust Timing…"), symbol: "slider.horizontal.3", action: #selector(Commands.showTimingPostProcessor(_:)))),
        ]
        let playback: [NSView] = [
            button(Command(title: String(localized: "Play Line"), symbol: "play.fill", action: #selector(Commands.playLine(_:)))),
            pullDown(String(localized: "Playback"), symbol: "play.circle", items: SubtitleEditorMenu.playbackItems),
        ]
        let select: [NSView] = [
            button(Command(title: String(localized: "Select Lines…"), symbol: "line.3.horizontal.decrease.circle", action: #selector(Commands.showSelectLines(_:)))),
            button(Command(title: String(localized: "Find and Replace…"), symbol: "magnifyingglass", action: #selector(Commands.showFindReplace(_:)))),
        ]
        let modes: [NSView] = [
            button(Command(title: String(localized: "Timing Mode"), symbol: "waveform", action: #selector(Commands.toggleWaveform(_:))), isToggle: true),
            button(Command(title: String(localized: "Show Source Column"), symbol: "rectangle.split.2x1", action: #selector(Commands.toggleSourceColumn(_:))), isToggle: true),
        ]

        for (index, group) in [lines, timing, playback, select].enumerated() {
            if index > 0 {
                stack.addView(separator(), in: .leading)
            }
            group.forEach { stack.addView($0, in: .leading) }
        }
        modes.forEach { stack.addView($0, in: .trailing) }
        // When the pane is narrow, the commands that are easiest to reach elsewhere go first.
        for view in select + playback {
            stack.setVisibilityPriority(.detachOnlyIfNecessary, for: view)
        }
    }

    /// Enables the buttons and sets the toggles from the current state.
    func validate() {
        for button in buttons {
            guard let action = button.action else { continue }
            button.isEnabled = isCommandEnabled(action)
        }
        for toggle in toggles {
            guard let action = toggle.action else { continue }
            toggle.state = isCommandOn(action) ? .on : .off
        }
    }

    // MARK: Building

    private func button(_ command: Command, isToggle: Bool = false) -> NSButton {
        let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: command.action)
        button.bezelStyle = isToggle ? .accessoryBar : .accessoryBarAction
        button.setButtonType(isToggle ? .pushOnPushOff : .momentaryPushIn)
        button.controlSize = .small
        button.isBordered = true
        button.toolTip = SubtitleEditorMenu.toolTip(command.title, for: command.action)
        buttons.append(button)
        if isToggle {
            toggles.append(button)
        }
        return button
    }

    private func pullDown(_ title: String, symbol: String, items: SubtitleEditorMenu.Group) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
        popUp.bezelStyle = .accessoryBarAction
        popUp.controlSize = .small
        popUp.toolTip = title
        popUp.imagePosition = .imageOnly
        // A pull-down shows its first item as the button's face: the symbol, no title.
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        popUp.menu?.addItem(face)
        SubtitleEditorMenu.add(items, to: popUp.menu ?? NSMenu())
        return popUp
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: Self.groupSeparatorHeight).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}
