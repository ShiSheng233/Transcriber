import AppKit
import UniformTypeIdentifiers

/// The queue on the left, the selected file's preview on the right, and a
/// toolbar. It forwards toolbar actions to the queue view model and passes the
/// selected job to the detail view model.
final class MainWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 1100, height: 700)

    private let queueViewModel: JobQueueViewModel
    private let detailViewModel = JobDetailViewModel()
    private let openSettings: () -> Void
    private var binder: ObservationBinder?

    init(queueViewModel: JobQueueViewModel, openSettings: @escaping () -> Void) {
        self.queueViewModel = queueViewModel
        self.openSettings = openSettings

        let splitViewController = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: JobQueueViewController(viewModel: queueViewModel))
        sidebar.minimumThickness = 260
        sidebar.canCollapse = false
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: JobDetailViewController(viewModel: detailViewModel)))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcriber"
        window.contentViewController = splitViewController
        window.setContentSize(Self.initialContentSize)
        window.setFrameAutosaveName("MainWindow")
        window.center()
        super.init(window: window)

        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code")
    }

    private func render() {
        detailViewModel.show(queueViewModel.selectedJob)
        _ = detailViewModel.showsPlayer  // re-validate the Player item when it changes
        window?.toolbar?.validateVisibleItems()
        if queueViewModel.isMissingModels {
            showMissingModelsAlert()
        }
    }

    private func showMissingModelsAlert() {
        guard let window, window.attachedSheet == nil else {
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "No Models Installed")
        alert.informativeText = String(localized: "Choose a models folder in Settings. Each model needs its own folder with a model.json.")
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.queueViewModel.dismissMissingModels()
            if response == .alertFirstButtonReturn {
                self?.openSettings()
            }
        }
    }

    // MARK: Actions (toolbar and menu)

    @objc func addFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audiovisualContent, .folder]
        panel.message = String(localized: "Choose audio or video files, or folders that contain them.")
        guard let window else {
            return
        }
        panel.beginSheetModal(for: window) { [queueViewModel] response in
            if response == .OK {
                queueViewModel.addFiles(panel.urls)
            }
        }
    }

    @objc func startQueue(_ sender: Any?) {
        queueViewModel.startQueue()
    }

    @objc func clearFinished(_ sender: Any?) {
        queueViewModel.clearFinished()
    }

    @objc func showSettingsFromToolbar(_ sender: Any?) {
        openSettings()
    }

    @objc func togglePlayer(_ sender: Any?) {
        detailViewModel.togglePlayer()
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePlayer(_:)) {
            menuItem.title = detailViewModel.showsPlayer ? String(localized: "Hide Player") : String(localized: "Show Player")
        }
        return true
    }
}

extension MainWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    private enum ItemID {
        static let add = NSToolbarItem.Identifier("add")
        static let start = NSToolbarItem.Identifier("start")
        static let clear = NSToolbarItem.Identifier("clear")
        static let player = NSToolbarItem.Identifier("player")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.add, ItemID.start, ItemID.clear, .flexibleSpace, ItemID.player, ItemID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        switch itemIdentifier {
        case ItemID.add:
            configure(item, label: String(localized: "Add Files"), symbol: "plus", action: #selector(addFiles(_:)))
        case ItemID.start:
            configure(item, label: String(localized: "Start"), symbol: "play.fill", action: #selector(startQueue(_:)))
        case ItemID.clear:
            configure(item, label: String(localized: "Clear Finished"), symbol: "checklist.checked", action: #selector(clearFinished(_:)))
        case ItemID.player:
            configure(item, label: String(localized: "Player"), symbol: "play.rectangle", action: #selector(togglePlayer(_:)))
        case ItemID.settings:
            configure(item, label: String(localized: "Settings"), symbol: "gearshape", action: #selector(showSettingsFromToolbar(_:)))
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == ItemID.player {
            let label = detailViewModel.showsPlayer ? String(localized: "Hide Player") : String(localized: "Show Player")
            item.toolTip = label
            item.image = NSImage(
                systemSymbolName: detailViewModel.showsPlayer ? "play.rectangle.fill" : "play.rectangle",
                accessibilityDescription: label
            )
        }
        return switch item.itemIdentifier {
        case ItemID.start: queueViewModel.canStart
        case ItemID.clear: queueViewModel.hasFinishedJobs
        default: true
        }
    }

    private func configure(_ item: NSToolbarItem, label: String, symbol: String, action: Selector) {
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
    }
}
