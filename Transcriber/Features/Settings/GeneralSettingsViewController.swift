import AppKit
import JobQueue
import TranscriberCore

final class GeneralSettingsViewController: SettingsPaneViewController {
    private static let concurrencyChoices = [1, 2, 4, 8]

    private lazy var modelPopUp = SettingsForm.popUp([], target: self, action: #selector(modelChanged(_:)))
    private let modelSummaryLabel = SettingsForm.descriptionLabel()
    private lazy var backendPopUp = SettingsForm.popUp(
        ["whisper.cpp (Metal)", "MLX"],
        target: self, action: #selector(backendChanged(_:))
    )
    private lazy var concurrencyPopUp = SettingsForm.popUp(
        Self.concurrencyChoices.map(String.init),
        target: self, action: #selector(concurrencyChanged(_:))
    )

    override func makeForm() -> NSView {
        SettingsForm.page([
            SettingsForm.section(String(localized: "Transcription"), rows: [
                SettingsForm.row(String(localized: "Model"), descriptionLabel: modelSummaryLabel, control: modelPopUp),
            ], footer: String(localized: "Applies to files you add from now on. Models are listed from the models folder.")),
            SettingsForm.section(String(localized: "Performance"), rows: [
                SettingsForm.row(String(localized: "Engine"), control: backendPopUp),
                SettingsForm.row(String(localized: "Chunks at once"), description: String(localized: "4 is fastest on most Macs"), control: concurrencyPopUp),
            ], footer: String(localized: "whisper.cpp translates faster; MLX transcribes faster and uses less memory.")),
        ])
    }

    override func render() {
        let settings = viewModel.settings
        let models = viewModel.recognitionModels
        modelPopUp.removeAllItems()
        for model in models {
            modelPopUp.addItem(withTitle: model.displayName)
            modelPopUp.lastItem?.representedObject = model.id
        }
        modelPopUp.isEnabled = !models.isEmpty
        if models.isEmpty {
            modelPopUp.addItem(withTitle: String(localized: "No models"))
        }
        let selected = viewModel.selectedRecognitionModel
        if let selected, let index = models.firstIndex(where: { $0.id == selected.id }) {
            modelPopUp.selectItem(at: index)
        }
        modelSummaryLabel.stringValue = selected?.summary ?? String(localized: "See the Models tab")
        backendPopUp.selectItem(at: settings.backend == .whisperCpp ? 0 : 1)
        concurrencyPopUp.selectItem(at: Self.concurrencyChoices.firstIndex(of: settings.concurrentChunkCount) ?? 2)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String {
            viewModel.setRecognitionModel(id)
        }
    }

    @objc private func backendChanged(_ sender: NSPopUpButton) {
        viewModel.setBackend(sender.indexOfSelectedItem == 0 ? .whisperCpp : .mlx)
    }

    @objc private func concurrencyChanged(_ sender: NSPopUpButton) {
        viewModel.setConcurrentChunkCount(Self.concurrencyChoices[sender.indexOfSelectedItem])
    }
}
