import Foundation
import YapCore

/// Per-provider API-key storage.
///
/// Backed by `UserDefaults`, NOT the macOS Keychain — deliberately, and named honestly
/// so this is obvious. This app is distributed as source and self-/ad-hoc signed, so its
/// code signature changes on every local rebuild; the Keychain's ACL is keyed to that
/// signature and would deny access to a previously-saved item after a rebuild (silently
/// breaking key load). `UserDefaults` survives rebuilds, which matters for a tool you
/// build yourself.
///
/// Tradeoff: the key is stored in plaintext in `~/Library/Preferences/io.github.normalpunk77.yap.plist`,
/// readable by processes running as you. That is the same trust boundary as most local
/// dev tools holding your own API key. The key never leaves your machine except to the
/// speech-to-text provider you explicitly configure. See SECURITY.md.
enum APIKeyStore {
    private static func defaultsKey(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .elevenLabs: return "elevenlabs-api-key"   // unchanged → existing keys survive
        case .deepgram:   return "deepgram-api-key"
        }
    }

    static func saveAPIKey(_ value: String, for provider: TranscriptionProvider) {
        UserDefaults.standard.set(value, forKey: defaultsKey(for: provider))
    }

    static func loadAPIKey(for provider: TranscriptionProvider) -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey(for: provider))
        return (value?.isEmpty == false) ? value : nil
    }
}
