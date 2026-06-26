import XCTest
@testable import YapCore

final class ElevenLabsWireModelTests: XCTestCase {
    func testInputAudioChunkEncodesExactKeys() throws {
        let chunk = InputAudioChunk(audioBase64: "AAAB", sampleRate: 16000)
        let data = try JSONEncoder().encode(chunk)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(obj["audio_base_64"] as? String, "AAAB")
        XCTAssertEqual(obj["commit"] as? Bool, false)
        XCTAssertEqual(obj["sample_rate"] as? Int, 16000)
    }

    func testDecodePartial() throws {
        let json = #"{"message_type":"partial_transcript","text":"ciao"}"#.data(using: .utf8)!
        XCTAssertEqual(try ElevenLabsResponse.decode(json), .partial("ciao"))
    }

    func testDecodeCommitted() throws {
        let json = #"{"message_type":"committed_transcript","text":"ciao mondo"}"#.data(using: .utf8)!
        XCTAssertEqual(try ElevenLabsResponse.decode(json), .committed("ciao mondo"))
    }

    func testDecodeAuthErrorByMessageType() throws {
        let json = #"{"message_type":"auth_error"}"#.data(using: .utf8)!
        XCTAssertEqual(try ElevenLabsResponse.decode(json), .error(.authenticationFailed))
    }

    func testDecodeQuotaErrorByMessageType() throws {
        let json = #"{"message_type":"quota_exceeded"}"#.data(using: .utf8)!
        XCTAssertEqual(try ElevenLabsResponse.decode(json), .error(.quotaExceeded))
    }

    func testDecodeUnknownTypeIsIgnored() throws {
        let json = #"{"message_type":"session_started"}"#.data(using: .utf8)!
        XCTAssertEqual(try ElevenLabsResponse.decode(json), .ignored)
    }

    func testDecodeMalformedThrows() {
        let json = #"{"no_type":true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ElevenLabsResponse.decode(json))
    }
}
