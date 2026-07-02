import Foundation
import Security
import YapCore

/// Shared low-level Keychain plumbing for the app's secret stores (`APIKeyStore`,
/// `LLMCredentialStore`). One home for the SecItem calls so save/read/delete behave —
/// and FAIL — consistently everywhere. Statuses are never swallowed: a refused
/// operation is logged and reported to the caller.
enum KeychainStore {
    /// A read either finds a value, finds nothing, or FAILS (locked keychain, ACL
    /// denied after a code-signature change, …). Callers must not collapse `failed`
    /// into "no key saved": that misdiagnosis tells users to re-enter a key that is
    /// still there.
    enum ReadOutcome: Equatable {
        case found(String)
        case missing
        case failed(OSStatus)
    }

    static func read(service: String, account: String) -> ReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .missing }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            Diag.app.error("keychain read failed for \(service, privacy: .public): OSStatus \(status)")
            return .failed(status)
        }
    }

    /// Upsert. An empty (post-trim) value deletes the item. Returns false when the
    /// Keychain refused — callers surface that instead of pretending the save landed.
    /// Add-then-update, NOT delete-then-add: if the second half of a delete→add pair
    /// failed, the user's existing key was destroyed while the UI showed success.
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(service: service, account: account) }
        var attributes = base
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        // Foreground dictation app: no need to reach the secret while the screen is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, [
                kSecValueData as String: Data(trimmed.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ] as CFDictionary)
        }
        if status != errSecSuccess {
            Diag.app.error("keychain save failed for \(service, privacy: .public): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    /// Returns true when the item is gone (deleted or never existed).
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Diag.app.error("keychain delete failed for \(service, privacy: .public): OSStatus \(status)")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
