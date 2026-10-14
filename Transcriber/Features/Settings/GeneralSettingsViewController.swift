import AppKit
import JobQueue
import TranscriberCore

final class GeneralSettingsViewController: SettingsPaneViewController {
    private static let concurrencyChoices = [1, 2, 4, 8]

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
            SettingsForm.section(String(localized: "Performance"), rows: [
                SettingsForm.row(String(localized: "Engine"), control: backendPopUp),
                SettingsForm.row(String(localized: "Chunks at once"), description: String(localized: "4 is fastest on most Macs"), control: concurrencyPopUp),
            ], footer: String(localized: "whisper.cpp translates faster; MLX transcribes faster and uses less memory.")),
        ])
    }

    override func render() {
        let settings = viewModel.settings
        backendPopUp.selectItem(at: settings.backend == .whisperCpp ? 0 : 1)
        concurrencyPopUp.selectItem(at: Self.concurrencyChoices.firstIndex(of: settings.concurrentChunkCount) ?? 2)
    }

    @objc private func backendChanged(_ sender: NSPopUpButton) {
        viewModel.setBackend(sender.indexOfSelectedItem == 0 ? .whisperCpp : .mlx)
    }

    @objc private func concurrencyChanged(_ sender: NSPopUpButton) {
        viewModel.setConcurrentChunkCount(Self.concurrencyChoices[sender.indexOfSelectedItem])
    }
}
