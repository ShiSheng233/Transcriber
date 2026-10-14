import AppKit
import JobQueue

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment()
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var activityWindowController: ActivityWindowController?
    private var statusPresenter: AppStatusPresenter?
    private var queueViewModel: JobQueueViewModel?
    /// Files opened before the window existed (e.g. dropped on the Dock icon at launch).
    private var pendingOpenedURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()

        let queueViewModel = JobQueueViewModel(
            queue: environment.jobQueue, settingsStore: environment.settingsStore, apiKeyStore: environment.apiKeyStore,
            library: environment.modelLibrary
        )
        queueViewModel.addFiles(pendingOpenedURLs)
        pendingOpenedURLs = []
        self.queueViewModel = queueViewModel
        let windowController = MainWindowController(
            queueViewModel: queueViewModel,
            activityViewModel: environment.activityViewModel,
            openSettings: { [weak self] in self?.showSettings(nil) },
            showActivity: { [weak self] in self?.showActivity(nil) }
        )
        windowController.showWindow(nil)
        mainWindowController = windowController
        statusPresenter = AppStatusPresenter(viewModel: environment.activityViewModel)

        #if DEBUG
        if let directory = DebugSnapshotRenderer.requestedDirectory {
            if let media = DebugSnapshotRenderer.requestedMedia {
                DebugSnapshotRenderer.transcribe(media, with: queueViewModel, main: windowController, to: directory)
                showActivity(nil)
                if let activityWindowController {
                    DebugSnapshotRenderer.renderActivity(activityWindowController, to: directory)
                }
            }
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

    /// Stops work and frees the model first: ggml aborts at exit if Metal
    /// buffers are still allocated.
    /// Asks about unsaved subtitle edits, then stops work and frees the
    /// model: ggml aborts at exit if Metal buffers are still allocated.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var savesFirst = false
        if let queueViewModel, !queueViewModel.unsavedJobIDs.isEmpty {
            switch askToSaveBeforeQuitting(count: queueViewModel.unsavedJobIDs.count) {
            case .alertFirstButtonReturn: savesFirst = true
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        let queue = environment.jobQueue
        let queueViewModel = queueViewModel
        Task {
            if savesFirst, let queueViewModel {
                do {
                    try await queueViewModel.saveAllSubtitles()
                } catch {
                    NSAlert(error: error).runModal()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await queue.shutDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func askToSaveBeforeQuitting(count: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(localized: "Save the edited subtitles before quitting?")
            : String(localized: "Save edited subtitles of \(count) files before quitting?")
        alert.informativeText = String(localized: "Your edits are lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func showActivity(_ sender: Any?) {
        if activityWindowController == nil {
            activityWindowController = ActivityWindowController(viewModel: environment.activityViewModel)
            activityWindowController?.window?.center()
        }
        activityWindowController?.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                viewModel: SettingsViewModel(
                    store: environment.settingsStore, apiKeyStore: environment.apiKeyStore, library: environment.modelLibrary
                )
            )
        }
        environment.modelLibrary.reload()  // pick up models installed since the last look
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
    }
}
