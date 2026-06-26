import Foundation

struct InputAudioChunk: Encodable, Equatable {
    let audioBase64: String
    let sampleRate: Int
    var commit: Bool = false
    /// Context for the model, sent ONLY on the first chunk after a reconnect so it
    /// continues coherently across the network gap (per the realtime docs). Omitted
    /// from the wire when nil — sending it on a later chunk is an error.
    var previousText: String? = nil
    private let messageType = "input_audio_chunk"

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case audioBase64 = "audio_base_64"
        case commit
        case sampleRate = "sample_rate"
        case previousText = "previous_text"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messageType, forKey: .messageType)
        try c.encode(audioBase64, forKey: .audioBase64)
        try c.encode(commit, forKey: .commit)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encodeIfPresent(previousText, forKey: .previousText)
    }
}

enum ElevenLabsResponse: Equatable {
    case partial(String)
    case committed(String)
    case error(TranscriptionError)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
    }

    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ElevenLabsResponse {
        return try decoder.decode(ElevenLabsResponse.self, from: data)
    }
}

extension ElevenLabsResponse: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try c.decodeIfPresent(String.self, forKey: .messageType) else {
            throw TranscriptionError.malformedFrame
        }
        switch type {
        case "partial_transcript":
            self = .partial(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            self = .committed(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        default:
            // Each error is its own message_type (auth_error, quota_exceeded, …);
            // anything not an error (session_started, future events) is ignored.
            if let error = TranscriptionError.mapped(fromMessageType: type) {
                self = .error(error)
            } else {
                self = .ignored
            }
        }
    }
}
