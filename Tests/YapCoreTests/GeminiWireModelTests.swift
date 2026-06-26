import XCTest
@testable import YapCore

final class GeminiWireModelTests: XCTestCase {
    func testRequestBodyShape() throws {
        let data = try GeminiWire.requestBody(prompt: "SYS", transcript: "hello world")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sys = obj["systemInstruction"] as! [String: Any]
        let sysParts = sys["parts"] as! [[String: Any]]
        XCTAssertEqual(sysParts.first?["text"] as? String, "SYS")
        let contents = obj["contents"] as! [[String: Any]]
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        let userParts = contents.first?["parts"] as! [[String: Any]]
        XCTAssertEqual(userParts.first?["text"] as? String, "hello world")
        let gen = obj["generationConfig"] as! [String: Any]
        XCTAssertEqual(gen["temperature"] as? Double, 0)
    }

    func testParseTextExtractsCandidate() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hello, world."}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiWire.parseText(json), "Hello, world.")
    }

    func testParseTextConcatenatesMultipleParts() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hello, "},{"text":"world."}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiWire.parseText(json), "Hello, world.")
    }

    func testParseTextThrowsOnNoCandidates() {
        let json = #"{"candidates":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiWire.parseText(json)) { error in
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }

    func testParseTextThrowsOnBlockedEmpty() {
        let json = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiWire.parseText(json)) { error in
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }
}
