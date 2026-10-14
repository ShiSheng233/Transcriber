import Foundation
import Security

/// Keeps the OpenRouter API key in the login Keychain rather than in settings.
final class APIKeyStore {
    private let service = "dev.shisheng.Transcriber"
    private let account = "openrouter"

    func read() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty key deletes the stored one.
    func save(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !key.isEmpty else {
            return
        }
        var item = baseQuery
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
