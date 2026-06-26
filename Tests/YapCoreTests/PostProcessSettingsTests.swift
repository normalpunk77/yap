import XCTest
@testable import YapCore

final class PostProcessSettingsTests: XCTestCase {
    func testModelRawValuesAreGeminiIDs() {
        XCTAssertEqual(GeminiModel.flashLite.rawValue, "gemini-2.5-flash-lite")
        XCTAssertEqual(GeminiModel.flash.rawValue, "gemini-2.5-flash")
    }

    func testDefaultPromptIsNonEmptyAndCleanupOriented() {
        let p = PostProcessDefaults.prompt.lowercased()
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(p.contains("only"))   // "output only the cleaned text"
    }

    func testDefaultRegion() {
        XCTAssertEqual(PostProcessDefaults.vertexRegion, "us-central1")
    }
}
