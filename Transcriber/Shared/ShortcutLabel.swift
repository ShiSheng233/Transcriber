import AppKit

/// A shortcut as a row of key caps, followed by the gesture the keys change
/// when there is one. VoiceOver reads it as one label.
final class ShortcutLabel: NSStackView {
    private enum Metrics {
        static let capSpacing: CGFloat = 3
        static let gestureSpacing: CGFloat = 6
    }

    init(_ shortcut: KeyboardShortcut) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Metrics.capSpacing
        for symbol in shortcut.keyCaps {
            addArrangedSubview(KeyCapView(symbol: symbol))
        }
        if let gesture = shortcut.gesture {
            let label = NSTextField(labelWithString: gesture)
            label.textColor = .secondaryLabelColor
            if let lastCap = arrangedSubviews.last {
                setCustomSpacing(Metrics.gestureSpacing, after: lastCap)
            }
            addArrangedSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel((shortcut.keyCaps + [shortcut.gesture].compactMap { $0 }).joined(separator: " "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutLabel is created in code")
    }
}
