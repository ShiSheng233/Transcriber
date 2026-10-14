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

    init(store: SettingsStore, apiKeyStore: APIKeyStore) {
        self.store = store
        self.apiKeyStore = apiKeyStore
        self.apiKey = apiKeyStore.read()
    }

    var settings: AppSettings {
        store.settings
    }

    struct ModelStatus: Equatable {
        let title: String
        /// Path inside the models folder.
        let relativePath: String
        let isPresent: Bool
    }

    /// The files the chosen engine needs, and whether each is in the models folder.
    var modelStatuses: [ModelStatus] {
        let engine = settings.backend == .whisperCpp ? "whisper.cpp" : "MLX"
        let required: [(title: String, path: String)] = switch settings.backend {
        case .whisperCpp: [
            ("ChickenRice v0.2 · \(engine)", "whisper/chickenrice-v0.2.bin"),
            ("whisper-ja-1.5B · \(engine)", "whisper/whisper-ja-1.5b.bin"),
        ]
        case .mlx: [
            ("ChickenRice v0.2 · \(engine)", "mlx/chickenrice-v0.2/model.safetensors"),
            ("whisper-ja-1.5B · \(engine)", "mlx/whisper-ja-1.5b/model.safetensors"),
        ]
        }
        let all = required + [(String(localized: "Voice activity detection (Core ML)"), "vad/whisper-vad-asmr.mlmodelc")]
        return all.map { model in
            ModelStatus(
                title: model.title,
                relativePath: model.path,
                isPresent: FileManager.default.fileExists(atPath: settings.modelsDirectory.appendingPathComponent(model.path).path)
            )
        }
    }

    // MARK: Intents

    func setModelsDirectory(_ url: URL) {
        store.update { $0.modelsDirectory = url }
    }

    func setTask(_ task: TranscriptionTask) {
        store.update { $0.task = task }
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
