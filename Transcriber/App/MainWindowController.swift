import AppKit
import AudioOverview
import JobQueue
import TranscriberCore
import UniformTypeIdentifiers

/// The queue on the left, the selected file's preview on the right, and a
/// toolbar. It forwards toolbar actions to the queue view model and passes the
/// selected job to the detail view model.
final class MainWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 1100, height: 700)

    private let queueViewModel: JobQueueViewModel
    private let detailViewModel: JobDetailViewModel
    private let detailViewController: JobDetailViewController
    private lazy var findReplaceSheet = FindReplaceSheet(editor: detailViewModel.editor)
    private lazy var shiftTimesSheet = ShiftTimesSheet(editor: detailViewModel.editor)
    private lazy var timingAdjustmentSheet = TimingAdjustmentSheet(
        editor: detailViewModel.editor,
        soundSpans: { [detailViewModel] in detailViewModel.waveform.snapSpans },
        videoFrames: { [detailViewModel] in detailViewModel.videoFrames.frames },
        videoFramesNote: { [detailViewModel] in detailViewModel.videoFramesUnavailableReason }
    )
    private lazy var selectLinesSheet = SelectLinesSheet(editor: detailViewModel.editor)
    private lazy var consistencySheet = ConsistencySheet(editor: detailViewModel.editor) { [queueViewModel] in
        queueViewModel.glossaryTerms
    }
    private lazy var spellingCheckSheet = SpellingCheckSheet(editor: detailViewModel.editor) { [detailViewController] index in
        detailViewController.seekToLine(index)
    }
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
        waveformLoader: WaveformLoader,
        spellChecker: any SpellChecking,
        videoFramesLoader: VideoFramesLoader,
        openSettings: @escaping () -> Void,
        showActivity: @escaping () -> Void
    ) {
        self.queueViewModel = queueViewModel
        self.openSettings = openSettings
        detailViewModel = JobDetailViewModel(waveformLoader: waveformLoader, videoFramesLoader: videoFramesLoader, spellChecker: spellChecker)
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

        let actionBar = detailViewController.editorView.actionBar
        actionBar.isCommandEnabled = { [weak self] action in self?.isCommandEnabled(action) ?? false }
        actionBar.isCommandOn = { [weak self] action in self?.isCommandOn(action) ?? false }
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code")
    }

    private func render() {
        let job = queueViewModel.selectedJob
        detailViewModel.show(job, subtitleLanguage: job.flatMap(queueViewModel.subtitleLanguage(of:)))
        window?.title = queueViewModel.windowTitle
        window?.subtitle = queueViewModel.windowSubtitle
        window?.isDocumentEdited = !queueViewModel.unsavedJobIDs.isEmpty
        _ = (detailViewModel.showsPlayer, detailViewModel.showsEditingTools)  // re-validate the toggles when they change
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

    @objc func toggleEditingTools(_ sender: Any?) {
        detailViewModel.toggleEditingTools()
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

    @objc func shiftTimes(_ sender: Any?) {
        guard let window else { return }
        detailViewController.editorView.commitPendingText()
        shiftTimesSheet.begin(on: window)
    }

    @objc func showTimingPostProcessor(_ sender: Any?) {
        guard let window else { return }
        detailViewController.editorView.commitPendingText()
        timingAdjustmentSheet.begin(on: window)
    }

    @objc func alignTimesToVideoFrames(_ sender: Any?) {
        guard let frames = detailViewModel.videoFrames.frames else { return }
        editing { $0.alignTimesToFrames(frames) }
    }

    @objc func showSelectLines(_ sender: Any?) {
        guard let window else { return }
        selectLinesSheet.begin(on: window)
    }

    @objc func showConsistencyCheck(_ sender: Any?) {
        guard let window else { return }
        detailViewController.editorView.commitPendingText()
        consistencySheet.begin(on: window)
    }

    @objc func showSpellingCheck(_ sender: Any?) {
        guard let window else { return }
        detailViewController.editorView.commitPendingText()
        spellingCheckSheet.begin(on: window)
    }

    @objc func toggleSpellingWhileTyping(_ sender: Any?) {
        detailViewModel.toggleSpellingWhileTyping()
    }

    @objc func playSelection(_ sender: Any?) {
        detailViewController.play(.selection)
    }

    @objc func playNextLine(_ sender: Any?) {
        if editor.selectNextLine() {
            detailViewController.playActiveLine()
        }
    }

    @objc func playBeforeStart(_ sender: Any?) {
        detailViewController.play(.beforeStart)
    }

    @objc func playAfterStart(_ sender: Any?) {
        detailViewController.play(.afterStart)
    }

    @objc func playBeforeEnd(_ sender: Any?) {
        detailViewController.play(.beforeEnd)
    }

    @objc func playAfterEnd(_ sender: Any?) {
        detailViewController.play(.afterEnd)
    }

    @objc func togglePlayback(_ sender: Any?) {
        detailViewController.togglePlayback()
    }

    @objc func selectNextLine(_ sender: Any?) {
        if editor.selectNextLine(), let index = editor.activeIndex {
            detailViewController.seekToLine(index)
        }
    }

    @objc func selectPreviousLine(_ sender: Any?) {
        if editor.selectPreviousLine(), let index = editor.activeIndex {
            detailViewController.seekToLine(index)
        }
    }

    @objc func splitLineAtPlayhead(_ sender: Any?) {
        let editorView = detailViewController.editorView
        let offset = editorView.isEditingText ? editorView.textCursorOffset : nil
        editing { $0.splitAtPlayback(atCharacter: offset) }
    }

    @objc func joinLinesKeepingFirstText(_ sender: Any?) {
        editing { $0.mergeKeepingFirstText() }
    }

    @objc func swapLines(_ sender: Any?) {
        editing { $0.swapTexts() }
    }

    @objc func sortLinesByStart(_ sender: Any?) {
        editing { $0.sortByStart() }
    }

    @objc func toggleWaveform(_ sender: Any?) {
        detailViewModel.toggleTimingMode()
    }

    @objc func toggleSourceColumn(_ sender: Any?) {
        detailViewModel.toggleSourceColumn()
    }

    @objc func toggleSpectrogram(_ sender: Any?) {
        detailViewModel.toggleSpectrogram()
    }

    @objc func zoomInWaveform(_ sender: Any?) {
        detailViewController.zoomWaveform(by: WaveformViewModel.zoomStep)
    }

    @objc func zoomOutWaveform(_ sender: Any?) {
        detailViewController.zoomWaveform(by: 1 / WaveformViewModel.zoomStep)
    }

    @objc func fitWaveformToLine(_ sender: Any?) {
        detailViewController.fitWaveformToActiveLine()
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

    /// Sends the selected lines to the language model only to fix what the
    /// speech model misheard: a translated file's originals are corrected
    /// (shown with Show Original Text), an untranslated transcript's lines
    /// change as one undo step.
    @objc func proofreadLines(_ sender: Any?) {
        detailViewController.editorView.commitPendingText()
        guard let jobID = detailViewModel.shownJobID, !editor.selection.isEmpty, queueViewModel.canProofread(jobID: jobID) else { return }
        let sentLines = editor.lines
        let lineIndices = editor.selection
        Task {
            do {
                let result = try await queueViewModel.proofread(lineIndices, of: sentLines, in: jobID)
                if detailViewModel.shownJobID == jobID, !result.correctedOriginals {
                    editor.applyProofreading(result.lines, sentLines: sentLines)
                }
                if result.unansweredCount > 0 || result.skippedCount > 0, let window {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Some lines were not proofread")
                    alert.informativeText = result.skippedCount > 0
                        ? String(localized: "\(result.skippedCount) of \(lineIndices.count) lines have no recognized original because they were added or retimed. The Activity window has the details.")
                        : String(localized: "\(result.unansweredCount) of \(lineIndices.count) lines got no answer and kept their text. The Activity window has the details.")
                    alert.beginSheetModal(for: window) { _ in }
                }
            } catch {
                if let window {
                    NSAlert(error: error).beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    /// Transcribes the time the selected lines cover again (and translates
    /// the new lines when the file was translated); one undo step.
    @objc func retranscribeLines(_ sender: Any?) {
        detailViewController.editorView.commitPendingText()
        guard let jobID = detailViewModel.shownJobID, !editor.selection.isEmpty, queueViewModel.canRetranscribe(jobID: jobID) else { return }
        let sentLines = editor.lines
        let lineIndices = editor.selection
        Task {
            do {
                let result = try await queueViewModel.retranscribe(lineIndices, of: sentLines, in: jobID)
                guard detailViewModel.shownJobID == jobID, let window else { return }
                if !editor.applyRetranscription(result.lines, sentLines: sentLines, newLineIndices: result.newLineIndices) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The lines changed meanwhile")
                    alert.informativeText = String(localized: "The new transcription was not applied because the subtitles were edited while it ran. Try again.")
                    alert.beginSheetModal(for: window) { _ in }
                } else if let untranslated = result.untranslatedCount, untranslated > 0 {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Some new lines were not translated")
                    alert.informativeText = String(localized: "\(untranslated) of \(result.newLineIndices.count) new lines got no answer from the language model; use Retranslate Selected Lines to try again.")
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
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(togglePlayer(_:)):
            menuItem.title = detailViewModel.showsPlayer ? String(localized: "Hide Player") : String(localized: "Show Player")
        case #selector(toggleEditingTools(_:)):
            menuItem.title = detailViewModel.showsEditingTools ? String(localized: "Hide Editing Tools") : String(localized: "Show Editing Tools")
        case #selector(toggleWaveform(_:)), #selector(toggleSourceColumn(_:)), #selector(toggleSpectrogram(_:)),
             #selector(toggleSpellingWhileTyping(_:)):
            menuItem.state = isCommandOn(action) ? .on : .off
        default:
            break
        }
        return isCommandEnabled(action)
    }

    /// Whether a toggle command is on: the menu's check mark, the action bar's pressed state.
    func isCommandOn(_ action: Selector) -> Bool {
        switch action {
        case #selector(toggleWaveform(_:)): detailViewModel.isTimingModeOn
        case #selector(toggleSourceColumn(_:)): editor.showsSourceColumn
        case #selector(toggleSpectrogram(_:)): detailViewModel.waveform.showsSpectrogram
        case #selector(toggleSpellingWhileTyping(_:)): editor.checksSpellingWhileTyping
        default: false
        }
    }

    /// One answer for the menu bar, the context menus and the action bar.
    func isCommandEnabled(_ action: Selector) -> Bool {
        let canPlay = editor.activeLine != nil && detailViewModel.showsPlayerArea
        switch action {
        case #selector(insertLineBefore(_:)), #selector(insertLineAfter(_:)):
            return editor.isEditable
        case #selector(duplicateLines(_:)), #selector(deleteLines(_:)), #selector(splitLine(_:)),
             #selector(makeStartsContinuous(_:)), #selector(makeEndsContinuous(_:)):
            return editor.canEditSelection
        case #selector(setStartToPlayback(_:)), #selector(setEndToPlayback(_:)), #selector(shiftToPlayback(_:)):
            return editor.canEditSelection && detailViewModel.showsPlayerArea
        case #selector(splitLineAtPlayhead(_:)):
            return editor.canSplitAtPlayback && detailViewModel.showsPlayerArea
        case #selector(jumpToLineStart(_:)), #selector(jumpToLineEnd(_:)), #selector(playLine(_:)), #selector(playSelection(_:)),
             #selector(playBeforeStart(_:)), #selector(playAfterStart(_:)), #selector(playBeforeEnd(_:)), #selector(playAfterEnd(_:)):
            return canPlay
        case #selector(playNextLine(_:)):
            return canPlay && (editor.activeIndex.map { $0 + 1 < editor.lines.count } ?? false)
        case #selector(togglePlayback(_:)):
            return detailViewModel.showsPlayerArea
        case #selector(selectNextLine(_:)), #selector(selectPreviousLine(_:)):
            return editor.activeLine != nil
        case #selector(showFindReplace(_:)), #selector(findNextSubtitle(_:)), #selector(showSelectLines(_:)):
            return !editor.lines.isEmpty
        case #selector(joinLines(_:)), #selector(joinLinesKeepingFirstText(_:)):
            return editor.canMerge
        case #selector(swapLines(_:)):
            return editor.canSwap
        case #selector(sortLinesByStart(_:)):
            return editor.canSort
        case #selector(shiftTimes(_:)), #selector(showTimingPostProcessor(_:)), #selector(showConsistencyCheck(_:)):
            return editor.isEditable && !editor.lines.isEmpty
        case #selector(alignTimesToVideoFrames(_:)):
            return editor.canAlignToFrames && detailViewModel.videoFrames.frames != nil
        case #selector(toggleWaveform(_:)):
            return detailViewModel.canUseTimingMode
        case #selector(toggleSourceColumn(_:)):
            return editor.hasSources
        case #selector(showSpellingCheck(_:)):
            return editor.canCheckSpelling
        case #selector(toggleSpellingWhileTyping(_:)):
            return editor.spellChecker != nil
        case #selector(toggleSpectrogram(_:)), #selector(zoomInWaveform(_:)), #selector(zoomOutWaveform(_:)):
            return detailViewModel.showsWaveform
        case #selector(fitWaveformToLine(_:)):
            return detailViewModel.showsWaveform && editor.activeLine != nil
        case #selector(retranscribeLines(_:)):
            return editor.canEditSelection && (detailViewModel.shownJobID.map(queueViewModel.canRetranscribe(jobID:)) ?? false)
        case #selector(retranslateLines(_:)):
            return editor.canEditSelection && queueViewModel.canUseLanguageModel
                && !(detailViewModel.shownJobID.map { queueViewModel.retranslatingJobIDs.contains($0) || queueViewModel.retranscribingJobIDs.contains($0) } ?? false)
        case #selector(proofreadLines(_:)):
            return editor.canEditSelection && (detailViewModel.shownJobID.map(queueViewModel.canProofread(jobID:)) ?? false)
        case #selector(translateSubtitles(_:)):
            return detailViewModel.subtitleMode == .edit
        case #selector(saveSubtitles(_:)):
            return detailViewModel.shownJobID.map(queueViewModel.unsavedJobIDs.contains) ?? false
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
        static let editingTools = NSToolbarItem.Identifier("editingTools")
        static let model = NSToolbarItem.Identifier("model")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ItemID.model, .space, ItemID.add, ItemID.start, ItemID.clear, .space, ItemID.editingTools, ItemID.player]
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
        case ItemID.editingTools:
            configure(item, label: String(localized: "Editing Tools"), symbol: "wrench.and.screwdriver", action: #selector(toggleEditingTools(_:)))
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
        if item.itemIdentifier == ItemID.editingTools {
            let shows = detailViewModel.showsEditingTools
            let label = shows ? String(localized: "Hide Editing Tools") : String(localized: "Show Editing Tools")
            item.toolTip = label
            // Filled while the bar is open, like a pressed toggle.
            item.image = NSImage(systemSymbolName: shows ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver", accessibilityDescription: label)
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
