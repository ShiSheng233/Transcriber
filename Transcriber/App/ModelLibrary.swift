import Foundation
import Observation
import TranscriberCore

/// The models installed in the chosen models folder, read from their
/// model.json files. Rescanned when the folder changes or on request.
@Observable
final class ModelLibrary {
    private let settingsStore: SettingsStore
    private(set) var catalog: ModelCatalog
    private var scannedDirectory: URL

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let directory = settingsStore.settings.modelsDirectory
        scannedDirectory = directory
        catalog = ModelCatalog.scan(directory)
    }

    var models: [RecognitionModel] {
        catalog.models
    }

    /// The model new files use: the chosen one, else the first installed one.
    var selectedModel: RecognitionModel? {
        catalog.model(withID: settingsStore.settings.modelID) ?? catalog.models.first
    }

    func reload() {
        scannedDirectory = settingsStore.settings.modelsDirectory
        catalog = ModelCatalog.scan(scannedDirectory)
    }

    func reloadIfFolderChanged() {
        if settingsStore.settings.modelsDirectory != scannedDirectory {
            reload()
        }
    }
}
