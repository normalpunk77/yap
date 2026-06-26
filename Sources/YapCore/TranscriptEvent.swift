import Foundation

public enum TranscriptEvent: Equatable, Sendable {
    case partial(String)
    case committed(String)
    case failed(TranscriptionError)
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case authenticationFailed
    case quotaExceeded
    case rateLimited
    case malformedFrame
    case socketClosed
    case unknown(String)

    /// Maps an ElevenLabs realtime error `message_type` to a typed failure, or
    /// `nil` when the type is not an error (so the caller can ignore it). Per the
    /// realtime STT spec each error is its OWN `message_type`, not a generic
    /// "error" frame.
    static func mapped(fromMessageType type: String) -> TranscriptionError? {
        switch type {
        case "auth_error": return .authenticationFailed
        case "quota_exceeded", "resource_exhausted": return .quotaExceeded
        case "rate_limited": return .rateLimited
        case "input_error", "chunk_size_exceeded", "insufficient_audio_activity",
             "unaccepted_terms", "session_time_limit_exceeded",
             "transcriber_error", "server_error", "error":
            return .unknown(type)
        // `commit_throttled` / `queue_overflow` are transient streaming back-pressure,
        // not an account rate limit — fall through to nil so they are ignored rather
        // than stopping dictation or being mislabelled as "Rate limited".
        default: return nil
        }
    }
}
