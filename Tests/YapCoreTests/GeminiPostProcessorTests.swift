import XCTest
@testable import YapCore

final class GeminiPostProcessorTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    func testApiKeyPathHitsCorrectURLAndReturnsCleanText() async throws {
        var seenURL: URL?
        var seenAuthHeader: String?
        var seenKeyHeader: String?
        MockURLProtocol.handler = { req in
            seenURL = req.url
            seenAuthHeader = req.value(forHTTPHeaderField: "Authorization")
            seenKeyHeader = req.value(forHTTPHeaderField: "x-goog-api-key")
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
        // The key travels in the x-goog-api-key header, NOT the URL — so it can't leak via
        // crash reports / proxy logs that capture the failing URL.
        XCTAssertEqual(seenURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent")
        XCTAssertEqual(seenKeyHeader, "SECRET")
        XCTAssertNil(seenAuthHeader)   // API-key path uses the key header, not a Bearer header
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

    func testVertexPathHitsRegionalURLWithBearer() async throws {
        var seenURL: URL?
        var seenAuth: String?
        MockURLProtocol.handler = { req in
            seenURL = req.url
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            let body = #"{"candidates":[{"content":{"parts":[{"text":"Ciao."}]}}]}"#.data(using: .utf8)!
            return (200, body)
        }
        let proc = GeminiPostProcessor(
            model: .flash,
            prompt: "SYS",
            auth: .vertex(token: { "TOK" }, project: "my-proj", region: "europe-west1"),
            session: MockURLProtocol.session()
        )
        let out = try await proc.process("ciao")
        XCTAssertEqual(out, "Ciao.")
        XCTAssertEqual(seenURL?.absoluteString,
            "https://europe-west1-aiplatform.googleapis.com/v1/projects/my-proj/locations/europe-west1/publishers/google/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(seenAuth, "Bearer TOK")
    }

    func testVertexTokenFailurePropagates() async {
        struct Boom: Error {}
        MockURLProtocol.handler = { _ in (200, Data(#"{"candidates":[]}"#.utf8)) }
        let proc = GeminiPostProcessor(
            model: .flash, prompt: "S",
            auth: .vertex(token: { throw Boom() }, project: "p", region: "us-central1"),
            session: MockURLProtocol.session()
        )
        do { _ = try await proc.process("x"); XCTFail("expected throw") }
        catch { XCTAssertTrue(error is Boom) }
    }
}
