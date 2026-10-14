import AppKit
import LLMTranslation

final class LLMSettingsViewController: SettingsPaneViewController {
    private static let keyPageURL = URL(string: "https://openrouter.ai/keys")
    private static let suggestedLanguages = ["简体中文", "繁體中文", "English", "한국어", "日本語"]

    private let enabledSwitch = NSSwitch()
    private let apiKeyField = NSSecureTextField()
    private lazy var modelPopUp = SettingsForm.popUp([], target: self, action: #selector(modelChanged(_:)))
    private let modelStatusLabel = SettingsForm.descriptionLabel()
    private let languageBox = NSComboBox()
    private let keepsOriginalSwitch = NSSwitch()
    private let glossaryView = NSTextView()

    override func makeForm() -> NSView {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged(_:))
        keepsOriginalSwitch.target = self
        keepsOriginalSwitch.action = #selector(keepsOriginalChanged(_:))

        apiKeyField.placeholderString = "sk-or-…"
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged(_:))
        apiKeyField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let getKeyButton = NSButton(title: String(localized: "Get a Key…"), target: self, action: #selector(openKeyPage(_:)))
        let apiKeyControls = NSStackView(views: [apiKeyField, getKeyButton])

        modelPopUp.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Refresh")) ?? NSImage(),
            target: self, action: #selector(refreshModels(_:))
        )
        refreshButton.bezelStyle = .accessoryBarAction
        let modelControls = NSStackView(views: [modelPopUp, refreshButton])

        languageBox.addItems(withObjectValues: Self.suggestedLanguages)
        languageBox.completes = true
        languageBox.target = self
        languageBox.action = #selector(languageChanged(_:))
        languageBox.delegate = self
        languageBox.widthAnchor.constraint(equalToConstant: 160).isActive = true

        glossaryView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        glossaryView.isRichText = false
        glossaryView.isAutomaticQuoteSubstitutionEnabled = false
        glossaryView.textContainerInset = NSSize(width: 4, height: 6)
        glossaryView.delegate = self
        let glossaryScroll = NSScrollView()
        glossaryScroll.documentView = glossaryView
        glossaryScroll.hasVerticalScroller = true
        glossaryScroll.borderType = .noBorder
        glossaryScroll.drawsBackground = false
        glossaryView.drawsBackground = false
        glossaryView.autoresizingMask = [.width]
        glossaryScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        glossaryScroll.widthAnchor.constraint(equalToConstant: SettingsForm.pageWidth - 64).isActive = true

        return SettingsForm.page([
            SettingsForm.section(String(localized: "Language Model"), rows: [
                SettingsForm.row(String(localized: "Improve subtitles"), description: String(localized: "Polish Chinese or translate Japanese"), control: enabledSwitch),
            ], footer: String(localized: "Runs on OpenRouter after transcription. Timing never changes.")),
            SettingsForm.section(String(localized: "OpenRouter"), rows: [
                SettingsForm.row(String(localized: "API key"), description: String(localized: "Stored in Keychain"), control: apiKeyControls),
                SettingsForm.row(String(localized: "Model"), descriptionLabel: modelStatusLabel, control: modelControls),
            ], footer: String(localized: "Only models with structured output are listed.")),
            SettingsForm.section(String(localized: "Translation"), rows: [
                SettingsForm.row(String(localized: "Translate into"), description: String(localized: "Transcribe task only"), control: languageBox),
                SettingsForm.row(String(localized: "Keep the Japanese line"), description: String(localized: "Bilingual subtitles"), control: keepsOriginalSwitch),
            ]),
            SettingsForm.section(String(localized: "Glossary"), rows: [
                SettingsForm.row(control: glossaryScroll),
            ], footer: String(localized: "One per line: source = translation, e.g. お兄ちゃん = 哥哥")),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if viewModel.modelListState == .notLoaded {
            viewModel.loadModels()
        }
    }

    override func render() {
        let llm = viewModel.settings.llm
        enabledSwitch.state = llm.isEnabled ? .on : .off
        keepsOriginalSwitch.state = llm.keepsOriginalLine ? .on : .off
        if apiKeyField.currentEditor() == nil {
            apiKeyField.stringValue = viewModel.apiKey
        }
        if languageBox.currentEditor() == nil {
            languageBox.stringValue = llm.targetLanguage
        }
        if glossaryView.window?.firstResponder !== glossaryView, glossaryView.string != llm.glossary {
            glossaryView.string = llm.glossary
        }
        renderModels(selectedID: llm.model)
    }

    private func renderModels(selectedID: String) {
        modelPopUp.removeAllItems()
        if selectedID.isEmpty {
            modelPopUp.addItem(withTitle: String(localized: "Choose a model"))
            modelPopUp.lastItem?.representedObject = ""
        }
        for model in viewModel.modelChoices {
            modelPopUp.addItem(withTitle: model.title)
            modelPopUp.lastItem?.representedObject = model.id
            modelPopUp.lastItem?.toolTip = model.id
        }
        if let index = modelPopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedID }) {
            modelPopUp.selectItem(at: index)
        }

        modelStatusLabel.stringValue = switch viewModel.modelListState {
        case .notLoaded, .loading: String(localized: "Loading…")
        case .loaded: selectedID.isEmpty ? String(localized: "\(viewModel.availableModels.count) models") : selectedID
        case .failed: String(localized: "Couldn't load models")
        }
        if case .failed(let message) = viewModel.modelListState {
            modelStatusLabel.toolTip = message
        } else {
            modelStatusLabel.toolTip = selectedID.isEmpty ? nil : selectedID
        }
        modelStatusLabel.textColor = if case .failed = viewModel.modelListState { .systemRed } else { .secondaryLabelColor }
    }

    // MARK: Actions

    @objc private func enabledChanged(_ sender: NSSwitch) {
        viewModel.setLLMEnabled(sender.state == .on)
    }

    @objc private func keepsOriginalChanged(_ sender: NSSwitch) {
        viewModel.setKeepsOriginalLine(sender.state == .on)
    }

    @objc private func apiKeyChanged(_ sender: NSSecureTextField) {
        viewModel.setAPIKey(sender.stringValue)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        if let modelID = sender.selectedItem?.representedObject as? String, !modelID.isEmpty {
            viewModel.setModel(modelID)
        }
    }

    @objc private func languageChanged(_ sender: NSComboBox) {
        viewModel.setTargetLanguage(sender.stringValue)
    }

    @objc private func refreshModels(_ sender: Any?) {
        viewModel.loadModels()
    }

    @objc private func openKeyPage(_ sender: Any?) {
        if let url = Self.keyPageURL {
            NSWorkspace.shared.open(url)
        }
    }
}

extension LLMSettingsViewController: NSTextViewDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    func textDidChange(_ notification: Notification) {
        viewModel.setGlossary(glossaryView.string)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let language = languageBox.objectValueOfSelectedItem as? String {
            viewModel.setTargetLanguage(language)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSSecureTextField) === apiKeyField {
            viewModel.setAPIKey(apiKeyField.stringValue)
        } else if (notification.object as? NSComboBox) === languageBox {
            viewModel.setTargetLanguage(languageBox.stringValue)
        }
    }
}
