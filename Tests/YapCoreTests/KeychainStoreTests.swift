import XCTest
@testable import YapApp

/// Round-trips against the REAL login keychain of the machine running the tests, on a
/// unique throwaway service name that is always deleted afterwards.
final class KeychainStoreTests: XCTestCase {
    private let service = "com.yap.tests.\(UUID().uuidString)"
    private let account = "api-key"

    override func tearDown() {
        KeychainStore.delete(service: service, account: account)
        super.tearDown()
    }

    func testSaveReadDeleteRoundTrip() {
        XCTAssertEqual(KeychainStore.read(service: service, account: account), .missing)

        XCTAssertTrue(KeychainStore.save("secret-1", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), .found("secret-1"))

        // Second save must UPDATE in place (errSecDuplicateItem path), not fail.
        XCTAssertTrue(KeychainStore.save("secret-2", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), .found("secret-2"))

        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), .missing)
    }

    func testSavingEmptyValueClearsTheItem() {
        KeychainStore.save("secret", service: service, account: account)
        XCTAssertTrue(KeychainStore.save("   ", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), .missing)
    }

    func testDeleteOfMissingItemReportsGone() {
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
    }
}
