import JobQueue
import LLMTranslation

/// Creates the services once and hands them to view models.
final class AppEnvironment {
    let settingsStore = SettingsStore()
    let apiKeyStore = APIKeyStore()
    /// Finished LLM batches are kept two weeks, so a stopped or failed run
    /// started again does not pay for them twice.
    let jobQueue = JobQueue(llmReplyCache: LLMReplyCache(directory: LLMReplyCache.standardDirectory))
    private(set) lazy var modelLibrary = ModelLibrary(settingsStore: settingsStore)
    private(set) lazy var activityViewModel = ActivityViewModel(queue: jobQueue)
}
