import JobQueue

/// Creates the services once and hands them to view models.
final class AppEnvironment {
    let settingsStore = SettingsStore()
    let apiKeyStore = APIKeyStore()
    let jobQueue = JobQueue()
}
