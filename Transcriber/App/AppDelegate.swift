import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment()
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var queueViewModel: JobQueueViewModel?
    /// Files opened before the window existed (e.g. dropped on the Dock icon at launch).
    private var pendingOpenedURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()

        let queueViewModel = JobQueueViewModel(queue: environment.jobQueue, settingsStore: environment.settingsStore)
        queueViewModel.addFiles(pendingOpenedURLs)
        pendingOpenedURLs = []
        self.queueViewModel = queueViewModel
        let windowController = MainWindowController(queueViewModel: queueViewModel) { [weak self] in
            self?.showSettings(nil)
        }
        windowController.showWindow(nil)
        mainWindowController = windowController

        #if DEBUG
        if let directory = DebugSnapshotRenderer.requestedDirectory {
            showSettings(nil)
            if let settingsWindowController {
                DebugSnapshotRenderer.render(settings: settingsWindowController, main: windowController, to: directory)
            }
            NSApp.terminate(nil)
            return
        }
        #endif

        NSApp.activate()
    }

    /// "Open With", files dropped on the Dock icon, `open -a Transcriber file`.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let queueViewModel {
            queueViewModel.addFiles(urls)
        } else {
            pendingOpenedURLs += urls
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(viewModel: SettingsViewModel(store: environment.settingsStore))
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
    }
}
