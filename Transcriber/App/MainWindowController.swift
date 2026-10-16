import AppKit
import JobQueue
import TranscriberCore
import UniformTypeIdentifiers

/// The queue on the left, the selected file's preview on the right, and a
/// toolbar. It forwards toolbar actions to the queue view model and passes the
/// selected job to the detail view model.
final class MainWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 1100, height: 700)

    private let queueViewModel: JobQueueViewModel
    private let detailViewModel = JobDetailViewModel()
    private let detailViewController: JobDetailViewController
    private lazy var findReplaceSheet = FindReplaceSheet(editor: detailViewModel.editor)
    private let openSettings: () -> Void
    private var binder: ObservationBinder?
    private lazy var modelPopUp: NSPopUpButton = {
        let popUp = NSPopUpButton()
        popUp.target = self
        popUp.action = #selector(modelChanged(_:))
        return popUp
    }()
    private var displayedModelIDs: [String] = []

    init(
        queueViewModel: JobQueueViewModel,
        activityViewModel: ActivityViewModel,
        openSettings: @escaping () -> Void,
        showActivity: @escaping () -> Void
    ) {
        self.queueViewModel = queueViewModel
        self.openSettings = openSettings
        detailViewController = JobDetailViewController(viewModel: detailViewModel)
        detailViewModel.onEdit = { [queueViewModel] jobID, lines in
            queueViewModel.updateSubtitles(of: jobID, to: lines)
        }
        detailViewModel.onSwitchMode = { [queueViewModel] jobID, mode, lines in
            queueViewModel.switchMode(of: jobID, to: mode, lines: lines)
        }

        let splitViewController = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: JobQueueViewController(
            viewModel: queueViewModel, activityViewModel: activityViewModel, showActivity: showActivity
        ))
        sidebar.minimumThickness = 260
        sidebar.canCollapse = false
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: detailViewController))

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
        window?.title = queueViewModel.windowTitle
        window?.subtitle = queueViewModel.windowSubtitle
        window?.isDocumentEdited = !queueViewModel.unsavedJobIDs.isEmpty
        _ = detailViewModel.showsPlayer  // re-validate the Player item when it changes
        window?.toolbar?.validateVisibleItems()
        renderModelMenu()
        if queueViewModel.isMissingModels {
            showMissingModelsAlert()
        }
        if let intake = queueViewModel.pendingSubtitleChoice {
            askAboutExistingSubtitles(count: intake.mediaWithSubtitles.count, example: intake.mediaWithSubtitles.first?.subtitleURL)
        }
    }

    private func renderModelMenu() {
        let models = queueViewModel.models
        let ids = models.map(\.id)
        if ids != displayedModelIDs {
            displayedModelIDs = ids
            modelPopUp.removeAllItems()
            for model in models {
                modelPopUp.addItem(withTitle: model.displayName)
                modelPopUp.lastItem?.representedObject = model.id
                modelPopUp.lastItem?.toolTip = model.summary
            }
            if models.isEmpty {
                modelPopUp.addItem(withTitle: String(localized: "No Models"))
            }
            modelPopUp.isEnabled = !models.isEmpty
        }
        if let id = queueViewModel.selectedModelID, let index = ids.firstIndex(of: id) {
            modelPopUp.selectItem(at: index)
        }
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String {
            queueViewModel.selectModel(id: id)
        }
    }

    /// Media files that already have subtitles beside them: translate those,
    /// or transcribe the media again.
    private func askAboutExistingSubtitles(count: Int, example: URL?) {
        guard let window, window.attachedSheet == nil else {
            return
        }
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(localized: "This File Already Has Subtitles")
            : String(localized: "\(count) Files Already Have Subtitles")
        alert.informativeText = String(localized: "Open the existing subtitles (such as \(example?.lastPathComponent ?? "")) to edit or translate them, or transcribe the audio again?")
        alert.addButton(withTitle: String(localized: "Edit Subtitles"))
        alert.addButton(withTitle: String(localized: "Translate Subtitles"))
        alert.addButton(withTitle: String(localized: "Transcribe Again"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            let choice: JobQueueViewModel.SubtitleChoice = switch response {
            case .alertFirstButtonReturn: .editSubtitles
            case .alertSecondButtonReturn: .translateSubtitles
            case .alertThirdButtonReturn: .transcribe
            default: .cancel
            }
            self?.queueViewModel.resolveSubtitleChoice(choice)
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
        let subtitleTypes = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.audiovisualContent, .folder] + subtitleTypes
        panel.message = String(localized: "Choose audio or video files to transcribe, subtitle files (SRT, VTT) to translate, or folders.")
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

    @objc func stopQueue(_ sender: Any?) {
        queueViewModel.stopQueue()
    }

    /// The toolbar's Start button turns into Stop while files run.
    @objc func startOrStopQueue(_ sender: Any?) {
        if queueViewModel.isRunning {
            queueViewModel.stopQueue()
        } else {
            queueViewModel.startQueue()
        }
    }

    @objc func clearFinished(_ sender: Any?) {
        queueViewModel.clearFinished()
    }

    @objc func togglePlayer(_ sender: Any?) {
        detailViewModel.togglePlayer()
    }
}

extension MainWindowController: SubtitleEditorCommands {
    private var editor: SubtitleEditorViewModel {
        detailViewModel.editor
    }

    /// Commands read the lines: keep what is being typed first.
    private func editing(_ change: (SubtitleEditorViewModel) -> Void) {
        detailViewController.editorView.commitPendingText()
        change(editor)
    }

    @objc func insertLineBefore(_ sender: Any?) {
        editing { $0.insertBefore() }
        detailViewController.editorView.focusText()
    }

    @objc func insertLineAfter(_ sender: Any?) {
        editing { $0.insertAfter() }
        detailViewController.editorView.focusText()
    }

    @objc func duplicateLines(_ sender: Any?) {
        editing { $0.duplicate() }
    }

    @objc func deleteLines(_ sender: Any?) {
        editing { $0.delete() }
    }

    @objc func joinLines(_ sender: Any?) {
        editing { $0.merge() }
    }

    @objc func splitLine(_ sender: Any?) {
        let offset = detailViewController.editorView.textCursorOffset
        editing { $0.split(atCharacter: offset) }
    }

    @objc func makeStartsContinuous(_ sender: Any?) {
        editing { $0.makeContinuous(changing: .start) }
    }

    @objc func makeEndsContinuous(_ sender: Any?) {
        editing { $0.makeContinuous(changing: .end) }
    }

    @objc func shiftToPlayback(_ sender: Any?) {
        editing { $0.shiftToPlayback() }
    }

    @objc func jumpToLineStart(_ sender: Any?) {
        detailViewController.jumpToActiveLine(end: false)
    }

    @objc func jumpToLineEnd(_ sender: Any?) {
        detailViewController.jumpToActiveLine(end: true)
    }

    @objc func showFindReplace(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        findReplaceSheet.begin(on: window)
    }

    @objc func findNextSubtitle(_ sender: Any?) {
        if findReplaceSheet.query.isEmpty {
            showFindReplace(sender)
        } else if !editor.findNext(findReplaceSheet.query, options: findReplaceSheet.options) {
            NSSound.beep()
        }
    }

    @objc func setStartToPlayback(_ sender: Any?) {
        editing { $0.setStartToPlayback() }
    }

    @objc func setEndToPlayback(_ sender: Any?) {
        editing { $0.setEndToPlayback() }
    }

    @objc func playLine(_ sender: Any?) {
        detailViewController.playActiveLine()
    }

    /// Asks for an offset; applies it to the selected lines, or all of them.
    @objc func shiftTimes(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        detailViewController.editorView.commitPendingText()
        let alert = NSAlert()
        alert.messageText = String(localized: "Shift Times")
        let target = editor.selection.isEmpty
            ? String(localized: "all lines")
            : String(localized: "the \(editor.selection.count) selected lines")
        alert.informativeText = String(localized: "Seconds to move \(target) by; negative moves them earlier.")
        let field = NSTextField(string: "0.0")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Shift"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let text = field.stringValue.replacingOccurrences(of: ",", with: ".")
            guard response == .alertFirstButtonReturn, let seconds = Double(text) else { return }
            self?.editor.shift(byMilliseconds: Int((seconds * 1_000).rounded()))
        }
    }

    @objc func translateSubtitles(_ sender: Any?) {
        detailViewController.editorView.commitPendingText()
        detailViewModel.switchMode(to: .translate)
    }

    /// Sends the selected lines through the language model again; the
    /// answers replace them as one undo step.
    @objc func retranslateLines(_ sender: Any?) {
        detailViewController.editorView.commitPendingText()
        guard let jobID = detailViewModel.shownJobID, !editor.selection.isEmpty,
              !queueViewModel.retranslatingJobIDs.contains(jobID) else { return }
        let sentLines = editor.lines
        let lineIndices = editor.selection
        Task {
            do {
                let result = try await queueViewModel.retranslate(lineIndices, of: sentLines, in: jobID)
                if detailViewModel.shownJobID == jobID {
                    editor.applyRetranslation(result.lines, sentLines: sentLines)
                }
                if result.unansweredCount > 0, let window {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Some lines were not retranslated")
                    alert.informativeText = String(localized: "\(result.unansweredCount) of \(lineIndices.count) lines got no answer and kept their text. The Activity window has the details.")
                    alert.beginSheetModal(for: window) { _ in }
                }
            } catch {
                if let window {
                    NSAlert(error: error).beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    @objc func saveSubtitles(_ sender: Any?) {
        detailViewController.editorView.commitPendingText()
        guard let jobID = detailViewModel.shownJobID else { return }
        Task {
            do {
                try await queueViewModel.saveSubtitles(of: jobID)
            } catch {
                if let window {
                    NSAlert(error: error).beginSheetModal(for: window) { _ in }
                }
            }
        }
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(insertLineBefore(_:)), #selector(insertLineAfter(_:)):
            return editor.isEditable
        case #selector(duplicateLines(_:)), #selector(deleteLines(_:)), #selector(splitLine(_:)),
             #selector(setStartToPlayback(_:)), #selector(setEndToPlayback(_:)), #selector(shiftToPlayback(_:)),
             #selector(makeStartsContinuous(_:)), #selector(makeEndsContinuous(_:)):
            return editor.canEditSelection
        case #selector(jumpToLineStart(_:)), #selector(jumpToLineEnd(_:)):
            return editor.activeLine != nil && detailViewModel.showsPlayerArea
        case #selector(showFindReplace(_:)), #selector(findNextSubtitle(_:)):
            return !editor.lines.isEmpty
        case #selector(joinLines(_:)):
            return editor.canMerge
        case #selector(shiftTimes(_:)):
            return editor.isEditable && !editor.lines.isEmpty
        case #selector(playLine(_:)):
            return editor.activeLine != nil && detailViewModel.showsPlayerArea
        case #selector(retranslateLines(_:)):
            return editor.canEditSelection && queueViewModel.canUseLanguageModel
                && !(detailViewModel.shownJobID.map(queueViewModel.retranslatingJobIDs.contains) ?? false)
        case #selector(translateSubtitles(_:)):
            return detailViewModel.subtitleMode == .edit
        case #selector(saveSubtitles(_:)):
            return detailViewModel.shownJobID.map(queueViewModel.unsavedJobIDs.contains) ?? false
        case #selector(togglePlayer(_:)):
            menuItem.title = detailViewModel.showsPlayer ? String(localized: "Hide Player") : String(localized: "Show Player")
            return true
        case #selector(startQueue(_:)):
            return queueViewModel.canStart && !queueViewModel.isRunning
        case #selector(stopQueue(_:)):
            return queueViewModel.isRunning
        default:
            return true
        }
    }
}

extension MainWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    private enum ItemID {
        static let add = NSToolbarItem.Identifier("add")
        static let start = NSToolbarItem.Identifier("start")
        static let clear = NSToolbarItem.Identifier("clear")
        static let player = NSToolbarItem.Identifier("player")
        static let model = NSToolbarItem.Identifier("model")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ItemID.model, .space, ItemID.add, ItemID.start, ItemID.clear, .space, ItemID.player]
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
            configure(item, label: String(localized: "Start"), symbol: "play.fill", action: #selector(startOrStopQueue(_:)))
        case ItemID.clear:
            configure(item, label: String(localized: "Clear Finished"), symbol: "checklist.checked", action: #selector(clearFinished(_:)))
        case ItemID.player:
            configure(item, label: String(localized: "Player"), symbol: "video", action: #selector(togglePlayer(_:)))
        case ItemID.model:
            // Task-specific, so it lives here rather than in Settings (HIG).
            item.label = String(localized: "Model")
            item.toolTip = String(localized: "Model for files you add")
            item.view = modelPopUp
            renderModelMenu()
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
                systemSymbolName: detailViewModel.showsPlayer ? "video" : "video.slash",
                accessibilityDescription: label
            )
        }
        if item.itemIdentifier == ItemID.start {
            let isRunning = queueViewModel.isRunning
            let label = isRunning ? String(localized: "Stop") : String(localized: "Start")
            item.label = label
            item.toolTip = isRunning ? String(localized: "Stop (⌘.)") : String(localized: "Start (⌘R)")
            item.image = NSImage(systemSymbolName: isRunning ? "stop.fill" : "play.fill", accessibilityDescription: label)
        }
        return switch item.itemIdentifier {
        case ItemID.start: queueViewModel.isRunning || queueViewModel.canStart
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
