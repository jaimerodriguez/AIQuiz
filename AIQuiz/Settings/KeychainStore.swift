import Foundation
import Security

/// Generic-password Keychain access scoped to one service name. API keys never leave the
/// Keychain (SPEC N-3). UI-test mode uses a separate service so tests never see real keys.
struct KeychainStore: Sendable {
    let service: String

    /// Same service name as v1, so keys saved before 1.1.0 are found and migrated.
    static let production = KeychainStore(service: "com.jaimer.aiquiz")
    static let uiTest = KeychainStore(service: "com.jaimer.aiquiz.uitest")

    func set(_ value: String?, for account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        guard let value, !value.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.ai.error("Keychain add failed for account \(account): \(status)")
        }
    }

    func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
