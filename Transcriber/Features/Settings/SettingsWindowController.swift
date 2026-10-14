import AppKit

/// Preferences-style window with a tab per topic in the toolbar.
final class SettingsWindowController: NSWindowController {
    init(viewModel: SettingsViewModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        let panes: [(SettingsPaneViewController, String)] = [
            (GeneralSettingsViewController(viewModel: viewModel, title: String(localized: "General")), "gearshape"),
            (OutputSettingsViewController(viewModel: viewModel, title: String(localized: "Output")), "doc.text"),
            (ModelsSettingsViewController(viewModel: viewModel, title: String(localized: "Models")), "shippingbox"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code")
    }
}
