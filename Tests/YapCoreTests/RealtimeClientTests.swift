import XCTest
@testable import YapApp
@testable import YapCore

final class FakeSocket: TranscriptionSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake.socket")
    private(set) var sent: [Data] = []
    private var inbox: [Data]
    private var idx = 0

    private(set) var closed = false

    init(inbox: [Data]) { self.inbox = inbox }

    func send(_ data: Data) async throws { queue.sync { sent.append(data) } }
    func receive() async throws -> Data {
        try await Task.sleep(nanoseconds: 1_000_000)
        return queue.sync {
            guard idx < inbox.count else { return Data() } // empty => treat as closed below
            defer { idx += 1 }
            return inbox[idx]
        }
    }
    func close() async { closed = true }
}

final class ElevenLabsRealtimeClientTests: XCTestCase {
    func testSendChunkEncodesInputAudioFrame() async throws {
        let socket = FakeSocket(inbox: [])
        let client = ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
        try await client.sendChunk(Data([0x00, 0x01]))
        let obj = try JSONSerialization.jsonObject(with: socket.sent[0]) as! [String: Any]
        XCTAssertEqual(obj["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(obj["sample_rate"] as? Int, 16000)
    }

    func testSendCommitEncodesEmptyChunkWithCommitTrue() async throws {
        let socket = FakeSocket(inbox: [])
        let client = ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
        try await client.sendCommit()
        let obj = try JSONSerialization.jsonObject(with: socket.sent[0]) as! [String: Any]
        XCTAssertEqual(obj["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(obj["commit"] as? Bool, true)
        XCTAssertEqual(obj["audio_base_64"] as? String, "")
    }

    func testEventsStreamSurfacesPartialThenCommitted() async throws {
        let inbox = [
            #"{"message_type":"partial_transcript","text":"ci"}"#.data(using: .utf8)!,
            #"{"message_type":"committed_transcript","text":"ciao"}"#.data(using: .utf8)!,
        ]
        let socket = FakeSocket(inbox: inbox)
        let client = ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
        var received: [TranscriptEvent] = []
        for await ev in client.events() {
            received.append(ev)
            if case .committed = ev { break }
        }
        XCTAssertEqual(received, [.partial("ci"), .committed("ciao")])
    }

    func testUndecodableFrameIsSkippedNotFatal() async throws {
        // Regression: a frame missing `message_type` (malformedFrame) or that isn't valid JSON
        // used to end the stream with `.failed`, aborting the whole dictation on ONE bad message.
        // Such frames must be skipped so a transient/unknown server message can't kill a session.
        let inbox = [
            #"{"message_type":"partial_transcript","text":"ci"}"#.data(using: .utf8)!,
            #"{"unexpected":true}"#.data(using: .utf8)!,         // no message_type → malformedFrame
            Data("not json at all".utf8),                         // DecodingError
            #"{"message_type":"committed_transcript","text":"ciao"}"#.data(using: .utf8)!,
        ]
        let socket = FakeSocket(inbox: inbox)
        let client = ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
        var received: [TranscriptEvent] = []
        for await ev in client.events() {
            received.append(ev)
            if case .committed = ev { break }
        }
        XCTAssertEqual(received, [.partial("ci"), .committed("ciao")])   // bad frames skipped
    }

    func testCloseForwardsToSocket() async {
        let socket = FakeSocket(inbox: [])
        let client = ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
        await client.close()
        XCTAssertTrue(socket.closed)
    }
}

final class DeepgramRealtimeClientTests: XCTestCase {
    func testSendCommitSendsFinalize() async throws {
        let socket = FakeSocket(inbox: [])
        let client = DeepgramRealtimeClient(socket: socket)
        try await client.sendCommit()
        let obj = try JSONSerialization.jsonObject(with: socket.sent[0]) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "Finalize")
    }

    func testEventsParseInterimThenFinal() async throws {
        let inbox = [
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"ci"}]}}"#.data(using: .utf8)!,
            #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"ciao"}]}}"#.data(using: .utf8)!,
        ]
        let socket = FakeSocket(inbox: inbox)
        let client = DeepgramRealtimeClient(socket: socket)
        var received: [TranscriptEvent] = []
        for await ev in client.events() {
            received.append(ev)
            if case .committed = ev { break }
        }
        XCTAssertEqual(received, [.partial("ci"), .committed("ciao")])
    }

    func testUndecodableFrameIsSkippedNotFatal() async throws {
        // Regression: an undecodable frame used to fall through to the generic catch and be
        // mislabeled `.socketClosed`, triggering a pointless reconnect. It must be skipped so
        // the stream keeps delivering real results.
        let inbox = [
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"ci"}]}}"#.data(using: .utf8)!,
            Data("}{ not json".utf8),                              // DecodingError → skip
            #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"ciao"}]}}"#.data(using: .utf8)!,
        ]
        let socket = FakeSocket(inbox: inbox)
        let client = DeepgramRealtimeClient(socket: socket)
        var received: [TranscriptEvent] = []
        for await ev in client.events() {
            received.append(ev)
            if case .committed = ev { break }
        }
        XCTAssertEqual(received, [.partial("ci"), .committed("ciao")])   // bad frame skipped
    }
}
