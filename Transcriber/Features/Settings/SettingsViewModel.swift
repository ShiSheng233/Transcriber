import Foundation
import JobQueue
import Observation
import SubtitleExport
import TranscriberCore

/// Edits the app settings and reports whether the chosen models are present.
@Observable
final class SettingsViewModel {
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
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
}
