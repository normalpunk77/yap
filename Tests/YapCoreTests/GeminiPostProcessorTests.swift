import XCTest
@testable import YapCore

final class GeminiPostProcessorTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    func testApiKeyPathHitsCorrectURLAndReturnsCleanText() async throws {
        var seenURL: URL?
        var seenAuthHeader: String?
        MockURLProtocol.handler = { req in
            seenURL = req.url
            seenAuthHeader = req.value(forHTTPHeaderField: "Authorization")
            let body = #"{"candidates":[{"content":{"parts":[{"text":"Hello, world."}]}}]}"#.data(using: .utf8)!
            return (200, body)
        }
        let proc = GeminiPostProcessor(
            model: .flashLite,
            prompt: "SYS",
            auth: .apiKey("SECRET"),
            session: MockURLProtocol.session()
        )
        let out = try await proc.process("hello world")
        XCTAssertEqual(out, "Hello, world.")
        XCTAssertEqual(seenURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=SECRET")
        XCTAssertNil(seenAuthHeader)   // API-key path uses the query param, not a Bearer header
    }

    func testNon200Throws() async {
        MockURLProtocol.handler = { _ in (401, Data("nope".utf8)) }
        let proc = GeminiPostProcessor(model: .flash, prompt: "SYS", auth: .apiKey("BAD"),
                                       session: MockURLProtocol.session())
        do {
            _ = try await proc.process("hi")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? GeminiPostProcessorError, .httpStatus(401))
        }
    }

    func testEmptyCandidateThrows() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"candidates":[]}"#.utf8)) }
        let proc = GeminiPostProcessor(model: .flash, prompt: "SYS", auth: .apiKey("K"),
                                       session: MockURLProtocol.session())
        do {
            _ = try await proc.process("hi")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }
}
