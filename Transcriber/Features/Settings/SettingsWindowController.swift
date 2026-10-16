import AppKit

/// The settings window, laid out as the HIG describes for macOS: a fixed
/// toolbar of panes, the pane's name as the window title, minimize and zoom
/// dimmed, and the last viewed pane restored.
final class SettingsWindowController: NSWindowController {
    init(viewModel: SettingsViewModel) {
        let tabs = SettingsTabViewController()
        let panes: [(SettingsPaneViewController, String)] = [
            (GeneralSettingsViewController(viewModel: viewModel, title: String(localized: "General")), "gearshape"),
            (OutputSettingsViewController(viewModel: viewModel, title: String(localized: "Output")), "doc.text"),
            (ModelsSettingsViewController(viewModel: viewModel, title: String(localized: "Models")), "shippingbox"),
            (LLMSettingsViewController(viewModel: viewModel, title: String(localized: "LLM")), "sparkles"),
        ]
        for (pane, symbol) in panes {
            // Build the form now so its size is known before the first visit;
            // otherwise that size arrives while the pane loads, and the window
            // snaps to it instead of animating.
            pane.loadViewIfNeeded()
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]  // no minimize or zoom
        window.toolbarStyle = .preference
        super.init(window: window)
        tabs.restoreSelectedPane()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code")
    }
}

/// Switches panes instantly (no crossfade), then animates only the window's
/// height, keeping its top edge in place, as system apps do.
final class SettingsTabViewController: NSTabViewController {
    private static let selectedPaneKey = "SettingsSelectedPane"

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        tabStyle = .toolbar
        transitionOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController is created in code")
    }

    func restoreSelectedPane() {
        let index = UserDefaults.standard.integer(forKey: Self.selectedPaneKey)
        if tabViewItems.indices.contains(index) {
            selectedTabViewItemIndex = index
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.selectedPaneKey)
        if let pane = tabViewItem?.viewController {
            fitWindow(to: pane.preferredContentSize, animated: view.window?.isVisible == true)
        }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController == tabViewItems[selectedTabViewItemIndex].viewController {
            fitWindow(to: viewController.preferredContentSize, animated: false)
        }
    }

    private func fitWindow(to contentSize: NSSize, animated: Bool) {
        guard let window = view.window, contentSize.height > 0 else {
            return
        }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        var newFrame = window.frame
        newFrame.origin.y += newFrame.height - frame.height  // keep the top edge
        newFrame.size = frame.size
        if newFrame != window.frame {
            window.setFrame(newFrame, display: true, animate: animated)
        }
    }
}
