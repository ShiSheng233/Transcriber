import Foundation

/// Turns a menu item's key equivalent and modifier mask into the key caps a
/// Mac shows for it: modifiers in Apple's order ⌃⌥⇧⌘, then the key. It takes
/// raw values so it needs no AppKit and the test target can check it.
enum KeyCapFormatter {
    /// The modifier bits, with the raw values of `NSEvent.ModifierFlags`.
    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt

        static let shift = Modifiers(rawValue: 1 << 17)
        static let control = Modifiers(rawValue: 1 << 18)
        static let option = Modifiers(rawValue: 1 << 19)
        static let command = Modifiers(rawValue: 1 << 20)
        static let function = Modifiers(rawValue: 1 << 23)
    }

    /// Modifiers in the order menus draw them.
    private static let modifierSymbols: [(Modifiers, String)] = [
        (.function, "fn"),
        (.control, "⌃"),
        (.option, "⌥"),
        (.shift, "⇧"),
        (.command, "⌘"),
    ]

    /// Characters a key equivalent uses for keys that type nothing visible.
    private static let specialKeySymbols: [Character: String] = [
        "\r": "↩",
        "\u{3}": "⌤",  // Enter on the numeric keypad
        "\u{1b}": "⎋",
        "\u{8}": "⌫",  // backspace and delete both mean the Delete key
        "\u{7f}": "⌫",
        "\t": "⇥",
        "\u{19}": "⇤",  // back tab
        " ": String(localized: "Space"),
    ]

    /// AppKit's private-use characters for keys without a character
    /// (`NSUpArrowFunctionKey` and its neighbours).
    private enum FunctionKey {
        static let upArrow: UInt32 = 0xF700
        static let downArrow: UInt32 = 0xF701
        static let leftArrow: UInt32 = 0xF702
        static let rightArrow: UInt32 = 0xF703
        static let f1: UInt32 = 0xF704
        static let f35: UInt32 = 0xF726
        static let forwardDelete: UInt32 = 0xF728
        static let home: UInt32 = 0xF729
        static let end: UInt32 = 0xF72B
        static let pageUp: UInt32 = 0xF72C
        static let pageDown: UInt32 = 0xF72D
        static let clear: UInt32 = 0xF739
    }

    private static let functionKeySymbols: [UInt32: String] = [
        FunctionKey.upArrow: "↑",
        FunctionKey.downArrow: "↓",
        FunctionKey.leftArrow: "←",
        FunctionKey.rightArrow: "→",
        FunctionKey.forwardDelete: "⌦",
        FunctionKey.home: "↖",
        FunctionKey.end: "↘",
        FunctionKey.pageUp: "⇞",
        FunctionKey.pageDown: "⇟",
        FunctionKey.clear: "⌧",
    ]

    /// One string per cap. Without a key only the modifiers are left, for
    /// keys held during a drag or a scroll.
    static func keyCaps(keyEquivalent: String, modifiers: Modifiers) -> [String] {
        guard let character = keyEquivalent.first else {
            return modifierCaps(modifiers)
        }
        var modifiers = modifiers
        // A menu reads an uppercase letter as Shift plus that letter.
        if character.isUppercase {
            modifiers.insert(.shift)
        }
        return modifierCaps(modifiers) + [keySymbol(keyEquivalent)]
    }

    /// The caps run together, as a menu shows them after a title.
    static func text(keyEquivalent: String, modifiers: Modifiers) -> String {
        keyCaps(keyEquivalent: keyEquivalent, modifiers: modifiers).joined()
    }

    private static func modifierCaps(_ modifiers: Modifiers) -> [String] {
        modifierSymbols.compactMap { modifiers.contains($0.0) ? $0.1 : nil }
    }

    private static func keySymbol(_ keyEquivalent: String) -> String {
        if let character = keyEquivalent.first, let symbol = specialKeySymbols[character] {
            return symbol
        }
        if let scalar = keyEquivalent.unicodeScalars.first?.value {
            if let symbol = functionKeySymbols[scalar] {
                return symbol
            }
            if (FunctionKey.f1...FunctionKey.f35).contains(scalar) {
                return "F\(scalar - FunctionKey.f1 + 1)"
            }
        }
        return keyEquivalent.uppercased()
    }
}
