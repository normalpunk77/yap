import Foundation

/// The speech-to-text backend a session talks to. Used to pick the client and the
/// per-provider API key. ElevenLabs is the default.
public enum TranscriptionProvider: String, CaseIterable, Sendable {
    case elevenLabs
    case deepgram
    case parakeetLocal

    public var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs (Scribe v2)"
        case .deepgram: return "Deepgram (Nova-3)"
        case .parakeetLocal: return "Parakeet (on-device)"
        }
    }

    /// Runs entirely on-device — no API key, no network.
    public var isLocal: Bool { self == .parakeetLocal }
}
