import Foundation

/// Decodes Deepgram streaming `Results` frames into our provider-neutral outcome.
/// Deepgram sends `{"type":"Results","is_final":bool,"channel":{"alternatives":[{"transcript":"…"}]}}`
/// continuously: `is_final:false` are interim (partial) updates, `is_final:true` are
/// final segments (committed). Non-`Results` frames (Metadata, UtteranceEnd, …) and
/// empty transcripts are ignored.
enum DeepgramResponse: Equatable {
    case partial(String)
    case committed(String)
    case ignored

    private struct Frame: Decodable {
        let type: String?
        let isFinal: Bool?
        let channel: Channel?
        struct Channel: Decodable { let alternatives: [Alternative]? }
        struct Alternative: Decodable { let transcript: String? }
        enum CodingKeys: String, CodingKey {
            case type
            case isFinal = "is_final"
            case channel
        }
    }

    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> DeepgramResponse {
        let frame = try decoder.decode(Frame.self, from: data)
        guard frame.type == "Results" else { return .ignored }
        let transcript = frame.channel?.alternatives?.first?.transcript ?? ""
        guard !transcript.isEmpty else { return .ignored }
        return (frame.isFinal == true) ? .committed(transcript) : .partial(transcript)
    }
}
