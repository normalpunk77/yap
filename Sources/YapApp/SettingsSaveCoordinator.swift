import Foundation
import YapCore

enum SettingsSaveCoordinator {
    @MainActor
    static func commitIfVerified(_ verification: String, commit: () -> Void) {
        guard verification.hasPrefix("✓") else { return }
        commit()
    }
}

enum STTSettingsSaveCoordinator {
    static func verificationResult(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .elevenLabs:
            return "✓ Valid key — saved"
        case .deepgram:
            return "✓ Valid key — saved"
        case .parakeetLocal:
            return "✓ On-device engine selected"
        }
    }

    static func shouldPersistAPIKey(for provider: TranscriptionProvider) -> Bool {
        !provider.isLocal
    }
}
