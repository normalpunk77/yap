import Foundation
import Security
import YapCore

/// Per-provider API-key storage in the macOS **Keychain** (encrypted at rest, access-
/// controlled by the OS — NOT readable by a plain `defaults read`, unlike the old plaintext
/// UserDefaults store). Stored as a generic-password item per provider.
///
/// Note on rebuilds: the Keychain ties access to the app's code signature. An installed copy
/// has a stable signature, so the key persists. If you rebuild with a *different* ad-hoc
/// signature you may have to re-enter it — create the stable `Yap Self-Signed` identity (see
/// scripts/build-app.sh) to avoid that. The security win (no plaintext on disk) holds either way.
enum APIKeyStore {
    private static let didMigrateLegacyKeychainKeysFlag = "didMigrateLegacyKeychainKeys"
    private static let didPurgeLegacyPlaintextKeysFlag = "didPurgeLegacyPlaintextKeys"

    private static func service(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .elevenLabs:   return "com.yap.elevenlabs-api-key"
        case .deepgram:     return "com.yap.deepgram-api-key"
        case .parakeetLocal: return "com.yap.parakeet"  // local: no key, never stored
        }
    }
    private static let account = "api-key"

    static func saveAPIKey(_ value: String, for provider: TranscriptionProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // upsert: clear any existing, then add
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // empty = cleared (opt out)
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        // Foreground dictation app: no need to reach the key while the screen is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAPIKey(for provider: TranscriptionProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Bundle ids the app shipped under before settling on `com.yap`. Their Keychain items use
    /// the same per-provider suffix and `api-key` account, just a different service prefix.
    private static let legacyServicePrefixes = ["io.github.normalpunk77.yap"]

    private static func legacyService(prefix: String, for provider: TranscriptionProvider) -> String? {
        switch provider {
        case .elevenLabs:    return "\(prefix).elevenlabs-api-key"
        case .deepgram:      return "\(prefix).deepgram-api-key"
        case .parakeetLocal: return nil   // local: no key was ever stored
        }
    }

    /// One-time migration: the bundle id rename (`io.github.normalpunk77.yap` → `com.yap`)
    /// changed the Keychain service prefix, so a key the user saved under the old name would
    /// silently vanish from the UI after upgrading. Copy any old-name key to the new service
    /// (only when the new slot is empty) and delete the orphan, so existing users keep their key.
    static func migrateLegacyKeychainKeys() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didMigrateLegacyKeychainKeysFlag) else { return }
        for provider in [TranscriptionProvider.elevenLabs, .deepgram] {
            if loadAPIKey(for: provider) != nil { continue }   // already present under com.yap
            for prefix in legacyServicePrefixes {
                guard let old = legacyService(prefix: prefix, for: provider) else { continue }
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: old,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                      let data = item as? Data,
                      let value = String(data: data, encoding: .utf8), !value.isEmpty else { continue }
                saveAPIKey(value, for: provider)   // writes under the new com.yap service
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: old,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
                break
            }
        }
        defaults.set(true, forKey: didMigrateLegacyKeychainKeysFlag)
    }

    /// One-time hygiene: wipe any plaintext API keys left in UserDefaults by older builds (the
    /// keys now live in the Keychain), in both the current and legacy `com.dictabar` domains,
    /// so no plaintext key lingers on disk.
    static func purgeLegacyPlaintextKeys() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didPurgeLegacyPlaintextKeysFlag) else { return }
        let keys = ["elevenlabs-api-key", "deepgram-api-key"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        if let legacy = UserDefaults(suiteName: "com.dictabar") {
            for key in keys { legacy.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: didPurgeLegacyPlaintextKeysFlag)
    }
}
