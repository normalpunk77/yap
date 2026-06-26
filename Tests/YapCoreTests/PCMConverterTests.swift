import XCTest
@testable import YapCore

final class PCMConverterTests: XCTestCase {
    func testZeroSample() {
        XCTAssertEqual(PCM16.fromFloat([0]), Data([0x00, 0x00]))
    }
    func testFullScalePositiveClamps() {
        // +1.0 -> 32767 (0x7FFF) little-endian
        XCTAssertEqual(PCM16.fromFloat([1.0]), Data([0xFF, 0x7F]))
    }
    func testFullScaleNegativeClamps() {
        // -1.0 -> -32768 (0x8000) little-endian
        XCTAssertEqual(PCM16.fromFloat([-1.0]), Data([0x00, 0x80]))
    }
    func testOvershootIsClamped() {
        XCTAssertEqual(PCM16.fromFloat([2.0]), Data([0xFF, 0x7F]))
        XCTAssertEqual(PCM16.fromFloat([-2.0]), Data([0x00, 0x80]))
    }
    func testLengthIsTwoBytesPerSample() {
        XCTAssertEqual(PCM16.fromFloat([0, 0, 0]).count, 6)
    }
}
