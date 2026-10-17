import Foundation
import JobQueue
import Testing

/// The Engine pop-up's three choices and what the queue gets from them, kept
/// in a defaults suite of the test's own (never the app's) with keys in memory.
final class SettingsViewModelEngineTests {
    private let suiteName = "TranscriberTests.Engine.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeViewModel() -> (SettingsViewModel, SettingsStore) {
        let store = SettingsStore(userDefaults: defaults)
        let viewModel = SettingsViewModel(store: store, apiKeyStore: KeysInMemory(), library: ModelLibrary(settingsStore: store))
        return (viewModel, store)
    }

    @Test func startsWithTheNeuralEngineEncoder() {
        let (viewModel, store) = makeViewModel()
        #expect(viewModel.engineChoice == .whisperCppNeuralEngine)
        let engine = store.settings.queueConfiguration(apiKeys: KeysInMemory()).engine
        #expect(engine.backend == .whisperCpp && engine.usesNeuralEngineEncoder)
    }

    @Test(arguments: SettingsViewModel.EngineChoice.allCases)
    func everyChoiceReadsBackAsChosen(choice: SettingsViewModel.EngineChoice) {
        let (viewModel, store) = makeViewModel()
        viewModel.setEngine(choice)
        #expect(viewModel.engineChoice == choice)
        let engine = store.settings.queueConfiguration(apiKeys: KeysInMemory()).engine
        switch choice {
        case .whisperCppMetal: #expect(engine.backend == .whisperCpp && !engine.usesNeuralEngineEncoder)
        case .whisperCppNeuralEngine: #expect(engine.backend == .whisperCpp && engine.usesNeuralEngineEncoder)
        case .mlx: #expect(engine.backend == .mlx)
        }
    }

    @Test func settingsSavedBeforeTheChoiceExistedUseTheNeuralEngine() throws {
        var saved = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        saved["usesNeuralEngineEncoder"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "AppSettings")

        let (viewModel, _) = makeViewModel()
        #expect(viewModel.engineChoice == .whisperCppNeuralEngine)
    }
}

private final class KeysInMemory: APIKeyStoring {
    private var keys: [URL: String] = [:]

    func read(for baseURL: URL) -> String {
        keys[baseURL] ?? ""
    }

    func save(_ key: String, for baseURL: URL) {
        keys[baseURL] = key.isEmpty ? nil : key
    }
}
