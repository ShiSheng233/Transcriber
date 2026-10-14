import Foundation
import Security

/// Keeps LLM API keys in the login Keychain rather than in settings, one per
/// service (base URL host and port), so switching services keeps each key.
final class APIKeyStore {
    private let service = "dev.shisheng.Transcriber"

    func read(for baseURL: URL) -> String {
        var query = baseQuery(for: baseURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty key deletes the stored one.
    func save(_ key: String, for baseURL: URL) {
        SecItemDelete(baseQuery(for: baseURL) as CFDictionary)
        guard !key.isEmpty else {
            return
        }
        var item = baseQuery(for: baseURL)
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// OpenRouter keeps the account name it had before other services existed.
    private static func account(for baseURL: URL) -> String {
        guard let host = baseURL.host(), !host.hasSuffix("openrouter.ai") else {
            return "openrouter"
        }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    private func baseQuery(for baseURL: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: baseURL),
        ]
    }
}
