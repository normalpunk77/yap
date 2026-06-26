import XCTest
@testable import YapCore

final class DeepgramWireModelTests: XCTestCase {
    private func frame(isFinal: Bool, transcript: String) -> Data {
        #"{"type":"Results","is_final":\#(isFinal),"channel":{"alternatives":[{"transcript":"\#(transcript)"}]}}"#
            .data(using: .utf8)!
    }

    func testInterimIsPartial() throws {
        XCTAssertEqual(try DeepgramResponse.decode(frame(isFinal: false, transcript: "ciao")), .partial("ciao"))
    }

    func testFinalIsCommitted() throws {
        XCTAssertEqual(try DeepgramResponse.decode(frame(isFinal: true, transcript: "ciao mondo")), .committed("ciao mondo"))
    }

    func testEmptyTranscriptIgnored() throws {
        XCTAssertEqual(try DeepgramResponse.decode(frame(isFinal: true, transcript: "")), .ignored)
    }

    func testNonResultsTypeIgnored() throws {
        let meta = #"{"type":"Metadata","request_id":"abc"}"#.data(using: .utf8)!
        XCTAssertEqual(try DeepgramResponse.decode(meta), .ignored)
        let uttEnd = #"{"type":"UtteranceEnd","last_word_end":1.2}"#.data(using: .utf8)!
        XCTAssertEqual(try DeepgramResponse.decode(uttEnd), .ignored)
    }
}
