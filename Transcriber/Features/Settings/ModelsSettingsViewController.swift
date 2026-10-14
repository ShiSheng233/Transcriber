import AppKit

final class ModelsSettingsViewController: SettingsPaneViewController {
    private let folderPath = SettingsForm.pathView()
    private let statusStack = NSStackView()

    override func makeForm() -> NSView {
        let chooseButton = NSButton(title: String(localized: "Change…"), target: self, action: #selector(chooseFolder(_:)))
        let revealButton = NSButton(title: String(localized: "Show in Finder"), target: self, action: #selector(revealFolder(_:)))
        let folderControls = NSStackView(views: [folderPath, revealButton, chooseButton])

        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 0

        return SettingsForm.page([
            SettingsForm.section(String(localized: "Models Folder"), rows: [
                SettingsForm.row(control: folderControls),
            ], footer: String(localized: "One folder per model, each with a model.json, plus vad/.")),
            SettingsForm.section(String(localized: "Installed Models"), rows: [statusStack]),
        ])
    }

    override func render() {
        folderPath.url = viewModel.settings.modelsDirectory
        statusStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let statuses = viewModel.hasNoModels
            ? [SettingsViewModel.ModelStatus(title: String(localized: "No models"), detail: String(localized: "This folder has no model.json files"), isReady: false)] + viewModel.modelStatuses
            : viewModel.modelStatuses
        for (index, status) in statuses.enumerated() {
            let row = SettingsForm.row(status.title, description: status.detail, control: Self.statusIcon(isPresent: status.isReady))
            statusStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: statusStack.widthAnchor).isActive = true
            if index > 0 {
                SettingsForm.addDivider(above: row)
            }
        }
    }

    private static func statusIcon(isPresent: Bool) -> NSView {
        let symbol = isPresent ? "checkmark.circle.fill" : "xmark.circle.fill"
        let description = isPresent ? String(localized: "Found") : String(localized: "Missing")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.contentTintColor = isPresent ? .systemGreen : .systemRed
        imageView.toolTip = description
        return imageView
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window = view.window else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder that holds the model folders and vad/.")
        panel.directoryURL = viewModel.settings.modelsDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.viewModel.setModelsDirectory(url)
            }
        }
    }

    @objc private func revealFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([viewModel.settings.modelsDirectory])
    }
}
