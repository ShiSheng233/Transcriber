import AppKit
import JobQueue
import TranscriberCore

final class GeneralSettingsViewController: SettingsPaneViewController {
    /// Doubling stops: the slider moves by index, one tick per choice.
    private static let concurrencyChoices = [1, 2, 4, 8, 16, 32]
    /// Wide enough for "32" so the slider doesn't shift as the value changes.
    private static let concurrencyLabelWidth: CGFloat = 24

    /// In `SettingsViewModel.EngineChoice.allCases` order.
    private lazy var backendPopUp = SettingsForm.popUp(
        ["whisper.cpp (Metal)", "whisper.cpp (Core ML)", "MLX"],
        target: self, action: #selector(backendChanged(_:))
    )
    private lazy var concurrencySlider: NSSlider = {
        let slider = NSSlider(
            value: 0,
            minValue: 0,
            maxValue: Double(Self.concurrencyChoices.count - 1),
            target: self, action: #selector(concurrencyChanged(_:))
        )
        slider.numberOfTickMarks = Self.concurrencyChoices.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }()
    private let concurrencyLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: concurrencyLabelWidth).isActive = true
        return label
    }()

    override func makeForm() -> NSView {
        let concurrencyControl = NSStackView(views: [concurrencySlider, concurrencyLabel])
        concurrencyControl.orientation = .horizontal
        concurrencyControl.spacing = 8
        concurrencyControl.widthAnchor.constraint(equalToConstant: SettingsForm.fieldWidth).isActive = true

        return SettingsForm.page([
            SettingsForm.section(String(localized: "Performance"), rows: [
                SettingsForm.row(String(localized: "Engine"), control: backendPopUp),
                SettingsForm.row(String(localized: "Chunks at once"), description: String(localized: "4 is fastest on most Macs"), control: concurrencyControl),
            ], footer: String(localized: "whisper.cpp translates faster; MLX transcribes faster and uses less memory. Core ML runs the encoder on the Neural Engine for models converted for it, leaving the GPU to decoding; other models use Metal.")),
        ])
    }

    override func render() {
        let settings = viewModel.settings
        backendPopUp.selectItem(at: SettingsViewModel.EngineChoice.allCases.firstIndex(of: viewModel.engineChoice) ?? 0)
        // A stored count between stops shows at the nearest stop below it.
        let index = Self.concurrencyChoices.lastIndex { $0 <= settings.concurrentChunkCount } ?? 0
        concurrencySlider.integerValue = index
        concurrencyLabel.integerValue = Self.concurrencyChoices[index]
    }

    @objc private func backendChanged(_ sender: NSPopUpButton) {
        let choices = SettingsViewModel.EngineChoice.allCases
        guard choices.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        viewModel.setEngine(choices[sender.indexOfSelectedItem])
    }

    @objc private func concurrencyChanged(_ sender: NSSlider) {
        let count = Self.concurrencyChoices[sender.integerValue]
        concurrencyLabel.integerValue = count
        viewModel.setConcurrentChunkCount(count)
    }
}
