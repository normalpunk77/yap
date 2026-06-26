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
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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

    /// One-time hygiene: wipe any plaintext API keys left in UserDefaults by older builds (the
    /// keys now live in the Keychain), in both the current and legacy `com.dictabar` domains,
    /// so no plaintext key lingers on disk.
    static func purgeLegacyPlaintextKeys() {
        let keys = ["elevenlabs-api-key", "deepgram-api-key"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        if let legacy = UserDefaults(suiteName: "com.dictabar") {
            for key in keys { legacy.removeObject(forKey: key) }
        }
    }
}
