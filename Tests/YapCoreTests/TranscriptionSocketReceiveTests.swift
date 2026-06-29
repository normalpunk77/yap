import XCTest
@testable import YapApp
@testable import YapCore

/// `URLSessionTranscriptionSocket.receive()` classifies a WebSocket receive failure.
/// The distinction that matters: a *rejected handshake* (non-101 HTTP status) is fatal,
/// while a drop *after* a successful upgrade (status 101) is a recoverable mid-dictation
/// drop the controller reconnects from. Reporting that 101 as a fatal "HTTP 101" was the
/// bug that tore the pipeline down mid-speech.
final class TranscriptionSocketReceiveTests: XCTestCase {
    private struct DummyError: Error {}

    func testStatus101DropIsRecoverableSocketClose() {
        let mapped = URLSessionTranscriptionSocket.classify(receiveFailure: DummyError(), responseStatus: 101)
        XCTAssertEqual(mapped, .socketClosed,
                       "A drop after a successful upgrade (101) must be recoverable, not a fatal HTTP 101")
    }

    func testRejectedHandshakeSurfacesHTTPStatus() {
        XCTAssertEqual(URLSessionTranscriptionSocket.classify(receiveFailure: DummyError(), responseStatus: 401),
                       .unknown("HTTP 401"))
        XCTAssertEqual(URLSessionTranscriptionSocket.classify(receiveFailure: DummyError(), responseStatus: 404),
                       .unknown("HTTP 404"))
    }
}
