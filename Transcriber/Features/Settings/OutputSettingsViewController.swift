import AppKit
import SubtitleExport
import TranscriberCore

final class OutputSettingsViewController: SettingsPaneViewController {
    private var formatCheckboxes: [SubtitleFormat: NSButton] = [:]
    private lazy var locationPopUp = SettingsForm.popUp(
        [String(localized: "Next to the source file"), String(localized: "In a folder…")],
        target: self, action: #selector(locationChanged(_:))
    )
    private let folderPath = SettingsForm.pathView()
    private var folderRow: NSView?
    private var filterSwitches: [(option: WritableKeyPath<SubtitleFilterSettings, Bool>, control: NSSwitch)] = []

    private func filterRow(
        _ title: String,
        description: String,
        option: WritableKeyPath<SubtitleFilterSettings, Bool>
    ) -> NSView {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(filterToggled(_:))
        control.tag = filterSwitches.count
        filterSwitches.append((option, control))
        return SettingsForm.row(title, description: description, control: control)
    }

    override func makeForm() -> NSView {
        let formatsStack = NSStackView()
        formatsStack.spacing = 14
        for format in SubtitleFormat.allCases {
            let checkbox = NSButton(checkboxWithTitle: format.rawValue.uppercased(), target: self, action: #selector(formatToggled(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(format.rawValue)
            formatCheckboxes[format] = checkbox
            formatsStack.addArrangedSubview(checkbox)
        }

        let changeButton = NSButton(title: String(localized: "Change…"), target: self, action: #selector(chooseFolder(_:)))
        let folderControls = NSStackView(views: [folderPath, changeButton])
        let folderRow = SettingsForm.row(control: folderControls)
        self.folderRow = folderRow

        return SettingsForm.page([
            SettingsForm.section(String(localized: "Formats"), rows: [
                SettingsForm.row(control: formatsStack),
            ], footer: String(localized: "SRT, VTT and LRC match the original tool's files; ASS adds a default style.")),
            SettingsForm.section(String(localized: "Location"), rows: [
                SettingsForm.row(String(localized: "Save subtitles"), control: locationPopUp),
                folderRow,
            ], footer: String(localized: "Files with the same name are replaced.")),
            SettingsForm.section(String(localized: "Cleanup"), rows: [
                filterRow(String(localized: "Drop repetition loops"),
                          description: String(localized: "Text that repeats itself after every retry"),
                          option: \.dropsRepetitionLoops),
                filterRow(String(localized: "Drop vocal sounds"),
                          description: String(localized: "Breathing, moaning, music notes or a lone ellipsis"),
                          option: \.dropsNonverbalLines),
                filterRow(String(localized: "Drop invented outros"),
                          description: String(localized: "Video outros and subtitle credits invented over silence"),
                          option: \.dropsHallucinatedPhrases),
                filterRow(String(localized: "Merge repeated lines"),
                          description: String(localized: "Three or more identical lines in a row"),
                          option: \.mergesRepeatedLines),
                filterRow(String(localized: "Drop lines with odd timing"),
                          description: String(localized: "Too fast to read, or a word held for seconds"),
                          option: \.dropsImplausibleReadingSpeed),
                filterRow(String(localized: "Drop filler-only lines"),
                          description: String(localized: "Lines made only of hesitation sounds"),
                          option: \.dropsFillerLines),
            ], footer: String(localized: "All off gives the original tool's subtitles; short replies can also be removed.")),
            SettingsForm.section(String(localized: "Text and Timing"), rows: [
                filterRow(String(localized: "Normalize text"),
                          description: String(localized: "Even out character widths, ellipses and punctuation"),
                          option: \.normalizesText),
                filterRow(String(localized: "Shorten stretched sounds"),
                          description: String(localized: "Cut long repeated sounds and words down to two"),
                          option: \.shortensStretchedSounds),
                filterRow(String(localized: "Repair looping lines"),
                          description: String(localized: "Cut a line that repeats itself, keep the rest"),
                          option: \.repairsLoopingLines),
                filterRow(String(localized: "Fix timing"),
                          description: String(localized: "5/6–7 s on screen, small gaps closed"),
                          option: \.fixesTiming),
            ], footer: String(localized: "Off by default, so the subtitles match the original tool.")),
        ])
    }

    override func render() {
        let settings = viewModel.settings
        for (format, checkbox) in formatCheckboxes {
            checkbox.state = settings.formats.contains(format) ? .on : .off
        }
        locationPopUp.selectItem(at: settings.outputDirectory == nil ? 0 : 1)
        folderPath.url = settings.outputDirectory
        folderRow?.isHidden = settings.outputDirectory == nil
        for (option, control) in filterSwitches {
            control.state = settings.filter[keyPath: option] ? .on : .off
        }
    }

    @objc private func filterToggled(_ sender: NSSwitch) {
        viewModel.setFilter(filterSwitches[sender.tag].option, isEnabled: sender.state == .on)
    }

    @objc private func formatToggled(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue, let format = SubtitleFormat(rawValue: rawValue) else {
            return
        }
        viewModel.setFormat(format, isEnabled: sender.state == .on)
    }

    @objc private func locationChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            viewModel.setOutputDirectory(nil)
        } else {
            chooseFolder(sender)
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window = view.window else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where to save subtitles.")
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.viewModel.setOutputDirectory(url)
            } else {
                self?.render()  // put the pop-up back if nothing was chosen
            }
        }
    }
}
