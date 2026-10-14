import AppKit
import SubtitleExport

final class OutputSettingsViewController: SettingsPaneViewController {
    private var formatCheckboxes: [SubtitleFormat: NSButton] = [:]
    private lazy var locationPopUp = SettingsForm.popUp(
        [String(localized: "Next to the source file"), String(localized: "In a folder…")],
        target: self, action: #selector(locationChanged(_:))
    )
    private let folderPath = SettingsForm.pathView()
    private var folderRow: NSView?

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
                SettingsForm.row(
                    String(localized: "Save subtitles"),
                    description: String(localized: "Files are named after the source and replace older ones."),
                    control: locationPopUp
                ),
                folderRow,
            ]),
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
