import XCTest
import ObjCExceptionCatcher

/// The crash that kept killing Yap: AVFoundation's installTap raises an
/// Objective-C NSException, which Swift's do/catch cannot intercept -> SIGABRT.
/// These assert the shim converts such an exception into a recoverable error.
final class ObjCExceptionCatcherTests: XCTestCase {
    func testConvertsRaisedNSExceptionIntoError() {
        var error: NSError?
        let ok = ocec_perform({
            NSException(name: .invalidArgumentException, reason: "required condition is false", userInfo: nil).raise()
        }, &error)

        XCTAssertFalse(ok, "a raised NSException must report failure, not crash")
        XCTAssertEqual(error?.domain, "ObjCException")
        XCTAssertEqual(error?.localizedDescription, "required condition is false")
    }

    func testPassesThroughWhenNoExceptionRaised() {
        var ran = false
        var error: NSError?
        let ok = ocec_perform({ ran = true }, &error)

        XCTAssertTrue(ok)
        XCTAssertTrue(ran)
        XCTAssertNil(error)
    }
}
