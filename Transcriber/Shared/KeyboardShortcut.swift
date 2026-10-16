import Foundation

/// A command and the key caps that run it, as the Shortcuts settings page
/// lists it.
struct KeyboardShortcut: Equatable, Sendable {
    /// Shortcuts under one heading: a menu, a submenu, or a view's own keys.
    struct Section: Equatable, Sendable {
        let title: String
        let shortcuts: [KeyboardShortcut]
        /// When the shortcuts apply, if not everywhere.
        var footer: String?
    }

    let name: String
    let keyCaps: [String]
    /// What the pointer does while the keys are held, for modifiers that
    /// change a drag or a scroll.
    var gesture: String?

    init(name: String, keyCaps: [String], gesture: String? = nil) {
        self.name = name
        self.keyCaps = keyCaps
        self.gesture = gesture
    }

    init(name: String, keyEquivalent: String, modifiers: KeyCapFormatter.Modifiers = [], gesture: String? = nil) {
        self.init(name: name, keyCaps: KeyCapFormatter.keyCaps(keyEquivalent: keyEquivalent, modifiers: modifiers), gesture: gesture)
    }
}
