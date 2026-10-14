import AppKit
import JobQueue
import TranscriberCore

final class GeneralSettingsViewController: SettingsPaneViewController {
    private static let concurrencyChoices = [1, 2, 4, 8]

    private lazy var taskPopUp = SettingsForm.popUp(
        [String(localized: "Translate to Chinese"), String(localized: "Transcribe Japanese")],
        target: self, action: #selector(taskChanged(_:))
    )
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
                SettingsForm.row(
                    String(localized: "Task"),
                    description: String(localized: "Applies to files you add from now on."),
                    control: taskPopUp
                ),
            ], footer: String(localized: "Translate uses ChickenRice v0.2 (Japanese speech → Chinese subtitles). Transcribe uses whisper-ja-1.5B (Japanese subtitles).")),
            SettingsForm.section(String(localized: "Performance"), rows: [
                SettingsForm.row(
                    String(localized: "Engine"),
                    description: String(localized: "whisper.cpp is faster for translation; MLX uses less memory and is faster for transcription."),
                    control: backendPopUp
                ),
                SettingsForm.row(
                    String(localized: "Chunks at once"),
                    description: String(localized: "30-second chunks decoded in parallel on the GPU. 4 is fastest on most Macs."),
                    control: concurrencyPopUp
                ),
            ]),
        ])
    }

    override func render() {
        let settings = viewModel.settings
        taskPopUp.selectItem(at: settings.task == .translate ? 0 : 1)
        backendPopUp.selectItem(at: settings.backend == .whisperCpp ? 0 : 1)
        concurrencyPopUp.selectItem(at: Self.concurrencyChoices.firstIndex(of: settings.concurrentChunkCount) ?? 2)
    }

    @objc private func taskChanged(_ sender: NSPopUpButton) {
        viewModel.setTask(sender.indexOfSelectedItem == 0 ? .translate : .transcribe)
    }

    @objc private func backendChanged(_ sender: NSPopUpButton) {
        viewModel.setBackend(sender.indexOfSelectedItem == 0 ? .whisperCpp : .mlx)
    }

    @objc private func concurrencyChanged(_ sender: NSPopUpButton) {
        viewModel.setConcurrentChunkCount(Self.concurrencyChoices[sender.indexOfSelectedItem])
    }
}
