import Foundation
import JobQueue
import LLMTranslation
import Observation
import SubtitleExport
import TranscriberCore

/// Edits the app settings and reports whether the chosen models are present.
@Observable
final class SettingsViewModel {
    enum ModelListState: Equatable {
        case notLoaded
        case loading
        case loaded
        case failed(message: String)
    }

    private let store: SettingsStore
    private let apiKeyStore: APIKeyStore
    private let library: ModelLibrary

    private(set) var apiKey: String
    private(set) var availableModels: [OpenRouterModel] = []
    private(set) var modelListState = ModelListState.notLoaded

    struct ModelChoice: Equatable {
        let id: String
        let title: String
    }

    /// Menu entries: the loaded models, plus the chosen one if the list lacks it.
    var modelChoices: [ModelChoice] {
        var choices = availableModels.map { ModelChoice(id: $0.id, title: $0.name) }
        let selectedID = settings.llm.model
        if !selectedID.isEmpty, !choices.contains(where: { $0.id == selectedID }) {
            choices.insert(ModelChoice(id: selectedID, title: selectedID), at: 0)
        }
        return choices
    }

    init(store: SettingsStore, apiKeyStore: APIKeyStore, library: ModelLibrary) {
        self.store = store
        self.apiKeyStore = apiKeyStore
        self.library = library
        self.apiKey = apiKeyStore.read()
    }

    var settings: AppSettings {
        store.settings
    }

    struct ModelStatus: Equatable {
        let title: String
        let detail: String
        let isReady: Bool
    }

    /// Each installed model and whether the chosen engine can run it, then the
    /// VAD models they use, then any model.json that could not be read.
    var modelStatuses: [ModelStatus] {
        let fileManager = FileManager.default
        let catalog = library.catalog
        var statuses = catalog.models.map { model in
            let weights = settings.backend == .whisperCpp ? model.files.whisperCpp : model.files.mlx
            let isReady = weights.map { fileManager.fileExists(atPath: $0.path) } == true
                && fileManager.fileExists(atPath: model.files.tokenizer.path)
            let detail = isReady
                ? model.summary
                : String(localized: "No \(settings.backend.displayName) weights in \(model.directory.lastPathComponent)/")
            return ModelStatus(title: model.displayName, detail: detail, isReady: isReady)
        }
        for vadModel in Set(catalog.models.map(\.vadModelName)).sorted() {
            let path = "vad/\(vadModel).mlmodelc"
            statuses.append(ModelStatus(
                title: String(localized: "Voice activity detection"),
                detail: path,
                isReady: fileManager.fileExists(atPath: settings.modelsDirectory.appendingPathComponent(path).path)
            ))
        }
        for problem in catalog.problems {
            let folder = problem.configurationURL.deletingLastPathComponent().lastPathComponent
            statuses.append(ModelStatus(title: folder, detail: String(localized: "model.json could not be read"), isReady: false))
        }
        return statuses
    }

    var hasNoModels: Bool {
        library.models.isEmpty
    }

    // MARK: Intents

    func setModelsDirectory(_ url: URL) {
        store.update { $0.modelsDirectory = url }
        library.reload()
    }

    /// Picks up models added to or removed from the folder.
    func reloadModels() {
        library.reload()
    }



    func setBackend(_ backend: EngineSettings.Backend) {
        store.update { $0.backend = backend }
    }

    func setConcurrentChunkCount(_ count: Int) {
        store.update { $0.concurrentChunkCount = count }
    }

    func setFormat(_ format: SubtitleFormat, isEnabled: Bool) {
        store.update { settings in
            var enabled = Set(settings.formats)
            if isEnabled {
                enabled.insert(format)
            } else {
                enabled.remove(format)
            }
            settings.formats = SubtitleFormat.allCases.filter(enabled.contains)  // keep a stable order
        }
    }

    func setOutputDirectory(_ url: URL?) {
        store.update { $0.outputDirectory = url }
    }

    // MARK: LLM intents

    func setLLMEnabled(_ isEnabled: Bool) {
        store.update { $0.llm.isEnabled = isEnabled }
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyStore.save(trimmed)
        apiKey = trimmed
    }

    func setModel(_ modelID: String) {
        store.update { $0.llm.model = modelID }
    }

    func setTargetLanguage(_ language: String) {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update { $0.llm.targetLanguage = trimmed.isEmpty ? LLMSettings.defaults.targetLanguage : trimmed }
    }

    func setKeepsOriginalLine(_ keepsOriginalLine: Bool) {
        store.update { $0.llm.keepsOriginalLine = keepsOriginalLine }
    }

    func setGlossary(_ glossary: String) {
        store.update { $0.llm.glossary = glossary }
    }

    /// Fetches the models that support structured output (no API key needed).
    func loadModels() {
        guard modelListState != .loading else {
            return
        }
        modelListState = .loading
        Task {
            do {
                availableModels = try await OpenRouterClient.structuredOutputModels()
                modelListState = .loaded
            } catch {
                modelListState = .failed(message: error.localizedDescription)
            }
        }
    }
}
