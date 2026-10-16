import Foundation

/// Where LLM API keys are kept. The app uses the Keychain (`APIKeyStore`);
/// the ViewModel tests are built without that file and use a store in
/// memory, so they can never touch the user's stored keys.
protocol APIKeyStoring: AnyObject {
    func read(for baseURL: URL) -> String
    /// An empty key deletes the stored one.
    func save(_ key: String, for baseURL: URL)
}
