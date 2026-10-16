import Foundation
import Observation

/// The Shortcuts settings page: every shortcut the app has, narrowed by a
/// search on the command names. The view gathers the menu bar's shortcuts
/// (they live in AppKit) and hands them in with the keys views handle
/// themselves.
@Observable
final class ShortcutsViewModel {
    private(set) var sections: [KeyboardShortcut.Section] = []
    private(set) var searchText = ""

    /// The sections with the shortcuts whose names match the search; a
    /// section with none left is dropped.
    var visibleSections: [KeyboardShortcut.Section] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sections
        }
        return sections.compactMap { section in
            let matches = section.shortcuts.filter { $0.name.localizedStandardContains(query) }
            return matches.isEmpty ? nil : KeyboardShortcut.Section(title: section.title, shortcuts: matches, footer: section.footer)
        }
    }

    /// Replaces the list, dropping empty sections. Unchanged lists are kept,
    /// so reopening the page does not redraw it.
    func showShortcuts(_ sections: [KeyboardShortcut.Section]) {
        let nonEmpty = sections.filter { !$0.shortcuts.isEmpty }
        if nonEmpty != self.sections {
            self.sections = nonEmpty
        }
    }

    func search(_ text: String) {
        if text != searchText {
            searchText = text
        }
    }
}
