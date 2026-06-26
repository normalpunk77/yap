import XCTest
@testable import YapCore

private struct StubProcessor: TextPostProcessor {
    let behavior: @Sendable (String) async throws -> String
    func process(_ text: String) async throws -> String { try await behavior(text) }
}

private struct StubError: Error {}

final class PostProcessRunnerTests: XCTestCase {
    func testNilProcessorReturnsRaw() async {
        let out = await PostProcessRunner.run("raw text", with: nil)
        XCTAssertEqual(out, "raw text")
    }

    func testSuccessReturnsCleaned() async {
        let proc = StubProcessor { _ in "cleaned" }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "cleaned")
    }

    func testThrowFallsBackToRaw() async {
        let proc = StubProcessor { _ in throw StubError() }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "raw")
    }

    func testEmptyResultFallsBackToRaw() async {
        let proc = StubProcessor { _ in "   \n " }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "raw")
    }

    func testTimeoutFallsBackToRaw() async {
        let proc = StubProcessor { _ in
            try await Task.sleep(for: .seconds(10))
            return "too late"
        }
        let out = await PostProcessRunner.run("raw", with: proc, timeout: .milliseconds(50))
        XCTAssertEqual(out, "raw")
    }
}
