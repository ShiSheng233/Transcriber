import AudioOverview
import JobQueue
import LLMTranslation

/// Creates the services once and hands them to view models.
final class AppEnvironment {
    let settingsStore = SettingsStore()
    let apiKeyStore = APIKeyStore()
    let spellChecker = SystemSpellChecker()
    /// Finished LLM batches are kept two weeks, so a stopped or failed run
    /// started again does not pay for them twice.
    /// Waveforms made while transcribing, so timing mode opens at once.
    let waveformCache = WaveformCache(directory: WaveformCache.standardDirectory)
    private(set) lazy var jobQueue = JobQueue(
        llmReplyCache: LLMReplyCache(directory: LLMReplyCache.standardDirectory),
        waveformCache: waveformCache
    )
    private(set) lazy var waveformLoader = WaveformLoader(diskCache: waveformCache)
    private(set) lazy var modelLibrary = ModelLibrary(settingsStore: settingsStore)
    private(set) lazy var activityViewModel = ActivityViewModel(queue: jobQueue)
}
