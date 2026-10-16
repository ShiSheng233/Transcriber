import AppKit
import LLMTranslation

final class LLMSettingsViewController: SettingsPaneViewController {
    private static let suggestedLanguages = ["简体中文", "繁體中文", "English", "한국어", "日本語"]

    private let enabledSwitch = NSSwitch()
    private lazy var providerPopUp = SettingsForm.popUp(
        LLMProvider.allCases.map(\.displayName), target: self, action: #selector(providerChanged(_:))
    )
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let apiKeyDescription = SettingsForm.descriptionLabel()
    private var getKeyButton: NSButton?
    /// Editable: any model id the server accepts, listed or not.
    private let modelBox = NSComboBox()
    private let modelStatusLabel = SettingsForm.descriptionLabel()
    private let languageBox = NSComboBox()
    private let keepsOriginalSwitch = NSSwitch()
    private let proofreadSwitch = NSSwitch()
    private let removesHallucinationsSwitch = NSSwitch()
    private let glossaryView = NSTextView()

    override func makeForm() -> NSView {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged(_:))
        keepsOriginalSwitch.target = self
        keepsOriginalSwitch.action = #selector(keepsOriginalChanged(_:))
        proofreadSwitch.target = self
        proofreadSwitch.action = #selector(proofreadChanged(_:))
        removesHallucinationsSwitch.target = self
        removesHallucinationsSwitch.action = #selector(removesHallucinationsChanged(_:))

        baseURLField.placeholderString = "https://example.com/v1"
        baseURLField.target = self
        baseURLField.action = #selector(baseURLChanged(_:))
        baseURLField.delegate = self

        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged(_:))
        apiKeyField.delegate = self
        let getKeyButton = NSButton(title: String(localized: "Get a Key…"), target: self, action: #selector(openKeyPage(_:)))
        self.getKeyButton = getKeyButton
        let apiKeyControls = SettingsForm.fieldGroup(apiKeyField, buttons: [getKeyButton])

        modelBox.completes = true
        modelBox.numberOfVisibleItems = 15
        modelBox.target = self
        modelBox.action = #selector(modelChanged(_:))
        modelBox.delegate = self
        modelBox.placeholderString = String(localized: "Model id")
        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Refresh")) ?? NSImage(),
            target: self, action: #selector(refreshModels(_:))
        )
        refreshButton.bezelStyle = .accessoryBarAction
        let modelControls = SettingsForm.fieldGroup(modelBox, buttons: [refreshButton])

        languageBox.addItems(withObjectValues: Self.suggestedLanguages)
        languageBox.completes = true
        languageBox.target = self
        languageBox.action = #selector(languageChanged(_:))
        languageBox.delegate = self

        glossaryView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        glossaryView.isRichText = false
        glossaryView.isAutomaticQuoteSubstitutionEnabled = false
        glossaryView.textContainerInset = NSSize(width: 4, height: 6)
        glossaryView.delegate = self
        let glossaryScroll = NSScrollView()
        glossaryScroll.documentView = glossaryView
        glossaryScroll.hasVerticalScroller = true
        glossaryScroll.autohidesScrollers = true
        glossaryScroll.scrollerStyle = .overlay
        glossaryScroll.borderType = .noBorder
        glossaryScroll.drawsBackground = false
        glossaryView.drawsBackground = false
        glossaryView.autoresizingMask = [.width]
        glossaryScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        glossaryScroll.widthAnchor.constraint(equalToConstant: SettingsForm.pageWidth - 64).isActive = true

        return SettingsForm.page([
            SettingsForm.section(String(localized: "Language Model"), rows: [
                SettingsForm.row(String(localized: "Improve subtitles"), description: String(localized: "Polish Chinese or translate Japanese"), control: enabledSwitch),
            ], footer: String(localized: "Runs after transcription. Timing never changes.")),
            SettingsForm.section(String(localized: "Correction"), rows: [
                SettingsForm.row(String(localized: "Fix recognition mistakes"), description: String(localized: "Correct the Japanese while translating it"), control: proofreadSwitch),
                SettingsForm.row(String(localized: "Remove invented lines"), description: String(localized: "Outros, credits and loops that were never said"), control: removesHallucinationsSwitch),
            ], footer: String(localized: "Corrections come in the same request as the translation and replace the recognized Japanese. Lines the speech model was unsure of are checked with extra care; removed lines are listed in the Activity window.")),
            SettingsForm.section(String(localized: "Service"), rows: [
                SettingsForm.row(String(localized: "Provider"), control: providerPopUp),
                SettingsForm.row(String(localized: "Base URL"), control: SettingsForm.field(baseURLField)),
                SettingsForm.row(String(localized: "API key"), descriptionLabel: apiKeyDescription, control: apiKeyControls),
                SettingsForm.row(String(localized: "Model"), descriptionLabel: modelStatusLabel, control: modelControls),
            ], footer: String(localized: "Any OpenAI-compatible API. OpenRouter lists only models with structured output.")),
            SettingsForm.section(String(localized: "Translation"), rows: [
                SettingsForm.row(String(localized: "Translate into"), description: String(localized: "When the LLM translates"), control: SettingsForm.field(languageBox)),
                SettingsForm.row(String(localized: "Bilingual subtitles"), description: String(localized: "The original under each translated line"), control: keepsOriginalSwitch),
            ], footer: String(localized: "Applies to every format: a second line in SRT, VTT and TXT, a smaller grey line in ASS, a second lyric at the same time in LRC. The editor shows the translation only.")),
            SettingsForm.section(String(localized: "Glossary"), rows: [
                SettingsForm.row(control: glossaryScroll),
            ], footer: String(localized: "One per line: source = translation")),
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
        proofreadSwitch.state = llm.proofreadsTranscript ? .on : .off
        removesHallucinationsSwitch.state = llm.removesHallucinations ? .on : .off
        let provider = viewModel.llmProvider
        providerPopUp.selectItem(at: LLMProvider.allCases.firstIndex(of: provider) ?? 0)
        if baseURLField.currentEditor() == nil {
            baseURLField.stringValue = llm.baseURL.absoluteString
        }
        if apiKeyField.currentEditor() == nil {
            apiKeyField.stringValue = viewModel.apiKey
        }
        apiKeyField.placeholderString = provider.needsAPIKey ? String(localized: "Required") : String(localized: "Not needed")
        apiKeyDescription.stringValue = viewModel.apiKeyProblem ?? String(localized: "Stored in Keychain")
        apiKeyDescription.textColor = viewModel.apiKeyProblem == nil ? .secondaryLabelColor : .systemRed
        baseURLField.contentType = .URL
        getKeyButton?.isHidden = provider.keysPage == nil
        if languageBox.currentEditor() == nil {
            languageBox.stringValue = llm.targetLanguage
        }
        if glossaryView.window?.firstResponder !== glossaryView, glossaryView.string != llm.glossary {
            glossaryView.string = llm.glossary
        }
        renderModels(selectedID: llm.model)
    }

    private func renderModels(selectedID: String) {
        let ids = viewModel.availableModels.map(\.id)
        if (modelBox.objectValues as? [String]) != ids {
            modelBox.removeAllItems()
            modelBox.addItems(withObjectValues: ids)
        }
        if modelBox.currentEditor() == nil {
            modelBox.stringValue = selectedID
        }

        modelStatusLabel.stringValue = switch viewModel.modelListState {
        case .notLoaded, .loading: String(localized: "Loading…")
        case .loaded: String(localized: "\(viewModel.availableModels.count) models")
        case .failed(let message): message
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

    @objc private func proofreadChanged(_ sender: NSSwitch) {
        viewModel.setProofreadsTranscript(sender.state == .on)
    }

    @objc private func removesHallucinationsChanged(_ sender: NSSwitch) {
        viewModel.setRemovesHallucinations(sender.state == .on)
    }

    @objc private func apiKeyChanged(_ sender: NSSecureTextField) {
        viewModel.setAPIKey(sender.stringValue)
    }

    @objc private func modelChanged(_ sender: NSComboBox) {
        viewModel.setModel(sender.stringValue)
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let provider = LLMProvider.allCases[sender.indexOfSelectedItem]
        if provider == .custom {
            view.window?.makeFirstResponder(baseURLField)  // the user types the URL
        } else {
            viewModel.setLLMProvider(provider)
        }
    }

    @objc private func baseURLChanged(_ sender: NSTextField) {
        commitBaseURL()
    }

    private func commitBaseURL() {
        if !viewModel.setLLMBaseURL(text: baseURLField.stringValue) {
            NSSound.beep()
            baseURLField.stringValue = viewModel.settings.llm.baseURL.absoluteString
        }
    }

    @objc private func languageChanged(_ sender: NSComboBox) {
        viewModel.setTargetLanguage(sender.stringValue)
    }

    @objc private func refreshModels(_ sender: Any?) {
        viewModel.loadModels()
    }

    @objc private func openKeyPage(_ sender: Any?) {
        if let url = viewModel.llmProvider.keysPage {
            NSWorkspace.shared.open(url)
        }
    }
}

extension LLMSettingsViewController: NSTextViewDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    func textDidChange(_ notification: Notification) {
        viewModel.setGlossary(glossaryView.string)
    }

    /// The key is saved as it is typed, so closing the window right after
    /// pasting it cannot lose it.
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSSecureTextField) === apiKeyField {
            viewModel.setAPIKey(apiKeyField.stringValue)
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSComboBox) === modelBox, let modelID = modelBox.objectValueOfSelectedItem as? String {
            viewModel.setModel(modelID)
        } else if let language = languageBox.objectValueOfSelectedItem as? String {
            viewModel.setTargetLanguage(language)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSSecureTextField) === apiKeyField {
            viewModel.setAPIKey(apiKeyField.stringValue)
        } else if (notification.object as? NSTextField) === baseURLField {
            commitBaseURL()
        } else if (notification.object as? NSComboBox) === modelBox {
            viewModel.setModel(modelBox.stringValue)
        } else if (notification.object as? NSComboBox) === languageBox {
            viewModel.setTargetLanguage(languageBox.stringValue)
        }
    }
}
