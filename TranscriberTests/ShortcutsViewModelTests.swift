import Testing

/// The Shortcuts page's list and its search, without the menus or the view.
struct ShortcutsViewModelTests {
    private static let sections = [
        KeyboardShortcut.Section(title: "File", shortcuts: [
            KeyboardShortcut(name: "Add Files…", keyEquivalent: "o", modifiers: .command),
            KeyboardShortcut(name: "Start", keyEquivalent: "r", modifiers: .command),
        ]),
        KeyboardShortcut.Section(title: "Empty", shortcuts: []),
        KeyboardShortcut.Section(title: "Playback", shortcuts: [
            KeyboardShortcut(name: "Play Line", keyEquivalent: "\r", modifiers: .command),
            KeyboardShortcut(name: "Play Selection", keyEquivalent: "\r", modifiers: [.command, .shift]),
        ], footer: "Footer"),
    ]

    @Test func dropsEmptySections() {
        let viewModel = ShortcutsViewModel()
        viewModel.showShortcuts(Self.sections)
        #expect(viewModel.sections.map(\.title) == ["File", "Playback"])
        #expect(viewModel.visibleSections == viewModel.sections)
    }

    @Test func searchMatchesNamesIgnoringCase() {
        let viewModel = ShortcutsViewModel()
        viewModel.showShortcuts(Self.sections)
        viewModel.search("  play sel ")
        #expect(viewModel.visibleSections == [
            KeyboardShortcut.Section(title: "Playback", shortcuts: [
                KeyboardShortcut(name: "Play Selection", keyEquivalent: "\r", modifiers: [.command, .shift]),
            ], footer: "Footer"),
        ])
    }

    @Test func searchWithoutMatchesShowsNothing() {
        let viewModel = ShortcutsViewModel()
        viewModel.showShortcuts(Self.sections)
        viewModel.search("zzz")
        #expect(viewModel.visibleSections.isEmpty)
        viewModel.search("")
        #expect(viewModel.visibleSections.count == 2)
    }
}
