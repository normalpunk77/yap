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
    private static let migrateLegacyKeychainAttemptsKey = "migrateLegacyKeychainAttempts"
    private static let didPurgeLegacyPlaintextKeysFlag = "didPurgeLegacyPlaintextKeys"

    private static func service(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .elevenLabs:   return "com.yap.elevenlabs-api-key"
        case .deepgram:     return "com.yap.deepgram-api-key"
        case .parakeetLocal: return "com.yap.parakeet"  // local: no key, never stored
        }
    }
    private static let account = "api-key"

    /// Persist (or, with an empty value, remove) the provider's key. Returns false when
    /// the Keychain refused the operation — the UI surfaces that instead of showing a
    /// green check over a key that was never stored.
    @discardableResult
    static func saveAPIKey(_ value: String, for provider: TranscriptionProvider) -> Bool {
        KeychainStore.save(value, service: service(for: provider), account: account)
    }

    static func loadAPIKey(for provider: TranscriptionProvider) -> String? {
        if case .found(let value) = readAPIKey(for: provider) { return value }
        return nil
    }

    /// Full outcome, for callers that must distinguish "no key saved" from "the
    /// Keychain refused to hand it over" (locked keychain, ACL denied after a
    /// signature change): telling the user to re-enter a key that IS there was the
    /// exact confusion this distinction removes.
    static func readAPIKey(for provider: TranscriptionProvider) -> KeychainStore.ReadOutcome {
        KeychainStore.read(service: service(for: provider), account: account)
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
    /// The old item is deleted only once the copy VERIFIABLY landed, and the one-shot flag is
    /// burned only when every provider migrated cleanly — a locked keychain at first launch
    /// must not permanently skip the migration.
    static func migrateLegacyKeychainKeys() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didMigrateLegacyKeychainKeysFlag) else { return }
        // Retry a FAILED migration on later launches (locked keychain at login), but
        // only a few times: a legacy item whose ACL the user denies would otherwise
        // re-trigger the keychain permission dialog on EVERY launch, forever.
        let attempts = defaults.integer(forKey: migrateLegacyKeychainAttemptsKey) + 1
        defaults.set(attempts, forKey: migrateLegacyKeychainAttemptsKey)
        var fullyMigrated = true
        for provider in [TranscriptionProvider.elevenLabs, .deepgram] {
            switch readAPIKey(for: provider) {
            case .found:
                continue   // already present under com.yap
            case .failed:
                fullyMigrated = false   // keychain unavailable — retry next launch
                continue
            case .missing:
                break
            }
            for prefix in legacyServicePrefixes {
                guard let old = legacyService(prefix: prefix, for: provider) else { continue }
                switch KeychainStore.read(service: old, account: account) {
                case .missing:
                    continue
                case .failed:
                    fullyMigrated = false
                    continue
                case .found(let value):
                    if saveAPIKey(value, for: provider), case .found = readAPIKey(for: provider) {
                        KeychainStore.delete(service: old, account: account)
                    } else {
                        fullyMigrated = false
                    }
                }
                break
            }
        }
        if fullyMigrated || attempts >= 3 {
            defaults.set(true, forKey: didMigrateLegacyKeychainKeysFlag)
        }
    }

    /// One-time hygiene: wipe any plaintext API keys left in UserDefaults by older builds (the
    /// keys now live in the Keychain), in the current domain and BOTH legacy domains
    /// (`com.dictabar` and the pre-rename `io.github.normalpunk77.yap`), so no plaintext key
    /// lingers on disk.
    static func purgeLegacyPlaintextKeys() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didPurgeLegacyPlaintextKeysFlag) else { return }
        let keys = ["elevenlabs-api-key", "deepgram-api-key"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        for domain in ["com.dictabar", "io.github.normalpunk77.yap"] {
            if let legacy = UserDefaults(suiteName: domain) {
                for key in keys { legacy.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: didPurgeLegacyPlaintextKeysFlag)
    }
}
